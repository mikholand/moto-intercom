import AVFAudio

/// Сигнал «собеседника», который приложение играет поверх музыки (фаза 4).
/// Если в бандл положен voice_clip.(m4a|wav|caf), используется он, иначе — синтетические тоны.
enum TestClip {
    static func load() -> (buffer: AVAudioPCMBuffer, source: String) {
        for ext in ["m4a", "wav", "caf"] {
            if let url = Bundle.main.url(forResource: "voice_clip", withExtension: ext),
               let file = try? AVAudioFile(forReading: url),
               let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(file.length)),
               (try? file.read(into: buffer)) != nil {
                return (buffer, "voice_clip.\(ext)")
            }
        }
        return (synthesized(), "синтетические тоны 500/1500 Гц")
    }

    /// 6 с: чередование 500 и 1500 Гц по 250 мс с паузами 250 мс, фейды 5 мс против щелчков.
    private static func synthesized() -> AVAudioPCMBuffer {
        let sampleRate = 48_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let total = AVAudioFrameCount(sampleRate * 6)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total)!
        buffer.frameLength = total
        let samples = buffer.floatChannelData![0]
        let tone = Int(sampleRate * 0.25)
        let fade = Int(sampleRate * 0.005)
        for i in 0..<Int(total) {
            let slot = i / tone
            let pos = i % tone
            guard slot % 2 == 0 else { samples[i] = 0; continue }
            let freq = (slot / 2) % 2 == 0 ? 500.0 : 1500.0
            let envelope = Float(min(1, Double(min(pos, tone - pos)) / Double(fade)))
            samples[i] = 0.3 * envelope * Float(sin(2 * .pi * freq * Double(i) / sampleRate))
        }
        return buffer
    }
}
