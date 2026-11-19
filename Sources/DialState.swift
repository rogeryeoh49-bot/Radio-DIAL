import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

struct Preferences: Codable {
    var favorites: [Source] = []
    var history: [Visit] = []
    var actions: [TimedAction] = []
    var volume = 80.0
    var balance = 0.0
    var eq = [0.0, 0, 0, 0, 0]
    var eqEnabled: Bool?
    var preset = "Flat"
    var customEQ: [String: [Double]] = [:]
    var visualizer = "Spectrum"
    var theme = "vice city"
    var capture = CaptureOptions()
    var last: Source?
    var resumeOnLaunch = true
    var keepInMenuBar = true
    var profile = "Balanced"
    var proxy = ""
    var podcastCountry = "US"
    // Optional for compatibility with settings saved by earlier releases.
    var defaultRadioCountry: String?
    var viEnabled: Bool?
    var viToggleMode: Bool?
    var viImmediatePlayback: Bool?
    var viShortcut: VIShortcut?
    var shortcuts: [String: VIShortcut]?
    var viPreviousKey: VIShortcut?
    var viNextKey: VIShortcut?
    var radioMarket: String?
    var radioBand: String?
    var automaticRecognition = false
    var lastFMUser = ""
    var lastFMKey = ""
    var lastFMEnabled = false
    var discordID = ""
}

@MainActor
final class DialState: ObservableObject {
    nonisolated static let storage = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Radio Dial")
    private let settingsURL: URL
    let audio = StreamAudio()
    let meter = MeterState()
    let links = ListeningLinks()

    @Published var prefs: Preferences { didSet { persist() } }
    @Published var source: Source?
    @Published var track = ""
    @Published var art: URL?
    @Published var appleMusicURL: URL?
    @Published var matchedSong: Catalog.SongMatch?
    @Published var status = "Choose a station to start listening."
    @Published var playback = Playback.stopped
    @Published var recording = false
    @Published var recordStart: Date?
    @Published var recordings: [Source] = []
    @Published var downloads: [Source] = []
    @Published var elapsed = 0.0
    @Published var length = 0.0
    @Published var stationCount: Int?
    @Published var stations = Catalog.featured
    @Published var countries: [Catalog.Country] = []
    @Published var tags = ["pop", "rock", "jazz", "classical", "news", "electronic", "talk", "ambient"]
    @Published var busy = false
    @Published var more = false
    @Published var radioError = ""
    @Published var podcasts: [Source] = []
    @Published var episodes: [Source] = []
    @Published var selectedPodcast: Source?
    @Published var podcastBusy = false
    @Published var podcastError = ""
    @Published var sleepEnd: Date?
    @Published var sleepRemaining = ""
    @Published var lyrics: Catalog.Lyric?
    @Published var lyricStatus = ""
    @Published var finding = false
    @Published var streamLatency: Double?
    @Published var mini = false
    @Published var pane: Pane?
    @Published var section = Section.radio

    enum Playback { case stopped, connecting, playing, paused }
    enum Section: String, CaseIterable { case radio = "Radio", podcasts = "Podcasts", favorites = "Favorites", history = "History", recordings = "Recordings" }
    enum Pane: String, Identifiable {
        case capture, scheduled, alarms, sleep, lyrics, info, settings, theme, playlist, presets, about, stream, custom
        var id: String { rawValue }
    }

    private var radioTask: Task<Void, Never>?
    private var podcastTask: Task<Void, Never>?
    private var lyricTask: Task<Void, Never>?
    private var recognitionTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var retryCount = 0
    private var tick: Timer?
    private var meterTick: Timer?
    private enum TrackOrigin { case none, station, unverifiedStation, recognition }
    private var trackOrigin: TrackOrigin = .none
    private var nextRecognition = Date.distantPast
    private var scheduledStop: Date?
    private var audioStart: TimeInterval?
    private var pauseAfterSeek = false
    private var pausedWhileConnecting = false
    private var healthySince: TimeInterval?
    private var resumedAt: TimeInterval?
    private var offset = 0.0
    private var trackStart = 0.0
    private var loaded = false
    private var radioOffset = 0
    private var transferTask: [String: Task<Void, Never>] = [:]
    var isFavorite: Bool { source.map { current in prefs.favorites.contains(where: { $0.id == current.id }) } ?? false }
    var currentPlaybackTime: Double { offset + audio.elapsed() }
    var currentLyricTime: Double { max(0, elapsed - trackStart) }
    var downloadFolder: URL { Self.storage.appendingPathComponent("Podcasts", isDirectory: true) }

