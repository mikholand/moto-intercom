import AVFAudio
import UIKit

/// Журналирует все системные события, влияющие на аудио, и передаёт ключевые контроллеру.
/// userInfo разбирается сразу в обработчике: Notification не Sendable.
@MainActor
final class RouteMonitor {
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?
    var onRouteChange: (() -> Void)?
    var onMediaServicesReset: (() -> Void)?

    private let log: DiagnosticsLog
    private var tokens: [NSObjectProtocol] = []

    init(log: DiagnosticsLog) {
        self.log = log
    }

    func start() {
        guard tokens.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()

        observe(AVAudioSession.interruptionNotification, object: session) { info in
            let typeRaw = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optionsRaw = info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let reasonRaw = info?[AVAudioSessionInterruptionReasonKey] as? UInt
            return { [weak self] in
                guard let self else { return }
                let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
                let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
                var fields = ["type": type == .began ? "began" : "ended",
                              "shouldResume": "\(shouldResume)"]
                if let reasonRaw { fields["reasonRaw"] = "\(reasonRaw)" }
                self.log.log("interruption", "Прерывание аудиосессии", fields: fields, snapshot: .capture())
                if type == .began {
                    self.onInterruptionBegan?()
                } else {
                    self.onInterruptionEnded?(shouldResume)
                }
            }
        }

        observe(AVAudioSession.routeChangeNotification, object: session) { info in
            let reasonRaw = info?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let previous = info?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            let previousText = previous.map { route in
                "IN: " + route.inputs.map { "\($0.portType.rawValue)「\($0.portName)」" }.joined(separator: ", ")
                    + " OUT: " + route.outputs.map { "\($0.portType.rawValue)「\($0.portName)」" }.joined(separator: ", ")
            } ?? "—"
            return { [weak self] in
                guard let self else { return }
                let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw)?.name ?? "raw \(reasonRaw)"
                self.log.log("route_change", "Смена маршрута: \(reason)",
                             fields: ["reason": reason, "previous": previousText], snapshot: .capture())
                self.onRouteChange?()
            }
        }

        observe(AVAudioSession.mediaServicesWereLostNotification, object: session) { _ in
            { [weak self] in self?.log.log("media_services_lost", "Медиасервисы потеряны") }
        }

        observe(AVAudioSession.mediaServicesWereResetNotification, object: session) { _ in
            { [weak self] in
                guard let self else { return }
                self.log.log("media_services_reset", "Медиасервисы перезапущены — нужно пересоздать сессию и движок")
                self.onMediaServicesReset?()
            }
        }

        observe(AVAudioSession.silenceSecondaryAudioHintNotification, object: session) { info in
            let typeRaw = info?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt ?? 0
            return { [weak self] in
                let begin = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: typeRaw) == .begin
                self?.log.log("silence_hint", begin ? "Другое приложение начало основной звук"
                                                    : "Другое приложение закончило основной звук",
                              snapshot: .capture())
            }
        }

        let lifecycle: [(Notification.Name, String, String)] = [
            (UIApplication.didEnterBackgroundNotification, "app_background", "Приложение ушло в фон"),
            (UIApplication.willEnterForegroundNotification, "app_foreground", "Приложение возвращается"),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, "device_locked",
             "Устройство заблокировано (защищённые данные недоступны)"),
            (UIApplication.protectedDataDidBecomeAvailableNotification, "device_unlocked", "Устройство разблокировано"),
            (ProcessInfo.thermalStateDidChangeNotification, "thermal", "Изменилось тепловое состояние"),
        ]
        for (name, kind, message) in lifecycle {
            observe(name, object: nil) { _ in
                { [weak self] in self?.log.log(kind, message, snapshot: .capture()) }
            }
        }
    }

    /// `parse` выполняется синхронно в обработчике и возвращает действие для MainActor.
    private func observe(_ name: Notification.Name, object: AnyObject?,
                         parse: @escaping ([AnyHashable: Any]?) -> @MainActor () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { note in
            let action = parse(note.userInfo)
            Task { @MainActor in action() }
        }
        tokens.append(token)
    }
}

extension AVAudioSession.RouteChangeReason {
    var name: String {
        switch self {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
