import Accelerate
import AVFoundation
import Foundation
import ShazamKit

enum AudioTools {
    static var ffmpeg: URL? {
        let paths = [ProcessInfo.processInfo.environment["FFMPEG_PATH"], "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return paths.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static func temporary(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("RadioDial-\(UUID()).\(suffix)")
    }

    static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    static func safeName(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: separators).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Recording" : String(cleaned.prefix(100))
    }
}

struct MeterFrame {
    var bars = Array(repeating: Float.zero, count: 32)
    var waveform = Array(repeating: Float.zero, count: 128)
    var left: Float = 0
    var right: Float = 0
}

private final class Analyzer {
    private static let fftSize = 2048
    private let setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private let window: [Float] = (0..<fftSize).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(fftSize - 1)) }
    private let edges: [Double] = (0...32).map {
        let hz = 45 * pow(16_000.0 / 45, Double($0) / 32)
        return hz * Double(fftSize) / AudioTools.format.sampleRate
    }
    deinit { vDSP_destroy_fftsetup(setup) }

    func frame(_ buffer: AVAudioPCMBuffer) -> MeterFrame {
        guard let channels = buffer.floatChannelData, buffer.frameLength == Self.fftSize else { return MeterFrame() }
        let left = channels[0], right = channels[1]
        let count = Self.fftSize
        var frame = MeterFrame()
        vDSP_rmsqv(left, 1, &frame.left, vDSP_Length(count))
        vDSP_rmsqv(right, 1, &frame.right, vDSP_Length(count))

        let mono = (0..<count).map { (left[$0] + right[$0]) * 0.5 }
        // Trigger on a rising zero crossing so adjacent scope traces line up.
        let trigger = (8..<512).first {
            mono[$0 - 1] <= 0 && mono[$0] > 0 && mono[$0 + 8] - mono[$0 - 8] > 0.035
        } ?? 0
        let previous = mono[max(0, trigger - 1)]
        let fraction = trigger == 0 ? Float.zero : -previous / (mono[trigger] - previous)
        for index in frame.waveform.indices {
            let sample = max(0, trigger - 1) + index * 8
            frame.waveform[index] = mono[sample] + (mono[sample + 1] - mono[sample]) * fraction
        }

        var real = zip(mono, window).map { $0.0 * $0.1 }
        var imaginary = Array(repeating: Float.zero, count: count)
        real.withUnsafeMutableBufferPointer { re in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, 11, FFTDirection(FFT_FORWARD))
            }
        }
        func magnitude(_ bin: Int) -> Float { hypotf(real[bin], imaginary[bin]) }

        for band in frame.bars.indices {
            let midpoint = sqrt(edges[band] * edges[band + 1])
            let bin = Int(midpoint)
            let left = magnitude(bin)
            let estimate = left + (magnitude(bin + 1) - left) * Float(midpoint - Double(bin))
            let first = Int(ceil(edges[band]))
            let last = Int(edges[band + 1])
            var peak = estimate
            if first <= last {
                for bin in first...last { peak = max(peak, magnitude(bin)) }
            }
            let db = 20 * log10(max(0.0001, peak / (Float(count) / 4)))
            frame.bars[band] = min(1, max(0, (db + 62) / 55))
        }
        return frame
    }
}

