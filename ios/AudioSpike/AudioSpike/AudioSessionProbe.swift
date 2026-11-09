import AVFAudio

/// Тонкая обёртка над AVAudioSession: применение пресета, активация, выбор входа и измерение
/// времени, за которое маршрут действительно сменился (setPreferredInput лишь запрашивает смену).
@MainActor
final class AudioSessionProbe {
    let session = AVAudioSession.sharedInstance()
    private(set) var isActive = false

    func apply(_ preset: SessionPreset) throws {
        guard let category = preset.category else { return }
        try session.setCategory(category, mode: preset.mode, options: preset.options)
    }

    func setOptions(_ options: AVAudioSession.CategoryOptions) throws {
        try session.setCategory(session.category, mode: session.mode, options: options)
    }

    func activate() throws {
        try session.setActive(true)
        isActive = true
    }

    func deactivate() throws {
        // notifyOthersOnDeactivation — чтобы Spotify мог восстановить громкость и маршрут.
        try session.setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
    }

    /// Сессия могла быть деактивирована системой (прерывание, сброс медиасервисов).
    func markInactive() {
        isActive = false
    }

    func setPreferredInput(uid: String?) throws {
        let port = uid.flatMap { uid in session.availableInputs?.first { $0.uid == uid } }
        try session.setPreferredInput(port)
    }

    func firstAvailableInput(of type: AVAudioSession.Port) -> AVAudioSessionPortDescription? {
        session.availableInputs?.first { $0.portType == type }
    }

    func setPrefersNoInterruptionsFromSystemAlerts(_ value: Bool) throws {
        try session.setPrefersNoInterruptionsFromSystemAlerts(value)
    }

    func requestMicrophonePermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// Ждёт, пока `condition` выполнится для currentRoute. Возвращает миллисекунды или nil по таймауту.
    func waitForRoute(timeout: TimeInterval = 5,
                      _ condition: (AVAudioSessionRouteDescription) -> Bool) async -> Double? {
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < timeout {
            if condition(session.currentRoute) {
                return (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }
}
