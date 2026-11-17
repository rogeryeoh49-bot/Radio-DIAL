import AppKit
import Combine
import Foundation
import ImageIO
import MediaPlayer

@MainActor
final class NowPlaying {
    private let info = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private weak var dial: DialState?
    private var observation: AnyCancellable?
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkLoad: Task<Void, Never>?
    private var targets: [(MPRemoteCommand, Any)] = []

    init(dial: DialState) {
        self.dial = dial
        register(commands.playCommand) { dial, _ in
            if dial.playback == .paused || (dial.playback == .stopped && dial.source != nil) {
                dial.togglePlayback()
            }
        }
        register(commands.pauseCommand) { dial, _ in
            if dial.playback == .playing || dial.playback == .connecting { dial.togglePlayback() }
        }
        register(commands.togglePlayPauseCommand) { dial, _ in
            if dial.playback != .stopped || dial.source != nil { dial.togglePlayback() }
        }
        register(commands.stopCommand) { dial, _ in dial.stop() }
        register(commands.changePlaybackPositionCommand) { dial, position in
            if let position, dial.playback == .playing || dial.playback == .paused { dial.seek(position) }
        }

        commands.nextTrackCommand.isEnabled = false
        commands.previousTrackCommand.isEnabled = false
        // Deliver after @Published has stored values, including the other fields changed by a tune.
        observation = Publishers.CombineLatest4(dial.$playback, dial.$source, dial.$track, dial.$length)
            .combineLatest(dial.$art)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor (DialState, Double?) -> Void) {
        let target = command.addTarget { [weak dial] event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            guard position?.isFinite != false else { return .commandFailed }
            Task { @MainActor in
                if let dial { action(dial, position) }
            }
            return .success
        }
        targets.append((command, target))
    }

    private func refresh() {
        guard let dial else { return }
        let active = dial.playback != .stopped && dial.source != nil
        let canSeek = active && dial.source?.isRadio == false && dial.length.isFinite && dial.length > 0
        commands.playCommand.isEnabled = active
        commands.pauseCommand.isEnabled = active
        commands.togglePlayPauseCommand.isEnabled = active
        commands.stopCommand.isEnabled = active
        commands.changePlaybackPositionCommand.isEnabled = canSeek

        loadArtwork(active ? dial.art : nil)
        guard active, let source = dial.source else {
            info.playbackState = .stopped
            info.nowPlayingInfo = nil
            return
        }
        var metadata: [String: Any] = [
            MPMediaItemPropertyTitle: dial.track.isEmpty ? source.title : dial.track,
            MPNowPlayingInfoPropertyIsLiveStream: source.isRadio,
            MPNowPlayingInfoPropertyPlaybackRate: dial.playback == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !dial.track.isEmpty { metadata[MPMediaItemPropertyArtist] = source.title }
        if let artwork { metadata[MPMediaItemPropertyArtwork] = artwork }
        if canSeek {
            metadata[MPMediaItemPropertyPlaybackDuration] = dial.length
            metadata[MPNowPlayingInfoPropertyElapsedPlaybackTime] = dial.playback == .connecting ? dial.elapsed : dial.currentPlaybackTime
        }
        info.nowPlayingInfo = metadata
        switch dial.playback {
        case .playing: info.playbackState = .playing
        case .paused: info.playbackState = .paused
        case .connecting: info.playbackState = .interrupted
        case .stopped: info.playbackState = .stopped
        }
    }

    private func loadArtwork(_ url: URL?) {
        guard artworkURL != url else { return }
        artworkLoad?.cancel()
        artworkLoad = nil
        artworkURL = url
        artwork = nil
        guard let url else { return }

        artworkLoad = Task { [weak self] in
            guard let image = try? await Self.artworkThumbnail(from: url),
                  !Task.isCancelled, let self, self.dial?.art == url,
                  self.dial?.playback != .stopped else { return }
            let size = NSSize(width: image.width, height: image.height)
            let cover = NSImage(cgImage: image, size: size)
            self.artwork = MPMediaItemArtwork(boundsSize: size) { _ in cover }
            self.refresh()
        }
    }

    private nonisolated static func artworkThumbnail(from url: URL) async throws -> CGImage? {
        let request = URLRequest(url: url, timeoutInterval: 8)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let image = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(image, 0, options)
    }

    func tearDown() {
        loadArtwork(nil)
        observation?.cancel()
        observation = nil
        for (command, target) in targets {
            command.isEnabled = false
            command.removeTarget(target)
        }
        targets.removeAll()
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }
}
