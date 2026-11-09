import AVFAudio

/// Как CaptureEngine настраивает Voice Processing I/O на входном узле.
enum VoiceProcessing: String, Codable {
    case off
    /// VPIO с ducking по умолчанию.
    case on
    /// VPIO + advanced ducking на минимальном уровне (iOS 17+).
    case onDuckingMin
    /// VPIO включён, но обработка обойдена (нет AEC/AGC/NS).
    case bypassed
}

/// Конфигурация аудиосессии из матрицы P0–P10 (docs/01-feasibility-study.md, раздел 4).
struct SessionPreset: Identifiable {
    let id: String
    let title: String
    /// nil — P0: приложение вообще не трогает AVAudioSession.
    let category: AVAudioSession.Category?
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions
    let voiceProcessing: VoiceProcessing
    let wantsInput: Bool
    let expectation: String
    var isAvailable: Bool = true

    static let all: [SessionPreset] = [
        SessionPreset(
            id: "P0", title: "Без сессии (базовая линия)",
            category: nil, mode: .default, options: [],
            voiceProcessing: .off, wantsInput: false,
            expectation: "Spotify → A2DP. Приложение не активирует сессию."),
        SessionPreset(
            id: "P1", title: "playback + mixWithOthers",
            category: .playback, mode: .default, options: [.mixWithOthers],
            voiceProcessing: .off, wantsInput: false,
            expectation: "Наш тестовый клип и Spotify → A2DP, микрофона нет."),
        SessionPreset(
            id: "P2", title: "playAndRecord + A2DP",
            category: .playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP],
            voiceProcessing: .off, wantsInput: true,
            expectation: "Вход — встроенный микрофон, вывод — A2DP [DOC]. Режим C."),
        SessionPreset(
            id: "P3", title: "playAndRecord + HFP",
            category: .playAndRecord, mode: .default, options: [.mixWithOthers, .hfp],
            voiceProcessing: .off, wantsInput: true,
            expectation: "Вход и вывод — HFP Y12. Музыка в HFP-качестве."),
        SessionPreset(
            id: "P4", title: "playAndRecord + HFP + A2DP",
            category: .playAndRecord, mode: .default, options: [.mixWithOthers, .hfp, .allowBluetoothA2DP],
            voiceProcessing: .off, wantsInput: true,
            expectation: "HFP в приоритете [DOC]. Смотрим, на какой фазе меняется маршрут."),
        SessionPreset(
            id: "P5", title: "voiceChat + A2DP (без HFP в опциях)",
            category: .playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .allowBluetoothA2DP],
            voiceProcessing: .off, wantsInput: true,
            expectation: "voiceChat сам добавит HFP [DOC]."),
        SessionPreset(
            id: "P6a", title: "voiceChat + VPIO, ducking default",
            category: .playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .hfp],
            voiceProcessing: .on, wantsInput: true,
            expectation: "Музыка приглушена (ducking). Измерить Δ дБ относительно P0."),
        SessionPreset(
            id: "P6b", title: "voiceChat + VPIO, advanced ducking min",
            category: .playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .hfp],
            voiceProcessing: .onDuckingMin, wantsInput: true,
            expectation: "Ducking слабее, чем в P6a (iOS 17+)."),
        SessionPreset(
            id: "P7", title: "voiceChat + VPIO bypassed",
            category: .playAndRecord, mode: .voiceChat, options: [.mixWithOthers, .hfp],
            voiceProcessing: .bypassed, wantsInput: true,
            expectation: "Нет AEC/AGC. Слушать эхо музыки и клипа во входе."),
        SessionPreset(
            id: "P8", title: "База для переключения A2DP↔HFP",
            category: .playAndRecord, mode: .default, options: [.mixWithOthers, .hfp, .allowBluetoothA2DP],
            voiceProcessing: .off, wantsInput: true,
            expectation: "Используйте блок «Переключение A2DP↔HFP» (режим B)."),
        hqRecordingPreset,
        SessionPreset(
            id: "P10", title: "Как P2 + внешний USB/Lightning-микрофон",
            category: .playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothA2DP],
            voiceProcessing: .off, wantsInput: true,
            expectation: "Подключите микрофон и выберите его в «Предпочтительный вход». Остаётся ли вывод на A2DP?"),
    ]

    private static var hqRecordingPreset: SessionPreset {
        let hq = AVAudioSession.CategoryOptions.bluetoothHQ
        let base: AVAudioSession.CategoryOptions = [.mixWithOthers, .hfp]
        return SessionPreset(
            id: "P9", title: "bluetoothHighQualityRecording (iOS 26)",
            category: .playAndRecord, mode: .default, options: base.union(hq ?? []),
            voiceProcessing: .off, wantsInput: true,
            expectation: "Для Y12 ожидаем isSupported == false. Опция только с mode default [DOC].",
            isAvailable: hq != nil)
    }

    static func byID(_ id: String) -> SessionPreset {
        all.first { $0.id == id } ?? all[0]
    }
}

extension AVAudioSession.CategoryOptions {
    /// В SDK iOS 26 `allowBluetooth` переименован в `allowBluetoothHFP`; поведение то же.
    static var hfp: AVAudioSession.CategoryOptions {
        #if compiler(>=6.2)
        return .allowBluetoothHFP
        #else
        return .allowBluetooth
        #endif
    }

    /// `bluetoothHighQualityRecording` есть только в SDK и рантайме iOS 26+.
    static var bluetoothHQ: AVAudioSession.CategoryOptions? {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            return .bluetoothHighQualityRecording
        }
        #endif
        return nil
    }

    var names: [String] {
        var known: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"),
            (.duckOthers, "duckOthers"),
            (.hfp, "allowBluetoothHFP"),
            (.defaultToSpeaker, "defaultToSpeaker"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
            (.allowBluetoothA2DP, "allowBluetoothA2DP"),
            (.allowAirPlay, "allowAirPlay"),
            (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"),
        ]
        if let hq = Self.bluetoothHQ {
            known.append((hq, "bluetoothHighQualityRecording"))
        }
        return known.filter { contains($0.0) }.map(\.1)
    }
}
