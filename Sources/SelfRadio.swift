import AppKit
import Combine
import ImageIO

@MainActor final class SelfRadioState: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var muted = false
    @Published private(set) var audioAccessVerified = false
    @Published private(set) var status = "Detection is off."
    @Published private(set) var metadataStatus = ""
    @Published private(set) var track: ExternalMediaTrack?
    @Published private(set) var artwork: URL?
    var onChange: (() -> Void)?
    private var enabled = false
    private var readMetadata = false
    private var defaultPlayer: SelfRadioMusicApp = .music
    private var candidates: [String] = []
    private var metadataTask: Task<Void, Never>?
    private let metadata = ExternalMediaMetadata()
    private var artworkFiles: [String: URL] = [:]
    private var artworkDirectory: URL?
    private lazy var detector = SystemAudioDetector { [weak self] event in
        Task { @MainActor in self?.receive(event) }
    }

    private var resumeBundle: String?
    private var resumePID: Int32?
    private(set) var applicationName: String?
    var displayStatus: String { muted ? "Muted" : active ? "Now Playing" : "Not Playing" }
    var displayDetail: String {
        if let track { return track.display }
        return active ? applicationName.map { "\($0) Playing" } ?? "" : ""
    }
    private func appName(_ bundle: String) -> String? {
        let names = ["com.apple.Music": "Apple Music", "com.spotify.client": "Spotify", "com.apple.Safari": "Safari", "com.google.Chrome": "Chrome", "org.mozilla.firefox": "Firefox", "com.microsoft.edgemac": "Microsoft Edge"]
        if let name = names[bundle] { return name }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { return app.localizedName }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    func configure(enabled: Bool, metadata: Bool, defaultPlayer: SelfRadioMusicApp) {
        let changed = self.enabled != enabled || readMetadata != metadata || self.defaultPlayer != defaultPlayer
        self.enabled = enabled; readMetadata = metadata; self.defaultPlayer = defaultPlayer
        detector.setEnabled(enabled)
        guard changed else { return }
        if !enabled { active = false; muted = false; audioAccessVerified = false; status = "Detection is off."; candidates = []; applicationName = nil }
        restartMetadata()
        onChange?()
    }
    func retry() { metadata.retryPermissions(); detector.retry(); restartMetadata() }
    func pauseExternalAudio() async -> String? {
        let previousPlayer = track?.player
        let previousPID = await SystemMediaControl.externalPlayerPID()
        let result = await metadata.pauseSupportedPlayers()
        if let previousPlayer, result.paused.contains(previousPlayer) { resumeBundle = previousPlayer }
        else if let first = result.paused.first { resumeBundle = first }
        if let previousPID { resumePID = previousPID }
        _ = await SystemMediaControl.pauseExternalPlayer()
        // Give the detector's silence debounce time to confirm the handoff.
        for _ in 0..<15 {
            if Task.isCancelled { return "Playback request cancelled." }
            if !active { return nil }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return "Playback request cancelled." }
        }
        return result.error ?? "External audio is still playing. Pause it in its app to start this station."
    }
    func resumeExternalAudio(defaultPlayer: SelfRadioMusicApp) async -> String? {
        guard !Task.isCancelled, !active else { return nil }
        if let bundle = resumeBundle, await metadata.resumePlayer(bundle: bundle) { return nil }
        if let pid = resumePID, await SystemMediaControl.resumeExternalPlayer(pid: pid) { return nil }
        // Continue a queue in a running music app before launching the configured fallback.
        let players = [defaultPlayer] + SelfRadioMusicApp.allCases.filter { $0 != defaultPlayer }
        for player in players where player.rawValue != resumeBundle {
            guard !Task.isCancelled else { return nil }
            if await metadata.resumePlayer(bundle: player.rawValue) { resumeBundle = player.rawValue; return nil }
        }
        guard !Task.isCancelled, !active else { return nil }
        return await metadata.startDefaultPlayer(defaultPlayer)
    }
    private func receive(_ event: SystemAudioDetector.Event) {
        guard enabled else { return }
        switch event {
        case .muted(let value): muted = value
        case .audioAccessVerified(let value): audioAccessVerified = value
        case .activity(let value):
            if value != active { active = value; restartMetadata() }
        case .status(let message): status = message
        case .candidates(let items):
            if items != candidates {
                candidates = items
                applicationName = items.compactMap { appName($0) }.first
                restartMetadata()
            }
        }
        onChange?()
    }
    private func clearTrack() { track = nil; artwork = nil; metadataStatus = "" }
    private func restartMetadata() {
        metadataTask?.cancel(); metadataTask = nil
        guard readMetadata else { clearTrack(); return }
        metadataTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let available = SelfRadioMusicApp.allCases.map(\.rawValue).filter {
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty
                }
                let audible = active ? candidates.filter { available.contains($0) } : []
                let preferred = [resumeBundle, defaultPlayer.rawValue].compactMap { $0 } + available
                var seen = Set<String>()
                let queued = preferred.filter { available.contains($0) && seen.insert($0).inserted }
                let requests = active ? audible.map { ($0, false) } : queued.map { ($0, true) }
                var selected: ExternalMediaTrack?
                var messages = Set<String>()
                for (bundle, includePaused) in requests {
                    let (value, message) = await metadata.read(bundle: bundle, includePaused: includePaused)
                    guard !Task.isCancelled, readMetadata else { return }
                    if let value { selected = value; break }
                    if let message { messages.insert(message) }
                }
                var changed = false
                if selected != track {
                    let preparedArtwork = if let selected { await cacheArtwork(selected) } else { nil as URL? }
                    guard !Task.isCancelled, readMetadata else { return }
                    track = selected
                    artwork = preparedArtwork
                    changed = true
                }
                let nextStatus = selected == nil ? messages.sorted().joined(separator: " ") : ""
                if metadataStatus != nextStatus { metadataStatus = nextStatus; changed = true }
                if changed { onChange?() }
                do { try await Task.sleep(for: .seconds(active ? 2 : 4)) } catch { return }
            }
        }
    }
    private func cacheArtwork(_ value: ExternalMediaTrack) async -> URL? {
        if let url = value.artworkURL { return url }
        guard let data = value.artworkData else { return nil }
        let key = value.player + ":" + value.id
        if let file = artworkFiles[key] {
            _ = await CoverFlowArtwork.load(file)
            return file
        }
        do {
            if artworkDirectory == nil {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RadioDial-SelfRadio-Art-\(UUID())", isDirectory: true)
                artworkDirectory = directory
            }
            if artworkFiles.count >= 20 {
                let obsolete = Array(artworkFiles.values)
                Task.detached(priority: .utility) { for file in obsolete { try? FileManager.default.removeItem(at: file) } }
                artworkFiles.removeAll()
            }
            let file = artworkDirectory!.appendingPathComponent(UUID().uuidString + ".image")
            try await Task.detached(priority: .utility) {
                guard CGImageSourceCreateWithData(data as CFData, nil) != nil else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }.value
            guard !Task.isCancelled else { try? FileManager.default.removeItem(at: file); return nil }
            artworkFiles[key] = file
            // Decode before publishing this URL so the new cover is already in the shared UI cache.
            _ = await CoverFlowArtwork.load(file)
            return file
        } catch { return nil }
    }
    func shutdown() {
        detector.setEnabled(false)
        metadataTask?.cancel(); metadataTask = nil
        if let directory = artworkDirectory { try? FileManager.default.removeItem(at: directory) }
        artworkDirectory = nil; artworkFiles.removeAll()
    }
}