final class StreamAudio {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 5)
    private var reader: Decoder?
    private let capture = Capture()
    var onFailure: (String) -> Void = { _ in }
    var onStarted: () -> Void = {}
    var onMetadata: (String, URL?) -> Void = { _, _ in }
    var onEnded: () -> Void = {}
    var onSaved: (Result<URL, Error>) -> Void = { _ in }
    private var icy: ICY?
    private var playlistMetadata: Task<Void, Never>?
    var frame: MeterFrame { reader?.latest ?? MeterFrame() }
    var duration: Double { reader?.duration ?? 0 }

    init() {
        engine.attach(node)
        engine.attach(equalizer)
        engine.connect(node, to: equalizer, format: AudioTools.format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: AudioTools.format)
        for (index, hz) in [Float(60), 250, 1_000, 4_000, 16_000].enumerated() {
            let band = equalizer.bands[index]
            band.filterType = .parametric
            band.frequency = hz
            band.bandwidth = 1.65
            band.bypass = false
        }
        capture.onSaved = { [weak self] in self?.onSaved($0) }
    }

    func play(_ source: Source, seek: Double = 0, profile: String = "Balanced", proxy: String = "") throws {
        halt()
        guard let executable = AudioTools.ffmpeg else { throw DialError.missingDecoder }
        if !engine.isRunning { try engine.start() }
        let decoder = Decoder(node: node, capture: capture)
        let isPlaylist = source.isRadio && ["m3u", "m3u8"].contains(source.url.pathExtension.lowercased())
        if isPlaylist {
            decoder.onPlaylist = { [weak self, weak decoder] url in
                guard let self, self.reader === decoder else { return }
                self.watchPlaylist(url, proxy: proxy)
            }
        }
        reader = decoder
        decoder.onStarted = { [weak self, weak decoder] in
            guard let self, self.reader === decoder else { return }
            if isPlaylist && self.playlistMetadata == nil { self.watchPlaylist(source.url, proxy: proxy) }
            self.onStarted()
        }
        decoder.onExit = { [weak self, weak decoder] decoded, error in
            guard let self, self.reader === decoder else { return }
            if decoded && !source.isRadio { self.onEnded() }
            else { self.onFailure(error ?? DialError.noAudio.localizedDescription) }
        }
        try decoder.start(executable: executable, source: source, seek: seek, profile: profile, proxy: proxy)
        node.play()
        if source.isRadio && !isPlaylist {
            let monitor = ICY()
            icy = monitor
            monitor.start(source.url, proxy: proxy) { [weak self, weak monitor] title in
                guard let self, self.icy === monitor else { return }
                self.onMetadata(title, nil)
            }
        }
    }

    private func watchPlaylist(_ url: URL, proxy: String) {
        playlistMetadata?.cancel()
        playlistMetadata = Task { @MainActor [weak self] in
            await PlaylistMetadata.watch(url, proxy: proxy) { [weak self] track in
                self?.onMetadata(track.name, track.artwork)
            }
        }
    }

    func halt() {
        playlistMetadata?.cancel()
        playlistMetadata = nil
        icy?.stop()
        icy = nil
        reader?.stop()
        reader = nil
        node.stop()
    }

    func pause(_ paused: Bool) { if paused { node.pause() } else { node.play() } }
    func setVolume(_ value: Float) { node.volume = value }
    func setBalance(_ value: Float) { node.pan = value }
    func setEQ(_ values: [Double]) {
        for (band, gain) in zip(equalizer.bands, values) { band.gain = Float(gain) }
    }
    func elapsed() -> Double {
        guard let render = node.lastRenderTime, let time = node.playerTime(forNodeTime: render) else { return 0 }
        return max(0, Double(time.sampleTime) / time.sampleRate)
    }

    func record(_ source: Source, options: CaptureOptions, title: String) throws {
        try capture.start(source, options: options, title: title)
    }
    func stopRecording() { capture.finish() }
    func afterRecordingsSaved(_ handler: @escaping () -> Void) { capture.afterSaved(handler) }
    func splitRecording(_ title: String) { capture.split(title) }
    func recognitionSample() throws -> URL {
        guard let reader else { throw DialError.noAudio }
        return try reader.sample()
    }
}

private final class Decoder {
    private let node: AVAudioPlayerNode
    private let capture: Capture
    private let process = Process()
    private let output = Pipe()
    private let errors = Pipe()
    private let slots: DispatchSemaphore
    private let analyzer = Analyzer()
    private let lock = NSLock()
    private var stopped = false
    private let meterLock = NSLock()
    private var last = MeterFrame()
    private var snippets: [Data] = []
    private var details = ""
    private var reportedPlaylist = false
    private var length: Double = 0
    var onStarted: () -> Void = {}
    var onPlaylist: (URL) -> Void = { _ in }
    var onExit: (Bool, String?) -> Void = { _, _ in }
    var latest: MeterFrame { meterLock.withLock { last } }
    var duration: Double { lock.withLock { length } }

