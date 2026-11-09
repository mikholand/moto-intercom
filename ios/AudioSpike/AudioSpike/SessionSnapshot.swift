import AVFAudio
import UIKit

struct PortInfo: Codable, Hashable {
    let type: String
    let name: String
    let uid: String
    let channels: Int
    /// Только iOS 26+: поддерживает ли порт bluetoothHighQualityRecording.
    let hqRecordingSupported: Bool?
    let hqRecordingEnabled: Bool?

    init(_ port: AVAudioSessionPortDescription) {
        type = port.portType.rawValue
        name = port.portName
        uid = port.uid
        channels = port.channels?.count ?? 0
        var supported: Bool?
        var enabled: Bool?
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let ext = port.bluetoothMicrophoneExtension {
            supported = ext.highQualityRecording.isSupported
            enabled = ext.highQualityRecording.isEnabled
        }
        #endif
        hqRecordingSupported = supported
        hqRecordingEnabled = enabled
    }

    var short: String { "\(type)「\(name)」ch\(channels)" }
}

/// Уровень L1 протокола: всё, что AVAudioSession сообщает о себе в данный момент.
struct SessionSnapshot: Codable {
    let category: String
    let mode: String
    let options: [String]
    let optionsRaw: UInt
    let sampleRate: Double
    let preferredSampleRate: Double
    let ioBufferDuration: Double
    let inputLatency: Double
    let outputLatency: Double
    let inputChannels: Int
    let outputChannels: Int
    let outputVolume: Float
    let isInputAvailable: Bool
    let isOtherAudioPlaying: Bool
    let secondaryAudioShouldBeSilencedHint: Bool
    let inputs: [PortInfo]
    let outputs: [PortInfo]
    let availableInputs: [PortInfo]
    let preferredInput: String?
    let thermalState: String
    let batteryLevel: Float
    let lowPowerMode: Bool
    let appState: String

    @MainActor
    static func capture() -> SessionSnapshot {
        let s = AVAudioSession.sharedInstance()
        let route = s.currentRoute
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        return SessionSnapshot(
            category: s.category.rawValue,
            mode: s.mode.rawValue,
            options: s.categoryOptions.names,
            optionsRaw: s.categoryOptions.rawValue,
            sampleRate: s.sampleRate,
            preferredSampleRate: s.preferredSampleRate,
            ioBufferDuration: s.ioBufferDuration,
            inputLatency: s.inputLatency,
            outputLatency: s.outputLatency,
            inputChannels: s.inputNumberOfChannels,
            outputChannels: s.outputNumberOfChannels,
            outputVolume: s.outputVolume,
            isInputAvailable: s.isInputAvailable,
            isOtherAudioPlaying: s.isOtherAudioPlaying,
            secondaryAudioShouldBeSilencedHint: s.secondaryAudioShouldBeSilencedHint,
            inputs: route.inputs.map(PortInfo.init),
            outputs: route.outputs.map(PortInfo.init),
            availableInputs: (s.availableInputs ?? []).map(PortInfo.init),
            preferredInput: s.preferredInput?.portType.rawValue,
            thermalState: ProcessInfo.processInfo.thermalState.name,
            batteryLevel: device.batteryLevel,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            appState: UIApplication.shared.applicationState.name)
    }

    var routeSummary: String {
        let i = inputs.map(\.short).joined(separator: ", ")
        let o = outputs.map(\.short).joined(separator: ", ")
        return "IN: \(i.isEmpty ? "—" : i)\nOUT: \(o.isEmpty ? "—" : o)"
    }

    var formatSummary: String {
        String(format: "SR %.0f Гц · IO %.1f мс · lat in %.1f / out %.1f мс",
               sampleRate, ioBufferDuration * 1000, inputLatency * 1000, outputLatency * 1000)
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

extension UIApplication.State {
    var name: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
