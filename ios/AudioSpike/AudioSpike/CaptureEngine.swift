import AVFAudio
import Accelerate

struct MeterReading {
    var rmsDB: Float = -160
    var peakDB: Float = -160
    var callbacks = 0
    var gaps = 0
    var lastFrames = 0

    static let zero = MeterReading()
}

/// Уровень L2: измерения прямо в аудиопотоке. Пишется из аудиопотока tap, читается с main.
final class MeterState: @unchecked Sendable {
    private let lock = NSLock()
    private var reading = MeterReading()
    private var lastSampleTime: AVAudioFramePosition = -1
    private var lastLength: AVAudioFrameCount = 0

    func update(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let count = vDSP_Length(buffer.frameLength)
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(channel, 1, &rms, count)
        vDSP_maxmgv(channel, 1, &peak, count)

        lock.lock()
        defer { lock.unlock() }
        reading.rmsDB = Self.dB(rms)
        reading.peakDB = Self.dB(peak)
        reading.callbacks += 1
        reading.lastFrames = Int(buffer.frameLength)
        // Разрыв: следующий буфер начался позже, чем закончился предыдущий (с допуском в полбуфера).
        if time.isSampleTimeValid {
            if lastSampleTime >= 0,
               time.sampleTime - lastSampleTime > AVAudioFramePosition(lastLength + lastLength / 2) {
                reading.gaps += 1
            }
            lastSampleTime = time.sampleTime
            lastLength = buffer.frameLength
        }
    }

    func read() -> MeterReading {
        lock.lock()
        defer { lock.unlock() }
        return reading
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        reading = MeterReading()
        lastSampleTime = -1
        lastLength = 0
    }

    private static func dB(_ x: Float) -> Float { 20 * log10(max(x, 1e-8)) }
}

enum CaptureError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput: return "Нет входа: категория без записи или микрофон недоступен"
        }
    }
}

/// AVAudioEngine с входным tap (измерения) и плеером тестового клипа.
/// Входной узел трогается только в startInput: даже обращение к engine.inputNode включает захват.
@MainActor
final class CaptureEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var hasInput = false
    @Published private(set) var inputFormat = "—"
    @Published private(set) var reading = MeterReading.zero

    /// Вызывается после AVAudioEngineConfigurationChange; движок к этому моменту уже остановлен.
    var onConfigurationChange: (() -> Void)?

    let meter = MeterState()
    private let clip: AVAudioPCMBuffer
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var configObserver: NSObjectProtocol?
    private var meterTimer: Timer?
    private let log: DiagnosticsLog

    init(log: DiagnosticsLog, clip: AVAudioPCMBuffer) {
        self.log = log
        self.clip = clip
    }

    func startInput(voiceProcessing: VoiceProcessing) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing != .off {
            try input.setVoiceProcessingEnabled(true)
            if voiceProcessing == .onDuckingMin {
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: true, duckingLevel: .min)
            }
            input.isVoiceProcessingBypassed = voiceProcessing == .bypassed
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }

        meter.reset()
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tapBlock(meter))
        let player = attachPlayer(to: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.player = player
        hasInput = true
        inputFormat = String(format: "%.0f Гц · %u кан. · VP %@",
                             format.sampleRate, format.channelCount, voiceProcessing.rawValue)
        didStart(engine)
    }

    func playClip() throws {
        if engine == nil || player == nil {
            // Движок только на вывод: inputNode не трогаем, чтобы не открыть микрофон.
            let engine = AVAudioEngine()
            let player = attachPlayer(to: engine)
            engine.prepare()
            try engine.start()
            self.engine = engine
            self.player = player
            hasInput = false
            inputFormat = "—"
            didStart(engine)
        }
        player?.scheduleBuffer(clip, at: nil, options: [], completionHandler: nil)
        player?.play()
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        player?.stop()
        if let engine {
            engine.stop()
            if hasInput { engine.inputNode.removeTap(onBus: 0) }
        }
        engine = nil
        player = nil
        isRunning = false
        hasInput = false
        inputFormat = "—"
    }

    /// Блок создаётся вне MainActor: tap вызывается на аудиопотоке, и замыкание,
    /// унаследовавшее изоляцию MainActor, упало бы на проверке изоляции.
    private nonisolated static func tapBlock(_ meter: MeterState) -> AVAudioNodeTapBlock {
        { buffer, time in meter.update(buffer, time) }
    }

    private func attachPlayer(to engine: AVAudioEngine) -> AVAudioPlayerNode {
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: clip.format)
        return player
    }

    private func didStart(_ engine: AVAudioEngine) {
        isRunning = true
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reading = self.meter.read()
            }
        }
    }

    private func handleConfigurationChange() {
        let running = engine?.isRunning ?? false
        log.log("engine_config_change", "AVAudioEngine: смена конфигурации",
                fields: ["isRunning": "\(running)", "hadInput": "\(hasInput)"],
                snapshot: .capture())
        isRunning = running
        onConfigurationChange?()
    }
}