    init(node: AVAudioPlayerNode, capture: Capture) {
        self.node = node
        self.capture = capture
        slots = DispatchSemaphore(value: 9)
    }

    func start(executable: URL, source: Source, seek: Double, profile: String, proxy: String) throws {
        process.executableURL = executable
        var args = ["-hide_banner", "-nostdin", "-loglevel", "info"]
        if !source.url.isFileURL {
            args += ["-rw_timeout", "12000000", "-reconnect", "1", "-reconnect_streamed", "1", "-reconnect_delay_max", "3"]
            if profile == "Low latency" { args += ["-analyzeduration", "1000000", "-probesize", "32768"] }
            if profile == "Stable" { args += ["-analyzeduration", "6000000", "-probesize", "1500000"] }
            if !proxy.isEmpty { args += ["-http_proxy", proxy] }
        }
        if seek > 0 { args += ["-ss", String(seek)] }
        args += ["-i", source.url.isFileURL ? source.url.path : source.url.absoluteString, "-vn", "-sn", "-dn",
                 "-ac", "2", "-ar", "44100", "-c:a", "pcm_f32le", "-f", "f32le", "pipe:1"]
        process.arguments = args
        process.standardOutput = output
        process.standardError = errors
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            self.lock.withLock {
                self.details = String((self.details + text).suffix(4000))
                if !self.reportedPlaylist,
                   let opening = self.details.range(of: #"(?m)^\[hls @ [^\]]+\] Opening 'https?://[^'\r\n]+\.m3u8(?:\?[^'\r\n]*)?' for reading"#, options: .regularExpression),
                   let address = self.details[opening].split(separator: "'").dropFirst().first,
                   let playlist = Catalog.webURL(String(address)) {
                    self.reportedPlaylist = true
                    DispatchQueue.main.async { self.onPlaylist(playlist) }
                }
                if let range = self.details.range(of: #"Duration: [0-9]+:[0-9]+:[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression) {
                    let pieces = self.details[range].dropFirst(10).split(separator: ":").compactMap { Double($0) }
                    if pieces.count == 3 { self.length = pieces[0] * 3600 + pieces[1] * 60 + pieces[2] }
                }
            }
        }
        do { try process.run() }
        catch { errors.fileHandleForReading.readabilityHandler = nil; throw error }
        DispatchQueue.global(qos: .userInitiated).async { self.consume() }
    }

    func stop() {
        lock.withLock { stopped = true }
        slots.signal()
        if process.isRunning { process.terminate() }
    }

    private func consume() {
        let handle = output.fileHandleForReading
        var started = false
        var pending = Data()
        let batch = 2048 * 2 * MemoryLayout<Float>.size
        while !lock.withLock({ stopped }) {
            let bytes = (try? handle.read(upToCount: batch - pending.count)) ?? Data()
            pending.append(bytes)
            if pending.count < batch && !bytes.isEmpty { continue }
            let count = pending.count / 8
            if count == 0 { break }
            slots.wait()
            if lock.withLock({ stopped }) { break }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioTools.format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            pending.withUnsafeBytes { raw in
                for i in 0..<count {
                    channels[0][i] = raw.loadUnaligned(fromByteOffset: i * 8, as: Float.self)
                    channels[1][i] = raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: Float.self)
                }
            }
            let frame = analyzer.frame(buffer)
            let queued = lock.withLock {
                guard !stopped else { return false }
                snippets.append(pending)
                if snippets.count > 300 { snippets.removeFirst() }
                capture.append(buffer)
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self, slots] _ in
                    // Display the buffer just heard, rather than audio still in the queue.
                    if let self { self.meterLock.withLock { self.last = frame } }
                    slots.signal()
                }
                return true
            }
            if !queued { break }
            if !started {
                started = true
                DispatchQueue.main.async { self.onStarted() }
            }
            pending.removeAll(keepingCapacity: true)
            if bytes.isEmpty { break }
        }
        if !lock.withLock({ stopped }) {
            for _ in 0..<9 {
                if lock.withLock({ stopped }) { break }
                if slots.wait(timeout: .now() + 0.65) == .timedOut { break }
            }
        }
        if lock.withLock({ stopped }) { return }
        let wasStarted = started
        let message = lock.withLock {
            details.components(separatedBy: .newlines).reversed().first {
                $0.contains("Error") || $0.contains("failed") || $0.contains("Forbidden")
            }?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        DispatchQueue.main.async { self.onExit(wasStarted, message) }
    }

    func sample() throws -> URL {
        let packets = lock.withLock { snippets }
        guard packets.count > 60 else { throw DialError.noAudio }
        let url = AudioTools.temporary("wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16
        ])
        for packet in packets {
            let count = packet.count / 8
            guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioTools.format, frameCapacity: AVAudioFrameCount(count)),
                  let channels = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            packet.withUnsafeBytes { raw in
                for i in 0..<count {
                    channels[0][i] = raw.loadUnaligned(fromByteOffset: i * 8, as: Float.self)
                    channels[1][i] = raw.loadUnaligned(fromByteOffset: i * 8 + 4, as: Float.self)
                }
            }
            try file.write(from: buffer)
        }
        return url
    }
}

