import AVFoundation
@main struct Test {
    static func main() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = VISelectionTone.makeBuffer(format: format)!
        let count = Int(buffer.frameLength)
        precondition(count == 7_056)
        let left = buffer.floatChannelData![0]
        let right = buffer.floatChannelData![1]
        var peak: Float = 0
        for index in 0..<count {
            precondition(left[index].isFinite && left[index] == right[index])
            peak = max(peak, abs(left[index]))
        }
        precondition(peak > 0.1 && peak < 0.4)
        precondition(left[0] == 0 && left[count - 1] == 0)
        let clip = VISelectionTone.loadBuffer(from: URL(fileURLWithPath: "Resources/VI-radio-selection.wav"))!
        precondition(clip.format.channelCount == 2)
        precondition(clip.format.sampleRate == 44_100)
        precondition((11_400...11_500).contains(Int(clip.frameLength)))
        for channel in 0..<2 {
            let samples = clip.floatChannelData![channel]
            for index in 0..<Int(clip.frameLength) { precondition(samples[index].isFinite && abs(samples[index]) < 0.4) }
            precondition(abs(samples[Int(clip.frameLength) - 1]) < 0.001)
        }
        print("Selection tone and imported audio format, duration, headroom and boundaries passed")
    }
}