    init(storage: URL = DialState.storage) {
        settingsURL = storage.appendingPathComponent("settings.json")
        var saved = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        saved.visualizer = Scope.currentMode(saved.visualizer)
        saved.theme = DialPalette.currentTheme(saved.theme)
        if saved.viPreviousKey?.keyCode == 50, saved.viPreviousKey?.label == "·" { saved.viPreviousKey?.label = "`" }
        if saved.viNextKey?.keyCode == 50, saved.viNextKey?.label == "·" { saved.viNextKey?.label = "`" }
        prefs = saved
        source = prefs.last
        art = prefs.last?.artwork
        audio.setEQ(prefs.eq)
        audio.setEQEnabled(isEQEnabled)
        applyVolume()
        audio.setBalance(Float(prefs.balance / 100))
        audio.onStarted = { [weak self] outputTime in self?.started(outputTime: outputTime) }
        audio.onFailure = { [weak self] error in self?.failed(error) }
        audio.onEnded = { [weak self] in self?.stop(message: "Playback finished.") }
        audio.onMetadata = { [weak self] title, artwork in
            let track = PlaylistMetadata.icyTrack(title)
            self?.setTrack(track?.name ?? title, artwork: track?.artwork ?? artwork)
        }
        audio.onRecordingInterrupted = { [weak self] message in
            guard let self else { return }
            self.recording = false
            self.recordStart = nil
            self.scheduledStop = nil
            self.status = "Recording: \(message)"
        }
        audio.onSaved = { [weak self] result in
            switch result {
            case .success(let file): self?.status = "Saved \(file.lastPathComponent)"
            case .failure(let error): self?.status = "Recording: \(error.localizedDescription)"
            }
            self?.refreshFiles()
        }
        refreshFiles()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        let meterTimer = Timer(timeInterval: 1 / 24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.playback == .playing else { return }
                self.meter.push(self.audio.frame)
            }
        }
        // AppKit switches run loop modes while tracking a menu.
        RunLoop.main.add(meterTimer, forMode: .common)
        meterTick = meterTimer
    }

    func bootstrap() {
        guard !loaded else { return }
        loaded = true
        searchStations(name: "", country: prefs.defaultRadioCountry ?? "", tag: "", min: 0, sort: "clickcount")
        Task {
            if let stats: Catalog.Stats = try? await Catalog.radio("/json/stats") { stationCount = stats.stations }
        }
        Task {
            if let items: [Catalog.Country] = try? await Catalog.radio("/json/countries", ["hidebroken": "true", "order": "name"]) {
                countries = items.compactMap { country in
                    let name = country.name.replacingOccurrences(of: "_", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !country.id.isEmpty, !name.isEmpty else { return nil }
                    return Catalog.Country(name: name, iso_3166_1: country.id)
                }
            }
        }
        Task {
            if let items: [Catalog.Tag] = try? await Catalog.radio("/json/tags", ["limit": "100", "order": "stationcount", "reverse": "true", "hidebroken": "true"]) {
                tags = items.map(\.name).filter { !$0.isEmpty }
            }
        }
        if prefs.resumeOnLaunch, let source { play(source) }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(prefs).write(to: settingsURL, options: .atomic)
        } catch {
            status = "Couldn’t save preferences: \(error.localizedDescription)"
        }
    }

    func searchStations(name: String, country: String, tag: String, min: Int, sort: String, append: Bool = false) {
        radioTask?.cancel()
        busy = true
        radioError = ""
        let page = append ? radioOffset + 120 : 0
        radioTask = Task {
            do {
                let rows = try await Catalog.stations(name: name, country: country, tag: tag, min: min, sort: sort, offset: page)
                try Task.checkCancellation()
                if append {
                    let existing = Set(stations.map(\.id))
                    stations += rows.filter { !existing.contains($0.id) }
                } else { stations = rows }
                more = rows.count >= 115
                radioOffset = page
                busy = false
            } catch {
                guard !Task.isCancelled else { return }
                radioError = "Station directory unavailable. \(error.localizedDescription)"
                if !append { stations = name.isEmpty && country.isEmpty && tag.isEmpty && min == 0 ? Catalog.featured : [] }
                busy = false
            }
        }
    }

    func searchPodcasts(_ value: String) {
        let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        podcastTask?.cancel()
        podcastBusy = true
        podcastError = ""
        selectedPodcast = nil
        episodes = []
        podcastTask = Task {
            do {
                let results = try await Catalog.podcasts(term, country: prefs.podcastCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
                try Task.checkCancellation()
                podcasts = results
                if results.isEmpty { podcastError = "No podcasts found." }
            } catch {
                guard !Task.isCancelled else { return }
                podcastError = error.localizedDescription
            }
            podcastBusy = false
        }
    }

    func openPodcast(_ podcast: Source) {
        section = .podcasts
        podcastTask?.cancel()
        podcastBusy = true
        podcastError = ""
        selectedPodcast = podcast
        episodes = []
        podcastTask = Task {
            do {
                let results = try await Catalog.episodes(podcast)
                try Task.checkCancellation()
                episodes = results
                if results.isEmpty { podcastError = "No playable episodes were found." }
            } catch {
                guard !Task.isCancelled else { return }
                podcastError = error.localizedDescription
            }
            podcastBusy = false
        }
    }

    func backToPodcasts() {
        podcastTask?.cancel()
        selectedPodcast = nil
        podcastBusy = false
        podcastError = ""
    }

    func open(_ item: Source) {
        if item.feed != nil { openPodcast(item) } else { tune(item) }
    }

    func tune(_ item: Source, tuningEffect: Bool = true) {
        let switchingStations = item.isRadio && source?.isRadio == true &&
            source?.id != item.id && playback != .stopped
        play(item, tuningEffect: switchingStations && tuningEffect)
    }

    func play(_ item: Source, position: Double = 0, retry: Bool = false, log: Bool = true, remainPaused: Bool = false, tuningEffect: Bool = false) {
        reconnectTask?.cancel()
        pausedWhileConnecting = false
        if !retry {
            retryCount = 0
            if source?.id != item.id { stopRecording() }
        }
        if !retry { links.clearTrack() }
        source = item
        if !item.url.isFileURL { prefs.last = item }
        lyricTask?.cancel()
        recognitionTask?.cancel()
        finding = false
        trackTask?.cancel()
        track = ""
        trackOrigin = .none
        appleMusicURL = nil
        matchedSong = nil
        lyrics = nil
        lyricStatus = ""
        art = item.artwork
        pauseAfterSeek = remainPaused
        offset = position
        elapsed = position
        length = 0
        trackStart = position
        meter.reset()
        audioStart = ProcessInfo.processInfo.systemUptime
        healthySince = nil
        resumedAt = nil
        nextRecognition = Date().addingTimeInterval(25)
        do {
            try audio.play(item, seek: position, profile: prefs.profile, proxy: prefs.proxy, tuningEffect: tuningEffect)
            playback = .connecting
            status = retry ? "Reconnecting to \(item.title)…" : "Connecting to \(item.title)…"
            if !retry && log {
                if prefs.history.first?.source.id != item.id { prefs.history = Array(([Visit(source: item)] + prefs.history).prefix(500)) }
            }
        } catch {
            playback = .stopped
            status = error.localizedDescription
        }
    }

    func togglePlayback() {
        switch playback {
        case .playing:
            audio.pause(true)
            playback = .paused
            meter.reset()
            status = "Paused"
        case .paused:
            if pausedWhileConnecting, let source {
                pausedWhileConnecting = false
                play(source, log: false)
                return
            }
            resumedAt = ProcessInfo.processInfo.systemUptime
            healthySince = nil
            audio.pause(false)
            playback = .playing
            status = "Playing \(source?.title ?? "")"
        case .connecting:
            reconnectTask?.cancel()
            audio.halt()
            audioStart = nil
            healthySince = nil
            pausedWhileConnecting = true
            playback = .paused
            meter.reset()
            status = "Paused"
        case .stopped:
            if let source { play(source) } else if let first = stations.first { play(first) }
        }
    }

    func stop(message: String = "Stopped") {
        pausedWhileConnecting = false
        reconnectTask?.cancel()
        recognitionTask?.cancel()
        finding = false
        stopRecording()
        audio.halt()
        playback = .stopped
        meter.reset()
        status = message
        links.clearDiscord(client: prefs.discordID)
    }

    private func started(outputTime: TimeInterval) {
        if let audioStart {
            streamLatency = outputTime - audioStart
            healthySince = outputTime
        }
        if pauseAfterSeek {
            pauseAfterSeek = false
            audio.pause(true)
            playback = .paused
            status = "Paused"
            return
        }
        playback = .playing
        status = "Playing \(source?.title ?? "")"
        if let source { links.discord(client: prefs.discordID, title: source.title, detail: track) }
    }

    private func failed(_ message: String) {
        guard let source, source.isRadio, retryCount < 3 else { stop(message: message); return }
        audio.halt()
        audioStart = nil
        healthySince = nil
        resumedAt = nil
        retryCount += 1
        let delay = retryCount * 2
        playback = .connecting
        status = "Stream interrupted. Reconnecting in \(delay)s…"
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            play(source, retry: true)
        }
    }

    func seek(_ seconds: Double) {
        if let source, !source.isRadio, length > 0, seconds.isFinite {
            play(source, position: max(0, min(length - 1, seconds)), log: false, remainPaused: playback == .paused)
        }
    }

    func setVolume(_ value: Double) { prefs.volume = max(0, min(100, value)); applyVolume() }
    private var muted = false
    func toggleMute() { muted.toggle(); applyVolume(); status = muted ? "Muted" : "Unmuted" }
    private func applyVolume() { audio.setVolume(muted ? 0 : Float(prefs.volume / 100)) }

    func setBalance(_ value: Double) { prefs.balance = value; audio.setBalance(Float(value / 100)) }

    static let presets: [String: [Double]] = [
        "Flat": [0, 0, 0, 0, 0], "Bass Boost": [8, 5, 0, 0, 0], "Treble Boost": [0, 0, 1, 4, 8],
        "Rock": [5, 3, -2, 3, 6], "Pop": [-1, 2, 4, 2, 1], "Jazz": [4, 1, 2, 3, 5],
        "Classical": [5, 2, 0, 2, 4], "Electronic": [7, 4, 0, 3, 5], "Hip-Hop": [8, 4, 0, 1, 3],
        "Voice": [-6, -2, 4, 6, -1], "Loudness": [7, 2, -1, 2, 6], "Soft": [1, 1, 0, -2, -4],
        "Acoustic": [3, 1, 2, 4, 2], "Dance": [7, 4, 1, 3, 4], "Metal": [5, 2, -3, 4, 6],
        "Reggae": [6, 3, 0, -2, -3], "Night": [-5, -2, 1, 0, -3], "Small Speakers": [4, 5, 1, 1, 0],
        "Headphones": [2, 0, 1, 2, 2]
    ]

    enum EQBand: String, CaseIterable {
        case low = "Low", mid = "Mid", high = "High"

        var indices: ClosedRange<Int> {
            switch self {
            case .low: return 0...1
            case .mid: return 2...2
            case .high: return 3...4
            }
        }
    }

    var isEQEnabled: Bool { prefs.eqEnabled ?? false }
    var eqPresetNames: [String] {
        ["Custom"] + Set(Self.presets.keys).union(prefs.customEQ.keys).subtracting(["Custom"]).sorted()
    }

    func setEQEnabled(_ enabled: Bool) {
        prefs.eqEnabled = enabled
        audio.setEQEnabled(enabled)
    }

    func applyPreset(_ key: String) {
        var updated = prefs
        if let values = updated.customEQ[key] ?? Self.presets[key] { updated.eq = values }
        updated.preset = key
        updated.eqEnabled = true
        prefs = updated
        audio.setEQ(updated.eq)
        audio.setEQEnabled(true)
    }

    func gain(for band: EQBand) -> Double {
        let gains = band.indices.map { prefs.eq.indices.contains($0) ? prefs.eq[$0] : 0 }
        return (gains.reduce(0, +) / Double(gains.count)).rounded()
    }

    func setGain(_ band: EQBand, _ value: Double) {
        guard isEQEnabled else { return }
        var updated = prefs
        for index in band.indices where updated.eq.indices.contains(index) {
            updated.eq[index] = value
        }
        updated.preset = "Custom"
        prefs = updated
        audio.setEQ(updated.eq)
    }

    func favorite(_ item: Source) {
        if let index = prefs.favorites.firstIndex(where: { $0.id == item.id }) {
            prefs.favorites.remove(at: index)
            status = "Removed \(item.title) from favorites."
        } else {
            prefs.favorites.append(item)
            status = "Added \(item.title) to favorites."
        }
    }

    func moveFavorite(_ item: Source, by step: Int) {
        guard let index = prefs.favorites.firstIndex(where: { $0.id == item.id }),
              prefs.favorites.indices.contains(index + step) else { return }
        prefs.favorites.swapAt(index, index + step)
    }

    func toggleRecording() {
        if recording { stopRecording(); return }
        guard let source, source.isRadio, playback == .playing else { status = "Play a radio station before recording."; return }
        pane = .capture
    }

    func startRecording(scheduled: Bool = false) {
        guard let source, !recording, scheduled || playback == .playing else { return }
        do {
            try audio.record(source, options: prefs.capture, title: track)
            recording = true
            recordStart = Date()
            status = "Recording \(source.title)"
        } catch { status = error.localizedDescription }
    }

    func stopRecording() {
        scheduledStop = nil
        if recording {
            audio.stopRecording()
            recording = false
            recordStart = nil
            status = "Saving recording…"
        }
    }

    func refreshFiles() {
        recordings = files(in: prefs.capture.folder)
        downloads = files(in: downloadFolder)
    }

    private func files(in folder: URL) -> [Source] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        return urls.filter { ["mp3", "wav", "flac", "ogg", "m4a", "aac", "opus", "mp4"].contains($0.pathExtension.lowercased()) }.sorted {
            ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast)
        }.map { Source(id: $0.absoluteString, title: $0.deletingPathExtension().lastPathComponent,
                       url: $0, subtitle: $0.dateModified?.formatted(date: .abbreviated, time: .shortened) ?? "",
                       codec: $0.pathExtension.uppercased()) }
    }

    func download(_ episode: Source) {
        guard transferTask[episode.id] == nil else { return }
        status = "Downloading \(episode.title)…"
        transferTask[episode.id] = Task {
            defer { transferTask.removeValue(forKey: episode.id) }
            do {
                let (temporary, response) = try await Catalog.downloads.download(from: episode.url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DialError.invalidResponse }
                let ext = URL(fileURLWithPath: response.suggestedFilename ?? "").pathExtension
                let format = ["mp3", "wav", "flac", "ogg", "m4a", "aac", "opus", "mp4"].contains(ext.lowercased()) ? ext : "mp3"
                let destination = downloadFolder.appendingPathComponent(AudioTools.safeName(episode.title) + " • " + String(UUID().uuidString.prefix(5))).appendingPathExtension(format)
                try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: temporary, to: destination)
                refreshFiles()
                status = "Downloaded \(episode.title)"
            } catch { status = "Download: \(error.localizedDescription)" }
        }
    }

    private func setTrack(_ title: String, artwork: URL? = nil, origin: TrackOrigin = .station) {
        let cleaned = title.replacingOccurrences(of: #"\s*-?\s*text=.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedOrigin = origin
        if origin == .station {
            switch TrackMetadataQuality.assess(cleaned, station: source?.title) {
            case .song:
                resolvedOrigin = .station
            case .ambiguous:
                // Keep a recognized song rather than replacing it with an unverified station label.
                if trackOrigin == .recognition { return }
                resolvedOrigin = .unverifiedStation
            case .promotional:
                // Announcements and slogans are not songs. Keep a recognition result if we have one.
                if trackOrigin == .recognition { return }
                if trackOrigin == .station { nextRecognition = min(nextRecognition, Date().addingTimeInterval(3)) }
                if !track.isEmpty { setTrack("", origin: .recognition) }
                trackOrigin = .none
                return
            }
        }
        trackOrigin = cleaned.isEmpty ? .none : resolvedOrigin
        if cleaned == track {
            if let artwork { art = artwork }
            return
        }
        track = cleaned
        appleMusicURL = nil
        matchedSong = nil
        art = artwork ?? source?.artwork
        trackStart = elapsed
        lyrics = nil
        lyricStatus = ""
        lyricTask?.cancel()
        trackTask?.cancel()
        if cleaned.isEmpty {
            links.clearTrack()
            if let source { links.discord(client: prefs.discordID, title: source.title, detail: "") }
            return
        }
        audio.splitRecording(cleaned)
        links.trackChanged(cleaned, prefs: prefs)
        if let source { links.discord(client: prefs.discordID, title: source.title, detail: cleaned) }
        trackTask = Task {
            let match = try? await Catalog.songMatch(cleaned)
            guard !Task.isCancelled, track == cleaned else { return }
            appleMusicURL = match?.appleMusicURL
            matchedSong = match
            if art == source?.artwork, let artwork = match?.artwork { art = artwork }
        }
        if pane == .lyrics { findLyrics(cleaned) }
    }

    func findLyrics(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { lyricStatus = "Enter a song or use Identify."; return }
        lyricTask?.cancel()
        lyrics = nil
        lyricStatus = "Searching LRCLIB…"
        lyricTask = Task {
            do {
                let result = try await Catalog.lyrics(text)
                guard !Task.isCancelled else { return }
                lyrics = result
                lyricStatus = result.instrumental == true ? "Instrumental" : ""
            } catch { if !Task.isCancelled { lyricStatus = error.localizedDescription } }
        }
    }

    func identify(automatic: Bool = false) {
        guard !finding else { return }
        let file: URL
        do { file = try audio.recognitionSample() }
        catch { lyricStatus = "Play at least a few seconds of audio first."; return }
        finding = true
        lyricStatus = "Shazaming…"
        status = "Shazaming…"
        recognitionTask = Task {
            defer {
                try? FileManager.default.removeItem(at: file)
                if !Task.isCancelled {
                    finding = false
                    if lyricStatus == "Shazaming…" { lyricStatus = "" }
                    if status == "Shazaming…", playback == .playing, let source { status = "Playing \(source.title)" }
                }
            }
            do {
                let match = try await Recognition.match(file)
                guard !Task.isCancelled,
                      !automatic || (prefs.automaticRecognition && playback == .playing && trackOrigin != .station) else { return }
                let name = [match.artist, match.title].filter { !$0.isEmpty }.joined(separator: " – ")
                guard !name.isEmpty else { return }
                if track != name { setTrack(name, origin: .recognition) }
                else if !automatic && pane == .lyrics { findLyrics(name) }
                if !automatic && pane != .lyrics { status = "Identified \(name)" }
            } catch {
                if !Task.isCancelled && !automatic {
                    lyricStatus = error.localizedDescription
                    status = error.localizedDescription
                }
            }
        }
    }

    func sleep(minutes: Int) {
        sleepEnd = minutes > 0 ? Date().addingTimeInterval(Double(minutes * 60)) : nil
        update()
    }

    private func checkRadioOutput() {
        guard source?.isRadio == true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if playback == .connecting, let audioStart, now - audioStart > 15 {
            failed("The station did not produce audio.")
        } else if playback == .playing, let output = audio.lastAudioOutput {
            if now - max(output, resumedAt ?? output) > 8 {
                failed("The station stopped producing audio.")
            } else if now - output < 1 {
                if healthySince == nil { healthySince = output }
                if let healthySince, now - healthySince > 25 { retryCount = 0 }
            } else {
                healthySince = nil
            }
        }
    }

    private func update() {
        if playback == .playing || playback == .paused {
            elapsed = currentPlaybackTime
            if audio.duration > 0 { length = audio.duration }
        }
        let now = Date()
        checkRadioOutput()

        if let sleepEnd {
            let seconds = Int(ceil(sleepEnd.timeIntervalSince(now)))
            if seconds <= 0 {
                self.sleepEnd = nil
                sleepRemaining = ""
                stop(message: "Sleep timer finished.")
            } else { sleepRemaining = String(format: "%d:%02d", seconds / 60, seconds % 60) }
        } else { sleepRemaining = "" }
        if let scheduledStop, scheduledStop <= now { stopRecording() }
        if let index = prefs.actions.firstIndex(where: { $0.isDue(at: now) }) {
            let action = prefs.actions[index]
            prefs.actions[index].lastRun = now
            if action.repeatRule == .once { prefs.actions[index].enabled = false }
            if action.mode == .recording && recording {
                status = "Scheduled recording “\(action.name)” was skipped because a recording is active."
            } else {
                play(action.source)
                if action.mode == .recording {
                    startRecording(scheduled: true)
                    scheduledStop = now.addingTimeInterval(Double(action.duration * 60))
                }
            }
        }
        if prefs.automaticRecognition && playback == .playing && source?.isRadio == true && now >= nextRecognition {
            nextRecognition = now.addingTimeInterval(60)
            if trackOrigin != .station { identify(automatic: true) }
        }
        if playback == .playing { links.tick(prefs: prefs) }
    }

    func importList() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["m3u", "m3u8", "pls"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            let items = try Playlist.read(file)
            let known = Set(prefs.favorites.map(\.url))
            var seen = known
            let new = items.filter { seen.insert($0.url).inserted }
            prefs.favorites.append(contentsOf: new)
            status = "Imported \(new.count) stations."
        } catch { status = error.localizedDescription }
    }

    func exportList(_ format: String) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: format) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = "Radio Dial Favorites.\(format)"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do { try Playlist.write(prefs.favorites.filter(\.isRadio), to: file); status = "Exported \(file.lastPathComponent)" }
        catch { status = error.localizedDescription }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.capture.folder
        if panel.runModal() == .OK, let folder = panel.url { prefs.capture.folder = folder; refreshFiles() }
    }

    func openFolder(_ url: URL) {
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
        catch { status = error.localizedDescription }
    }

    func openStream(_ address: String, name: String) {
        guard let url = Catalog.webURL(address) else { status = DialError.invalidURL.localizedDescription; return }
        tune(Source(id: url.absoluteString, title: name.isEmpty ? url.host ?? "Stream" : name, url: url))
    }

    func test(_ item: Source) {
        status = "Testing \(item.title)…"
        Task {
            do {
                let start = Date()
                var request = URLRequest(url: item.url)
                request.timeoutInterval = 12
                let (bytes, response) = try await Catalog.session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DialError.invalidResponse }
                var iterator = bytes.makeAsyncIterator()
                guard try await iterator.next() != nil else { throw DialError.noAudio }
                status = String(format: "%@ responded in %.2fs", item.title, Date().timeIntervalSince(start))
            } catch { status = "Stream test: \(error.localizedDescription)" }
        }
    }

    func vote(_ item: Source) {
        guard UUID(uuidString: item.id) != nil else { status = "This stream has no directory entry."; return }
        Task {
            do {
                struct Vote: Decodable { var ok: Bool; var message: String }
                let response: Vote = try await Catalog.radio("/json/vote/\(item.id)")
                status = response.message
            } catch { status = error.localizedDescription }
        }
    }
}

final class MeterState: ObservableObject {
    @Published private(set) var frame = MeterFrame()
    private(set) var history: [[Float]] = []
    private var ticksUntilHistory = 0

    func push(_ incoming: MeterFrame) {
        var next = incoming
        next.bars = zip(frame.bars, incoming.bars).map { Self.smooth(from: $0.0, to: $0.1) }
        next.left = Self.smooth(from: frame.left, to: incoming.left)
        next.right = Self.smooth(from: frame.right, to: incoming.right)
        if ticksUntilHistory == 0 {
            history.append(next.bars)
            if history.count > 20 { history.removeFirst() }
            ticksUntilHistory = 2
        } else {
            ticksUntilHistory -= 1
        }
        frame = next
    }

    func reset() {
        history.removeAll(keepingCapacity: true)
        ticksUntilHistory = 0
        frame = MeterFrame()
    }

    private static func smooth(from current: Float, to target: Float) -> Float {
        // Follow new peaks quickly, then let the display settle over several frames.
        current + (target - current) * (target > current ? 0.42 : 0.18)
    }
}

private extension URL {
    var dateModified: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}
