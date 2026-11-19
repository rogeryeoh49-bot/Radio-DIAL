import AVFoundation

/// A short, rounded selection note; rendered once and played by the existing audio engine.
enum VISelectionTone {
    static func bundledBuffer() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: "VI-radio-selection", withExtension: "wav") else { return nil }
        return loadBuffer(from: url)
    }

    static func loadBuffer(from url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              file.processingFormat.sampleRate == 44_100,
              file.processingFormat.channelCount == 2,
              file.length > 0, file.length < 44_100,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        do { try file.read(into: buffer); return buffer } catch { return nil }
    }

    static func makeBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 0.16
        let count = Int(format.sampleRate * duration)
        guard count > 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            let time = Double(index) / format.sampleRate
            let phase = 2 * Double.pi * (230 * time + 100 * (1 - exp(-35 * time)) / 35)
            let attack = min(1, time / 0.002)
            let release = min(1, Double(count - 1 - index) / (format.sampleRate * 0.012))
            let envelope = attack * release * exp(-25 * time)
            let value = Float(envelope * (0.26 * sin(phase) + 0.06 * sin(2 * phase) + 0.03 * sin(3 * phase)))
            for channel in 0..<Int(format.channelCount) { channels[channel][index] = value }
        }
        return buffer
    }
}
