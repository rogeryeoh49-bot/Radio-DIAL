import AVFoundation
import Foundation

@main
enum PlaybackOutputTests {
    @MainActor
    static func main() async throws {
        let audio = StreamAudio()
        defer { audio.halt() }
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        var sharing = false
        var requests = 0
        let stats = UsageStatistics(storage: storage, endpoint: URL(string: "https://stats.example.test/v1/playback"),
                                    version: "2.2.1") { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        var starts = 0
        var audible = 0
        audio.onStarted = { _ in starts += 1 }
        audio.onAudiblePlayback = {
            audible += 1
            stats.playbackSucceeded(sharingEnabled: sharing)
        }
        audio.onFailure = { preconditionFailure($0) }

        let silent = try fixture(frequency: 0)
        let tone = try fixture(frequency: 330)
        defer {
            try? FileManager.default.removeItem(at: silent.url)
            try? FileManager.default.removeItem(at: tone.url)
        }

        try audio.play(silent)
        precondition(starts == 0 && audible == 0)
        await waitUntil { starts == 1 }
        try await Task.sleep(for: .milliseconds(200))
        precondition(audible == 0)

        audio.setVolume(0)
        try audio.play(tone)
        await waitUntil { starts == 2 }
        try await Task.sleep(for: .milliseconds(150))
        precondition(audible == 0)

        audio.setVolume(0.15)
        await waitUntil { audible == 1 }
        try await Task.sleep(for: .milliseconds(200))
        precondition(audible == 1 && requests == 0)
        sharing = true
        audio.pause(true)
        try await Task.sleep(for: .milliseconds(150))
        precondition(audible == 1)
        audio.pause(false)
        await waitUntil { audible == 2 && requests == 1 }
        let firstOutput = audio.lastAudioOutput
        try await Task.sleep(for: .milliseconds(200))
        precondition(audible == 2 && audio.lastAudioOutput != firstOutput)

        sharing = false
        stats.cancel()
        audio.pause(true)
        audio.pause(false)
        await waitUntil { audible == 3 }
        precondition(requests == 1)

        try audio.play(tone)
        audio.halt()
        try await Task.sleep(for: .milliseconds(200))
        precondition(starts == 2 && audible == 3 && requests == 1)
        print("Audio output tests passed.")
    }

    static func fixture(frequency: Double) throws -> Source {
        let url = AudioTools.temporary("wav")
        let format = AudioTools.format
        let frameCount = AVAudioFrameCount(format.sampleRate * 3)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let value = Float(sin(2 * .pi * frequency * Double(frame) / format.sampleRate) * 0.2)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                       channels: format.channelCount, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return Source(id: url.absoluteString, title: "Playback test", url: url, episode: true)
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<250 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Expected audio output was not detected")
    }
}
