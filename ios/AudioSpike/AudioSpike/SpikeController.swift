import AVFAudio
import Foundation

struct SpikeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Фазы из протокола (docs/02-audio-spike-protocol.md, раздел 2) и паузы после них в автопрогоне.
enum Phase: Int, CaseIterable, Identifiable {
    case setCategory = 1, activate, startInput, playClip, stopInput, deactivate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .setCategory: return "1. setCategory"
        case .activate: return "2. Активировать"
        case .startInput: return "3. Старт входа"
        case .playClip: return "4. Клип поверх музыки"
        case .stopInput: return "5. Стоп входа"
        case .deactivate: return "6. Деактивировать"
        }
    }

    var dwell: TimeInterval {
        switch self {
        case .setCategory: return 2
        case .activate: return 5
        case .startInput: return 15
        case .playClip, .stopInput, .deactivate: return 10
        }
    }
}

enum SwitchStrategy: String, CaseIterable, Identifiable {
    /// Опции [HFP + A2DP] постоянны, вход переключается между HFP и встроенным микрофоном.
    case preferredInput
    /// Опции меняются: с HFP ↔ только A2DP.
    case categoryOptions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferredInput: return "setPreferredInput"
        case .categoryOptions: return "смена опций категории"
        }
    }
}

struct SwitchResult: Identifiable {
    let id = UUID()
    let cycle: Int
    let direction: String
    let milliseconds: Double?
    let route: String
}

@MainActor
final class SpikeController: ObservableObject {
    @Published var presetID = "P0" {
        didSet { log.currentPreset = presetID }
    }
    @Published private(set) var snapshot: SessionSnapshot
    @Published private(set) var status = "Готов"
    @Published private(set) var isAutoRunning = false
    @Published var autoResume = true
    @Published var autoRestartEngine = true
    @Published var noSystemAlertInterruptions = false {
        didSet { setNoSystemAlertInterruptions(noSystemAlertInterruptions) }
    }
    @Published var switchStrategy: SwitchStrategy = .preferredInput
    @Published private(set) var switchResults: [SwitchResult] = []

    let log: DiagnosticsLog
    let capture: CaptureEngine
    let clipSource: String
    private let probe = AudioSessionProbe()
    private let monitor: RouteMonitor
    private var runTask: Task<Void, Never>?
    private var ticker: Timer?
    private var ticks = 0
    private var resumeInputAfterInterruption = false

    var preset: SessionPreset { SessionPreset.byID(presetID) }
    var isSessionActive: Bool { probe.isActive }

