import Foundation
import UIKit

/// Журнал событий в JSONL (одна запись — одна строка). Аудио сюда не пишется никогда.
@MainActor
final class DiagnosticsLog: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let time: Date
        /// Монотонное время с загрузки устройства — для точных интервалов между событиями.
        let uptime: TimeInterval
        let kind: String
        let message: String
        let preset: String?
        let fields: [String: String]?
        let snapshot: SessionSnapshot?
    }

    @Published private(set) var recent: [Entry] = []
    @Published private(set) var fileURL: URL
    var currentPreset: String?

    private var handle: FileHandle?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // ISO8601FormatStyle — Sendable, в отличие от ISO8601DateFormatter.
        let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        encoder.dateEncodingStrategy = .custom { date, enc in
            var container = enc.singleValueContainer()
            try container.encode(style.format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let recentLimit = 300

    init() {
        fileURL = Self.makeFileURL()
        openFile()
    }

    func startNewFile() {
        try? handle?.close()
        fileURL = Self.makeFileURL()
        recent.removeAll()
        openFile()
    }

    func log(_ kind: String, _ message: String,
             fields: [String: String]? = nil, snapshot: SessionSnapshot? = nil) {
        let entry = Entry(time: Date(), uptime: ProcessInfo.processInfo.systemUptime,
                          kind: kind, message: message, preset: currentPreset,
                          fields: fields, snapshot: snapshot)
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
        guard let handle, var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        try? handle.write(contentsOf: data)
    }

    private func openFile() {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        log("log_start", "Новый журнал", fields: [
            "device": Self.machineIdentifier(),
            "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
        ])
    }

    private static func makeFileURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return dir.appendingPathComponent("spike-\(formatter.string(from: Date())).jsonl")
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// Ошибки AVAudioSession/CoreAudio часто приходят как FourCC (например '!rec' = cannotStartRecording).
func describe(_ error: Error) -> String {
    let ns = error as NSError
    let code = UInt32(truncatingIfNeeded: ns.code)
    let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
    let fourCC = bytes.allSatisfy { (0x20...0x7E).contains($0) }
        ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
    return "\(ns.domain) \(ns.code)\(fourCC): \(ns.localizedDescription)"
}