private final class Capture {
    private struct Part {
        let temporary: URL
        let output: URL
        let title: String
        var file: AVAudioFile?
        var frames = 0
    }
    private let lock = NSLock()
    private let conversion = DispatchQueue(label: "RadioDial.recording-encode")
    private var part: Part?
    private var source: Source?
    private var options = CaptureOptions()
    var onSaved: (Result<URL, Error>) -> Void = { _ in }

    func start(_ source: Source, options: CaptureOptions, title: String) throws {
        try lock.withLock {
            guard part == nil else { return }
            try FileManager.default.createDirectory(at: options.folder, withIntermediateDirectories: true)
            self.options = options
            self.source = source
            part = try makePart(title: title)
        }
    }

    private func makePart(title: String) throws -> Part {
        let label = options.prefix.isEmpty ? source?.title ?? "Radio" : options.prefix
        let safe = AudioTools.safeName(options.split && !title.isEmpty ? "\(label) – \(title)" : label)
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let name = "\(safe) • \(date.string(from: Date())) • \(UUID().uuidString.prefix(5))"
        let output = options.folder.appendingPathComponent(name).appendingPathExtension(options.format)
        let temporary = options.folder.appendingPathComponent(".RadioDial-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: temporary, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16
        ])
        return Part(temporary: temporary, output: output, title: title, file: file)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file = part?.file else { return }
            do {
                try file.write(from: buffer)
                part?.frames += Int(buffer.frameLength)
            } catch {
                finishLocked()
                DispatchQueue.main.async { self.onSaved(.failure(error)) }
            }
        }
    }

    func split(_ title: String) {
        lock.withLock {
            guard options.split, !title.isEmpty, let part, part.title != title else { return }
            finishLocked()
            do { self.part = try makePart(title: title) }
            catch { DispatchQueue.main.async { self.onSaved(.failure(error)) } }
        }
    }

    func finish() { lock.withLock { finishLocked() } }
    func afterSaved(_ handler: @escaping () -> Void) { conversion.async { DispatchQueue.main.async(execute: handler) } }

    private func finishLocked() {
        guard var saved = part else { return }
        part = nil
        saved.file = nil
        let options = self.options
        let fallbackTitle = source?.title ?? "Radio"
        conversion.async {
            do {
                if saved.frames == 0 {
                    try? FileManager.default.removeItem(at: saved.temporary)
                    throw DialError.noAudio
                }
                guard let executable = AudioTools.ffmpeg else { throw DialError.missingDecoder }
                let result = saved.output.deletingLastPathComponent().appendingPathComponent(".RadioDial-\(UUID()).\(options.format)")
                defer { try? FileManager.default.removeItem(at: result) }
                let process = Process()
                process.executableURL = executable
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                var arguments = ["-nostdin", "-v", "error", "-i", saved.temporary.path, "-metadata", "title=\(saved.title.isEmpty ? fallbackTitle : saved.title)"]
                if !options.artist.isEmpty { arguments += ["-metadata", "artist=\(options.artist)"] }
                if !options.album.isEmpty { arguments += ["-metadata", "album=\(options.album)"] }
                if ["mp3", "ogg"].contains(options.format) { arguments += ["-b:a", "\(options.bitrate)k"] }
                process.arguments = arguments + [result.path]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw DialError.invalidResponse }
                try FileManager.default.moveItem(at: result, to: saved.output)
                try? FileManager.default.removeItem(at: saved.temporary)
                DispatchQueue.main.async { self.onSaved(.success(saved.output)) }
            } catch {
                if FileManager.default.fileExists(atPath: saved.temporary.path) {
                    let recovery = saved.output.deletingPathExtension().appendingPathExtension("wav")
                    try? FileManager.default.moveItem(at: saved.temporary, to: recovery)
                }
                DispatchQueue.main.async { self.onSaved(.failure(error)) }
            }
        }
    }
}