    init() {
        let log = DiagnosticsLog()
        let clip = TestClip.load()
        self.log = log
        clipSource = clip.source
        capture = CaptureEngine(log: log, clip: clip.buffer)
        monitor = RouteMonitor(log: log)
        snapshot = .capture()
        log.currentPreset = presetID

        monitor.onInterruptionBegan = { [weak self] in self?.interruptionBegan() }
        monitor.onInterruptionEnded = { [weak self] shouldResume in self?.interruptionEnded(shouldResume) }
        monitor.onRouteChange = { [weak self] in self?.refresh() }
        monitor.onMediaServicesReset = { [weak self] in self?.mediaServicesReset() }
        capture.onConfigurationChange = { [weak self] in self?.engineConfigurationChanged() }
        monitor.start()

        // Раз в секунду обновляем экран; раз в 30 с пишем heartbeat — по росту callbacks
        // видно, что захват жив при заблокированном экране (T8).
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func prepare() async {
        let granted = await probe.requestMicrophonePermission()
        log.log("permission", granted ? "Доступ к микрофону есть" : "Доступ к микрофону запрещён")
    }

    func refresh() {
        snapshot = .capture()
    }

    // MARK: Фазы

    func run(_ phase: Phase) {
        let preset = preset
        do {
            switch phase {
            case .setCategory:
                guard preset.isAvailable else { throw SpikeError(message: "\(preset.id) недоступен на этой iOS") }
                if preset.category == nil {
                    log.log("phase", "P0: сессия не настраивается")
                    break
                }
                try probe.apply(preset)
            case .activate:
                guard preset.category != nil else { break }
                try probe.activate()
            case .startInput:
                guard preset.wantsInput else { throw SpikeError(message: "У \(preset.id) нет входа") }
                guard AVAudioApplication.shared.recordPermission == .granted else {
                    throw SpikeError(message: "Нет разрешения на микрофон")
                }
                try capture.startInput(voiceProcessing: preset.voiceProcessing)
            case .playClip:
                // В P0 сессия по умолчанию soloAmbient: клип прервал бы Spotify, это не тот тест.
                guard preset.category != nil else { throw SpikeError(message: "В P0 клип не играем") }
                try capture.playClip()
            case .stopInput:
                capture.stop()
            case .deactivate:
                // Деактивация при работающем I/O вернёт ошибку, поэтому сначала стоп движка.
                capture.stop()
                guard preset.category != nil else { break }
                try probe.deactivate()
            }
            refresh()
            status = "\(phase.title): OK"
            log.log("phase", phase.title, fields: ["result": "ok"], snapshot: snapshot)
        } catch {
            refresh()
            status = "\(phase.title): \(error.localizedDescription)"
            log.log("phase", phase.title, fields: ["result": "error", "error": describe(error)], snapshot: snapshot)
        }
    }

    func runAllPhases() {
        startTask { controller in
            controller.log.log("auto_run", "Автопрогон фаз 1–6")
            for phase in Phase.allCases {
                guard !Task.isCancelled else { return }
                controller.run(phase)
                try? await Task.sleep(nanoseconds: UInt64(phase.dwell * 1_000_000_000))
            }
            controller.log.log("auto_run", "Автопрогон завершён")
        }
    }

    func cancelTask() {
        runTask?.cancel()
        log.log("auto_run", "Остановлено пользователем")
    }

    // MARK: Маршрут

    func choosePreferredInput(uid: String?) {
        do {
            try probe.setPreferredInput(uid: uid)
            log.log("preferred_input", "Запрошен вход: \(uid ?? "nil")")
            Task {
                let ms = await probe.waitForRoute { route in
                    uid == nil || route.inputs.contains { $0.uid == uid }
                }
                refresh()
                log.log("preferred_input", "Маршрут после запроса",
                        fields: ["ms": ms.map { String(format: "%.0f", $0) } ?? "timeout"],
                        snapshot: snapshot)
            }
        } catch {
            status = "Вход: \(error.localizedDescription)"
            log.log("preferred_input", "Ошибка", fields: ["error": describe(error)])
        }
    }

    func runSwitchCycles(count: Int = 10, dwell: TimeInterval = 5) {
        guard probe.isActive, capture.hasInput else {
            status = "Сначала P8: фазы 1–3 (сессия активна, вход запущен)"
            return
        }
        startTask { controller in
            controller.switchResults.removeAll()
            controller.log.log("switch_start", "Циклы A2DP↔HFP",
                               fields: ["strategy": controller.switchStrategy.rawValue, "count": "\(count)"])
            for cycle in 1...count {
                for toHFP in [true, false] {
                    guard !Task.isCancelled else { return }
                    await controller.switchOnce(cycle: cycle, toHFP: toHFP)
                    try? await Task.sleep(nanoseconds: UInt64(dwell * 1_000_000_000))
                }
            }
            controller.log.log("switch_end", "Циклы завершены")
        }
    }

    private func switchOnce(cycle: Int, toHFP: Bool) async {
        let direction = toHFP ? "→HFP" : "→A2DP"
        do {
            switch switchStrategy {
            case .preferredInput:
                let type: AVAudioSession.Port = toHFP ? .bluetoothHFP : .builtInMic
                guard let port = probe.firstAvailableInput(of: type) else {
                    throw SpikeError(message: "\(type.rawValue) нет в availableInputs")
                }
                try probe.setPreferredInput(uid: port.uid)
            case .categoryOptions:
                try probe.setOptions(toHFP ? [.mixWithOthers, .hfp, .allowBluetoothA2DP]
                                           : [.mixWithOthers, .allowBluetoothA2DP])
                if toHFP, let port = probe.firstAvailableInput(of: .bluetoothHFP) {
                    try probe.setPreferredInput(uid: port.uid)
                }
            }
            // Успех «→A2DP» — это именно вывод на A2DP, а не просто уход входа с HFP.
            let ms = await probe.waitForRoute { route in
                toHFP ? route.inputs.contains { $0.portType == .bluetoothHFP }
                      : route.outputs.contains { $0.portType == .bluetoothA2DP }
            }
            refresh()
            let result = SwitchResult(cycle: cycle, direction: direction, milliseconds: ms,
                                      route: snapshot.routeSummary.replacingOccurrences(of: "\n", with: " | "))
            switchResults.append(result)
            log.log("switch", "Цикл \(cycle) \(direction)",
                    fields: ["ms": ms.map { String(format: "%.0f", $0) } ?? "timeout"], snapshot: snapshot)
        } catch {
            switchResults.append(SwitchResult(cycle: cycle, direction: direction, milliseconds: nil,
                                              route: error.localizedDescription))
            log.log("switch", "Цикл \(cycle) \(direction): ошибка", fields: ["error": describe(error)])
        }
    }

    // MARK: Прочее

    func checkHighQualityRecording() {
        refresh()
        let ports = snapshot.availableInputs + snapshot.inputs
        let lines = ports.map { port -> String in
            let supported = port.hqRecordingSupported.map { "\($0)" } ?? "н/д (iOS < 26 или не BT)"
            return "\(port.short): supported=\(supported)"
        }
        status = lines.isEmpty ? "Входов нет" : lines.joined(separator: "\n")
        log.log("hq_check", "bluetoothHighQualityRecording", fields: ["ports": lines.joined(separator: "; ")],
                snapshot: snapshot)
    }

    func mark(_ text: String) {
        refresh()
        log.log("mark", text, snapshot: snapshot)
        status = "Отметка: \(text)"
    }

    private func setNoSystemAlertInterruptions(_ value: Bool) {
        do {
            try probe.setPrefersNoInterruptionsFromSystemAlerts(value)
            log.log("setting", "prefersNoInterruptionsFromSystemAlerts = \(value)")
        } catch {
            log.log("setting", "prefersNoInterruptionsFromSystemAlerts: ошибка", fields: ["error": describe(error)])
        }
    }

    private func startTask(_ body: @escaping @MainActor (SpikeController) async -> Void) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            self.isAutoRunning = true
            await body(self)
            self.isAutoRunning = false
        }
    }

    private func tick() {
        refresh()
        ticks += 1
        guard ticks % 30 == 0, probe.isActive || capture.isRunning else { return }
        let reading = capture.meter.read()
        log.log("heartbeat", "Состояние", fields: [
            "engineRunning": "\(capture.isRunning)",
            "callbacks": "\(reading.callbacks)",
            "gaps": "\(reading.gaps)",
            "rmsDB": String(format: "%.1f", reading.rmsDB),
        ], snapshot: snapshot)
    }

    // MARK: Системные события

    private func interruptionBegan() {
        resumeInputAfterInterruption = capture.hasInput
        probe.markInactive()
        status = "Прерывание…"
        refresh()
    }

    private func interruptionEnded(_ shouldResume: Bool) {
        guard autoResume else {
            status = "Прерывание закончилось (shouldResume=\(shouldResume)), автовосстановление выключено"
            return
        }
        // Пробуем всегда, даже без shouldResume: важно узнать, позволит ли система (особенно в фоне).
        do {
            try probe.activate()
            if resumeInputAfterInterruption {
                try capture.startInput(voiceProcessing: preset.voiceProcessing)
            }
            status = "Восстановлено после прерывания"
            log.log("resume", "Восстановление после прерывания",
                    fields: ["result": "ok", "shouldResume": "\(shouldResume)"], snapshot: .capture())
        } catch {
            status = "Не удалось восстановить: \(error.localizedDescription)"
            log.log("resume", "Восстановление после прерывания",
                    fields: ["result": "error", "shouldResume": "\(shouldResume)", "error": describe(error)],
                    snapshot: .capture())
        }
        refresh()
    }

    private func engineConfigurationChanged() {
        let hadInput = capture.hasInput
        guard autoRestartEngine, hadInput else {
            capture.stop()
            refresh()
            return
        }
        do {
            try capture.startInput(voiceProcessing: preset.voiceProcessing)
            log.log("engine_restart", "Вход перезапущен после смены конфигурации", fields: ["result": "ok"])
        } catch {
            log.log("engine_restart", "Перезапуск входа не удался",
                    fields: ["result": "error", "error": describe(error)], snapshot: .capture())
        }
        refresh()
    }

    private func mediaServicesReset() {
        let hadInput = capture.hasInput
        capture.stop()
        probe.markInactive()
        guard autoResume, preset.category != nil else {
            status = "Медиасервисы сброшены — повторите фазы вручную"
            refresh()
            return
        }
        do {
            try probe.apply(preset)
            try probe.activate()
            if hadInput {
                try capture.startInput(voiceProcessing: preset.voiceProcessing)
            }
            log.log("reset_recover", "Сессия пересоздана после сброса", fields: ["result": "ok"], snapshot: .capture())
        } catch {
            log.log("reset_recover", "Не удалось пересоздать сессию",
                    fields: ["result": "error", "error": describe(error)], snapshot: .capture())
        }
        refresh()
    }
}
