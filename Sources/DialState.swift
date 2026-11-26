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
    var gettingStartedCompleted: Bool?
    var defaultRadioCountry: String?
    var viEnabled: Bool?
    var selfRadioEnabled: Bool?
    var selfRadioMetadata: Bool?
    var selfRadioMusicApp: SelfRadioMusicApp?
    var viToggleMode: Bool?
    var viBackgroundStrength: Double?
    var viBackgroundDarkness: Double?
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
    private let hadPreferencesAtLaunch: Bool
    var shouldShowGettingStarted: Bool {
        if let completed = prefs.gettingStartedCompleted { return !completed }
        return !hadPreferencesAtLaunch
    }
    let audio = StreamAudio()
    let meter = MeterState()
    let links = ListeningLinks()
    let selfRadio = SelfRadioState()
    private var selfRadioHandoff: Task<Void, Never>?
    private var selfRadioPlaybackTask: Task<Void, Never>?
    private var handingOffSelfRadio = false
    var waitingForExternalAudio: Bool { handingOffSelfRadio }
    var carouselStations: [Source] {
        let favorites = prefs.favorites
        let currentOutsideDirectory = source.flatMap { current in
            stations.contains(where: { $0.id == current.id }) ? nil : current
        }
        let ordered = [Source.selfRadio] + favorites + (currentOutsideDirectory.map { [$0] } ?? []) + stations
        var seen = Set<String>()
        return ordered.filter { $0.isStation && seen.insert($0.id).inserted }
    }

    @Published var prefs: Preferences {
        didSet {
            if !deferringPreferenceSave { persist() }
        }
    }
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
    @Published var gettingStartedStep: GettingStartedStep?
    @Published var section = Section.radio

    enum Playback { case stopped, connecting, playing, paused }
    enum Section: String, CaseIterable { case radio = "Radio", podcasts = "Podcasts", favorites = "Favorites", history = "History", recordings = "Recordings" }
    enum Pane: String, Identifiable {
        case capture, scheduled, alarms, sleep, lyrics, info, theme, playlist, presets, about, stream, custom
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
    private var deferringPreferenceSave = false
    private var preferenceSaveTask: Task<Void, Never>?
    private enum TrackOrigin { case none, station, unverifiedStation, recognition }
    private var trackOrigin: TrackOrigin = .none
    private var lastStationMetadata: PlaylistMetadata?
    private var needsSongArtwork = false
    private var trackArtworkPixels = 0
    private var nextRecognition = Date.distantPast
    private var lastAutomaticRecognition = Date.distantPast
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
        hadPreferencesAtLaunch = FileManager.default.fileExists(atPath: settingsURL.path)
        var saved = (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
        saved.visualizer = Scope.currentMode(saved.visualizer)
        saved.theme = DialPalette.currentTheme(saved.theme)
        if saved.viPreviousKey?.keyCode == 50, saved.viPreviousKey?.label == "·" { saved.viPreviousKey?.label = "`" }
        if saved.viNextKey?.keyCode == 50, saved.viNextKey?.label == "·" { saved.viNextKey?.label = "`" }
        prefs = saved
        source = prefs.last
        art = prefs.last?.stationArtwork
        audio.setEQ(prefs.eq)
        audio.setEQEnabled(isEQEnabled)
        applyVolume()
        audio.setBalance(Float(prefs.balance / 100))
        audio.onStarted = { [weak self] outputTime in self?.started(outputTime: outputTime) }
        audio.onFailure = { [weak self] error in self?.failed(error) }
        audio.onEnded = { [weak self] in self?.stop(message: "Playback finished.") }
        audio.onMetadata = { [weak self] metadata in
            self?.receiveStationTrack(metadata)
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
        selfRadio.onChange = { [weak self] in self?.refreshSelfRadio() }
    }

    func bootstrap() {
        guard !loaded else { return }
        loaded = true
        configureSelfRadio()
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

    private func updateAudioPreferences(_ updated: Preferences) {
        deferringPreferenceSave = true
        prefs = updated
        deferringPreferenceSave = false
        preferenceSaveTask?.cancel()
        preferenceSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    func flushPendingPreferences() {
        if preferenceSaveTask != nil { persist() }
    }

    private func persist() {
        preferenceSaveTask?.cancel()
        preferenceSaveTask = nil
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(prefs).write(to: settingsURL, options: .atomic)
        } catch {
            status = "Couldn’t save preferences: \(error.localizedDescription)"
        }
    }

    func configureSelfRadio() {
        if prefs.selfRadioEnabled == true { try? audio.prepareSystemAudioMonitoring() }
        selfRadio.configure(enabled: prefs.selfRadioEnabled ?? false, metadata: prefs.selfRadioMetadata ?? false,
                            defaultPlayer: prefs.selfRadioMusicApp ?? .music)
    }

    private func refreshSelfRadio() {
        objectWillChange.send()
        // External sound takes priority; the user's explicit station request performs the reverse handoff.
        if selfRadio.active, !handingOffSelfRadio, source?.isSelfRadio != true {
            stop()
            source = .selfRadio
        }
        guard !handingOffSelfRadio else { return }
        guard source?.isSelfRadio == true else { return }
        let nextTrack = selfRadio.displayDetail
        let nextArt = selfRadio.artwork ?? Source.selfRadio.artwork
        let nextPlayback: Playback = selfRadio.active ? .playing : .stopped
        if track != nextTrack { track = nextTrack }
        if art != nextArt { art = nextArt }
        if appleMusicURL != nil { appleMusicURL = nil }
        if matchedSong != nil { matchedSong = nil }
        if playback != nextPlayback { playback = nextPlayback }
        if elapsed != 0 { elapsed = 0 }
        if length != 0 { length = 0 }
        if status != selfRadio.displayStatus { status = selfRadio.displayStatus }
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

    func play(_ item: Source, position: Double = 0, retry: Bool = false, log: Bool = true, remainPaused: Bool = false, tuningEffect: Bool = false, externalHandoffComplete: Bool = false) {
        if item.isSelfRadio {
            if source?.isSelfRadio == true, selfRadio.active { return }
            stop()
            source = .selfRadio
            refreshSelfRadio()
            selfRadioPlaybackTask = Task { [weak self] in
                guard let self else { return }
                let message = await selfRadio.resumeExternalAudio(defaultPlayer: prefs.selfRadioMusicApp ?? .music)
                if !Task.isCancelled, source?.isSelfRadio == true, let message { status = message }
            }
            return
        }
        if prefs.selfRadioEnabled == true, !retry, !externalHandoffComplete {
            selfRadioHandoff?.cancel()
            stop()
            handingOffSelfRadio = true
            source = item
            track = ""; art = item.stationArtwork; appleMusicURL = nil; matchedSong = nil
            playback = .connecting
            status = "Pausing external audio…"
            selfRadioHandoff = Task { [weak self] in
                guard let self else { return }
                let error = await selfRadio.pauseExternalAudio()
                guard !Task.isCancelled else { return }
                handingOffSelfRadio = false
                selfRadioHandoff = nil
                if let error {
                    source = .selfRadio
                    refreshSelfRadio()
                    status = error
                } else {
                    play(item, position: position, log: log, remainPaused: remainPaused, tuningEffect: tuningEffect, externalHandoffComplete: true)
                }
            }
            return
        }
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
        lastStationMetadata = nil
        needsSongArtwork = false
        trackArtworkPixels = 0
        appleMusicURL = nil
        matchedSong = nil
        lyrics = nil
        lyricStatus = ""
        art = item.stationArtwork
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
        lastAutomaticRecognition = .distantPast
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
        if handingOffSelfRadio {
            stop(message: "Paused")
            if selfRadio.active { source = .selfRadio; refreshSelfRadio() }
            return
        }
        if source?.isSelfRadio == true {
            selfRadioPlaybackTask?.cancel()
            let pause = selfRadio.active
            selfRadioPlaybackTask = Task { [weak self] in
                guard let self else { return }
                let message = pause ? await selfRadio.pauseExternalAudio()
                    : await selfRadio.resumeExternalAudio(defaultPlayer: prefs.selfRadioMusicApp ?? .music)
                if !Task.isCancelled, source?.isSelfRadio == true, let message { status = message }
            }
            return
        }
        switch playback {
        case .playing:
            audio.pause(true)
            playback = .paused
            meter.reset()
            status = "Paused"
        case .paused:
            if prefs.selfRadioEnabled == true, let source {
                play(source, position: source.isRadio ? 0 : elapsed, log: false)
                return
            }
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
        selfRadioPlaybackTask?.cancel(); selfRadioPlaybackTask = nil
        selfRadioHandoff?.cancel(); selfRadioHandoff = nil
        handingOffSelfRadio = false
        pausedWhileConnecting = false
        reconnectTask?.cancel()
        recognitionTask?.cancel()
        trackTask?.cancel()
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

    func setVolume(_ value: Double) {
        let volume = max(0, min(100, value))
        guard prefs.volume != volume else { return }
        var updated = prefs
        updated.volume = volume
        updateAudioPreferences(updated)
        applyVolume()
    }
    private var muted = false
    func toggleMute() { muted.toggle(); applyVolume(); status = muted ? "Muted" : "Unmuted" }
    private func applyVolume() { audio.setVolume(muted ? 0 : Float(prefs.volume / 100)) }

    func setBalance(_ value: Double) {
        guard prefs.balance != value else { return }
        var updated = prefs
        updated.balance = value
        updateAudioPreferences(updated)
        audio.setBalance(Float(value / 100))
    }

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
        updateAudioPreferences(updated)
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
        guard let source, !source.isSelfRadio, !recording, scheduled || playback == .playing else { return }
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

    private func receiveStationTrack(_ metadata: PlaylistMetadata) {
        guard metadata != lastStationMetadata else { return }
        let previous = lastStationMetadata
        lastStationMetadata = metadata
        let cleaned = metadata.name.replacingOccurrences(of: #"\s*-?\s*text=.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch metadata.artistOnly ? .ambiguous : TrackMetadataQuality.assess(cleaned, station: source?.title) {
        case .song:
            setTrack(cleaned, origin: .station)
            loadTrackDetails(cleaned, artwork: [metadata.artwork], searchCatalog: true)
        case .ambiguous:
            if trackOrigin == .recognition, previous?.name == metadata.name { return }
            let label = metadata.artistOnly ? cleaned : TrackMetadataQuality.availableLabel(cleaned)
            setTrack(label, origin: .unverifiedStation)
            if let artwork = metadata.artwork {
                loadTrackDetails(label, artwork: [artwork], searchCatalog: false)
            }
            scheduleRecognition(after: 12)
        case .promotional:
            // Station IDs can arrive between music updates.
            if trackOrigin == .recognition { return }
            if trackOrigin == .station { scheduleRecognition(after: 3) }
            setTrack("", origin: .none)
        }
    }

    private func scheduleRecognition(after delay: TimeInterval) {
        let soon = max(Date().addingTimeInterval(delay), lastAutomaticRecognition.addingTimeInterval(20))
        nextRecognition = min(nextRecognition, soon)
    }

    private func setTrack(_ name: String, origin: TrackOrigin) {
        trackOrigin = name.isEmpty ? .none : origin
        guard track != name else { return }
        track = name
        appleMusicURL = nil
        matchedSong = nil
        art = source?.stationArtwork
        needsSongArtwork = false
        trackArtworkPixels = 0
        trackStart = elapsed
        lyrics = nil
        lyricStatus = ""
        lyricTask?.cancel()
        trackTask?.cancel()
        if name.isEmpty {
            links.clearTrack()
            if let source { links.discord(client: prefs.discordID, title: source.title, detail: "") }
            return
        }
        if origin != .unverifiedStation {
            audio.splitRecording(name)
            links.trackChanged(name, prefs: prefs)
            if pane == .lyrics { findLyrics(name) }
        } else {
            links.clearTrack()
        }
        if let source { links.discord(client: prefs.discordID, title: source.title, detail: name) }
    }

    private func loadTrackDetails(_ title: String, artwork: [URL?], searchCatalog: Bool) {
        trackTask?.cancel()
        needsSongArtwork = false
        trackTask = Task {
            async let match = searchCatalog ? try? Catalog.songMatch(title) : nil
            await showTrackArtwork(artwork)
            let song = await match
            guard !Task.isCancelled else { return }
            appleMusicURL = song?.appleMusicURL
            matchedSong = song
            if trackArtworkPixels < Catalog.artworkMaxPixels {
                await showTrackArtwork([song?.originalArtwork ?? song?.artwork])
            }
            if !Task.isCancelled, trackArtworkPixels < Catalog.artworkMinimumHD, trackOrigin == .station {
                needsSongArtwork = true
                scheduleRecognition(after: 3)
            }
        }
    }

    private func showTrackArtwork(_ candidates: [URL?]) async {
        var seen = Set<URL>()
        for url in candidates.compactMap({ $0 }) where url != source?.stationArtwork && seen.insert(url).inserted {
            guard !Task.isCancelled else { return }
            guard let image = await CoverFlowArtwork.load(url), !Task.isCancelled else { continue }
            let pixels = Catalog.artworkPixels(image)
            guard pixels > trackArtworkPixels else { continue }
            trackArtworkPixels = pixels
            art = url
            if pixels >= Catalog.artworkMaxPixels { return }
        }
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
        guard source?.isSelfRadio != true, !finding else { return }
        let file: URL
        do { file = try audio.recognitionSample() }
        catch {
            if automatic { nextRecognition = Date().addingTimeInterval(5) }
            else { lyricStatus = "Play at least a few seconds of audio first." }
            return
        }
        if automatic { lastAutomaticRecognition = Date() }
        let trackAtSample = track
        let artworkOnly = automatic && trackOrigin == .station
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
                      !automatic || (prefs.automaticRecognition && playback == .playing &&
                          track == trackAtSample) else { return }
                let name = [match.artist, match.title].filter { !$0.isEmpty }.joined(separator: " – ")
                guard !name.isEmpty else { return }
                let artwork = [match.artwork, match.originalArtwork]
                if artworkOnly {
                    guard needsSongArtwork, trackOrigin == .station,
                          Catalog.SongQuery(trackAtSample).matches(title: match.title, artist: match.artist) else { return }
                    loadTrackDetails(name, artwork: artwork, searchCatalog: !match.artist.isEmpty)
                    return
                }
                if automatic && trackOrigin == .station { return }
                let unchanged = track == name
                setTrack(name, origin: .recognition)
                if !unchanged || trackArtworkPixels < Catalog.artworkMaxPixels {
                    loadTrackDetails(name, artwork: artwork, searchCatalog: !match.artist.isEmpty)
                }
                if unchanged && !automatic && pane == .lyrics { findLyrics(name) }
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
        if source?.isSelfRadio != true, playback == .playing || playback == .paused {
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
        if prefs.automaticRecognition && playback == .playing && source?.isRadio == true &&
            (trackOrigin != .station || needsSongArtwork) && !finding && now >= nextRecognition {
            nextRecognition = now.addingTimeInterval(45)
            identify(automatic: true)
        }
        if source?.isSelfRadio != true, playback == .playing { links.tick(prefs: prefs) }
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
