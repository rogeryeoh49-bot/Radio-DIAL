import AppKit

enum SelfRadioMusicApp: String, Codable, CaseIterable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"

    var name: String { self == .music ? "Apple Music" : "Spotify" }

    var startScript: String {
        switch self {
        case .music:
            return """
            if (count of tracks of library playlist 1) is 0 then return 3
            set shuffle mode to songs
            set shuffle enabled to true
            play library playlist 1
            return 2
            """
        case .spotify:
            return """
            try
                set shuffling to true
            end try
            play
            return 2
            """
        }
    }
}

struct ExternalMediaTrack: Sendable, Equatable {
    let player: String
    let id: String
    let title: String
    let artist: String
    let album: String
    var artworkData: Data?
    var artworkURL: URL?
    var display: String { artist.isEmpty ? title : "\(artist) - \(title)" }
}

/// Reads only the documented Music/Spotify scripting dictionaries. No MediaRemote/private APIs.
final class ExternalMediaMetadata: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.radiodial.self-radio.metadata", qos: .utility)
    private var cached: ExternalMediaTrack?
    private var denied = Set<String>()

    func read(bundle: String, includePaused: Bool) async -> (ExternalMediaTrack?, String?) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in continuation.resume(returning: readPlayer(bundle, includePaused: includePaused)) }
        }
    }
    func retryPermissions() { queue.async { [self] in denied.removeAll() } }

    private func readPlayer(_ bundle: String, includePaused: Bool) -> (ExternalMediaTrack?, String?) {
        guard SelfRadioMusicApp(rawValue: bundle) != nil else { return (nil, nil) }
        guard !denied.contains(bundle) else { return (nil, "Track information access was denied. Allow Radio Dial under Privacy & Security → Automation, then retry.") }
        let music = bundle == "com.apple.Music"
        let fields = music ? "{player state as text, persistent ID of current track, name of current track, artist of current track, album of current track}" : "{player state as text, id of current track, name of current track, artist of current track, album of current track, artwork url of current track}"
        let stateGuard = includePaused ? "if player state is stopped then return {}" : "if player state is not playing then return {}"
        // Metadata queries must never launch a player.
        let source = """
        if application id "\(bundle)" is not running then return {}
        with timeout of 2 seconds
            tell application id "\(bundle)"
                \(stateGuard)
                try
                    return \(fields)
                on error errorMessage number errorNumber
                    if errorNumber is -1728 or errorNumber is -1700 then return {}
                    error errorMessage number errorNumber
                end try
            end tell
        end timeout
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (nil, "Couldn’t prepare the player metadata request.") }
        let result = script.executeAndReturnError(&error)
        if let error {
            if error[NSAppleScript.errorNumber] as? Int == -1743 { denied.insert(bundle) }
            return (nil, "Track information unavailable. Check Radio Dial’s Automation permission for \(music ? "Music" : "Spotify").")
        }
        guard result.numberOfItems >= 5, let state = result.atIndex(1)?.stringValue,
              state == "playing" || (includePaused && state == "paused"),
              let id = result.atIndex(2)?.stringValue, let title = result.atIndex(3)?.stringValue, !title.isEmpty else { cached = nil; return (nil, nil) }
        var track = ExternalMediaTrack(player: bundle, id: id, title: title,
                                       artist: result.atIndex(4)?.stringValue ?? "", album: result.atIndex(5)?.stringValue ?? "")
        if let cached, cached.player == bundle, cached.id == id, cached.title == title { return (cached, nil) }
        if music {
            // Artwork is optional; an unavailable/cloud-only artwork never hides the station logo.
            let artworkScript = NSAppleScript(source: """
            if application id "com.apple.Music" is not running then return missing value
            with timeout of 2 seconds
                tell application id "com.apple.Music"
                    if player state is not stopped and persistent ID of current track is "\(id.replacingOccurrences(of: "\"", with: ""))" then
                        if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track
                    end if
                end tell
            end timeout
            """)
            var artError: NSDictionary?
            if let descriptor = artworkScript?.executeAndReturnError(&artError), artError == nil,
               !descriptor.data.isEmpty, descriptor.data.count <= 12 * 1024 * 1024 {
                track.artworkData = descriptor.data
            }
        } else if let value = result.atIndex(6)?.stringValue, let url = URL(string: value), url.scheme == "https" {
            track.artworkURL = url
        }
        cached = track
        return (track, nil)
    }
}

extension ExternalMediaMetadata {
    /// Never launches a player, resumes playback, or changes its volume.
    func pauseSupportedPlayers() async -> (error: String?, paused: [String]) {
        let running = await MainActor.run {
            ["com.apple.Music", "com.spotify.client"].filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var errors: [String] = []
                var paused: [String] = []
                for bundle in running {
                    if denied.contains(bundle) { errors.append(bundle == "com.apple.Music" ? "Music" : "Spotify"); continue }
                    var error: NSDictionary?
                    let script = NSAppleScript(source: """
                    with timeout of 2 seconds
                        tell application id "\(bundle)"
                            if player state is playing then
                                pause
                                return true
                            end if
                            return false
                        end tell
                    end timeout
                    """)
                    let result = script?.executeAndReturnError(&error)
                    if error == nil, result?.booleanValue == true { paused.append(bundle) }
                    if let error {
                        if error[NSAppleScript.errorNumber] as? Int == -1743 { denied.insert(bundle) }
                        errors.append(bundle == "com.apple.Music" ? "Music" : "Spotify")
                    }
                }
                continuation.resume(returning: (errors.isEmpty ? nil : "Allow Automation access to pause \(errors.joined(separator: " and ")).", paused))
            }
        }
    }
}

extension ExternalMediaMetadata {
    private enum PlaybackStart: Int32 {
        case waiting = 0, playing, requested, empty, unavailable, denied
    }

    @MainActor
    func startDefaultPlayer(_ player: SelfRadioMusicApp) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.rawValue) else {
            return "Install \(player.name) or pick another default music app in Settings."
        }
        let application: NSRunningApplication
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: player.rawValue).first {
            application = running
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            do { application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
            catch { return "Couldn’t open \(player.name)." }
        }
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(8)
        while !application.isFinishedLaunching, !application.isTerminated, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return nil }
        }

        // The process can finish launching before its queue or library is ready.
        // Once a play request is accepted, check its state before sending another.
        var result = PlaybackStart.waiting
        var checksSinceRequest = 0
        for _ in 0..<8 {
            guard !Task.isCancelled else { return nil }
            guard !application.isTerminated else { return "Couldn’t start playback in \(player.name)." }
            let sendPlay = checksSinceRequest == 0 || checksSinceRequest == 4
            result = await requestPlayback(in: player, sendPlay: sendPlay, preferRestoredQueue: checksSinceRequest == 0)
            switch result {
            case .playing: return nil
            case .denied: return "Allow Radio Dial to control \(player.name) in Privacy & Security → Automation."
            case .requested, .waiting: checksSinceRequest += 1
            case .empty, .unavailable: break
            }
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return nil }
        }
        if player == .music, result == .empty {
            return "Add songs to your Apple Music library to start shuffle playback."
        }
        return player == .spotify
            ? "Choose something to play in Spotify; its queue is empty or unavailable."
            : "Couldn’t start playback in \(player.name)."
    }

    private func requestPlayback(in player: SelfRadioMusicApp, sendPlay: Bool, preferRestoredQueue: Bool) async -> PlaybackStart {
        guard !Task.isCancelled else { return .waiting }
        let queueRestore = player == .music && preferRestoredQueue ? """
            try
                if exists current track then
                    play
                    return 2
                end if
            end try
            """ : ""
        let action = sendPlay ? """
            if player state is paused then
                play
                return 2
            end if
            \(queueRestore)
            \(player.startScript)
            """ : "return 0"
        return await withCheckedContinuation { continuation in
            queue.async {
                let script = NSAppleScript(source: """
                if application id "\(player.rawValue)" is not running then return 4
                with timeout of 2 seconds
                    tell application id "\(player.rawValue)"
                        if player state is playing then return 1
                        \(action)
                    end tell
                end timeout
                """)
                var error: NSDictionary?
                let result = script?.executeAndReturnError(&error)
                if error?[NSAppleScript.errorNumber] as? Int == -1743 {
                    continuation.resume(returning: .denied)
                } else if error == nil, let result, let state = PlaybackStart(rawValue: result.int32Value) {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
    }

    func resumePlayer(bundle: String) async -> Bool {
        guard !Task.isCancelled, SelfRadioMusicApp(rawValue: bundle) != nil,
              await MainActor.run(body: { !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty }) else { return false }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !denied.contains(bundle) else { continuation.resume(returning: false); return }
                var error: NSDictionary?
                let script = NSAppleScript(source: """
                with timeout of 2 seconds
                    tell application id "\(bundle)"
                        if player state is paused then play
                        return player state is playing
                    end tell
                end timeout
                """)
                let result = script?.executeAndReturnError(&error)
                continuation.resume(returning: error == nil && result?.booleanValue == true)
            }
        }
    }
}