private final class ICY: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var interval = 0
    private var skip = 0
    private var metadataLength: Int?
    private var bytes = Data()
    private var previous = ""
    private var report: (String) -> Void = { _ in }

    func start(_ url: URL, proxy: String, report: @escaping (String) -> Void) {
        self.report = report
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 86_400
        if let proxy = URL(string: proxy), let host = proxy.host, let port = proxy.port {
            config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "Icy-MetaData")
        request.setValue("RadioDial/1.0", forHTTPHeaderField: "User-Agent")
        session?.dataTask(with: request).resume()
    }

    func stop() { session?.invalidateAndCancel(); session = nil }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        interval = Int((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "icy-metaint") ?? "") ?? 0
        skip = interval
        completionHandler(interval > 0 ? .allow : .cancel)
        if interval <= 0 { session.finishTasksAndInvalidate() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bytes.append(data)
        while !bytes.isEmpty {
            if skip > 0 {
                let consumed = min(skip, bytes.count)
                bytes.removeFirst(consumed)
                skip -= consumed
                continue
            }
            if metadataLength == nil { metadataLength = Int(bytes.removeFirst()) * 16 }
            guard let count = metadataLength, bytes.count >= count else { return }
            let block = Data(bytes.prefix(count))
            bytes.removeFirst(count)
            metadataLength = nil
            skip = interval
            guard count > 0, let string = String(data: block, encoding: .utf8) ?? String(data: block, encoding: .isoLatin1),
                  let start = string.range(of: "StreamTitle='"),
                  let end = string.range(of: "';", range: start.upperBound..<string.endIndex) else { continue }
            let title = String(string[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, title != previous {
                previous = title
                DispatchQueue.main.async { self.report(title) }
            }
        }
    }
}

enum Recognition {
    struct Match: Decodable { var artist: String; var title: String }
    private struct Failure: Decodable { var error: String }
    static func match(_ sample: URL) async throws -> Match {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Radio Dial")
        let python = support.appendingPathComponent("Recognition/bin/python")
        if FileManager.default.isExecutableFile(atPath: python.path),
           let script = Bundle.main.url(forResource: "recognize", withExtension: "py") {
            return try await Task.detached {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = python
                process.arguments = [script.path, sample.path]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0, let match = try? JSONDecoder().decode(Match.self, from: data) { return match }
                if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                    throw NSError(domain: "RadioDial.Recognition", code: 1, userInfo: [NSLocalizedDescriptionKey: failure.error])
                }
                throw DialError.noTrack
            }.value
        }

        let generator = SHSignatureGenerator()
        let input = try AVAudioFile(forReading: sample)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)) else { throw DialError.noAudio }
        try input.read(into: buffer)
        try generator.append(buffer, at: nil)
        let session = SHSession()
        switch await session.result(from: generator.signature()) {
        case .match(let match):
            guard let item = match.mediaItems.first, let title = item.title else { throw DialError.noTrack }
            return Match(artist: item.artist ?? "", title: title)
        case .noMatch: throw DialError.noTrack
        case .error(let error, _): throw error
        @unknown default: throw DialError.noTrack
        }
    }
}
