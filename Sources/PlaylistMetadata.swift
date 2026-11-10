import Foundation

struct PlaylistMetadata: Equatable {
    let name: String
    let artwork: URL?

    @MainActor
    static func watch(_ source: URL, proxy: String, report: (PlaylistMetadata) -> Void) async {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "RadioDial/1.0"]
        if let proxy = URL(string: proxy), let host = proxy.host, let port = proxy.port {
            config.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var mediaURL = source
        var previous: PlaylistMetadata?

        while !Task.isCancelled {
            do {
                let (data, response) = try await session.data(from: mediaURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let playlist = String(data: data, encoding: .utf8) else { throw DialError.invalidResponse }
                let lines = playlist.components(separatedBy: .newlines)
                if let index = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }),
                   let variant = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                   let resolved = URL(string: variant, relativeTo: response.url ?? mediaURL)?.absoluteURL,
                   resolved != mediaURL, mediaURL == source {
                    mediaURL = resolved
                    continue
                }
                guard lines.contains(where: { $0.hasPrefix("#EXT-X-TARGETDURATION:") }) else { return }
                try Task.checkCancellation()
                if let track = current(in: lines), track != previous {
                    previous = track
                    report(track)
                }
            } catch {
                mediaURL = source
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    static func current(in lines: [String]) -> PlaylistMetadata? {
        let segments = lines.filter { $0.hasPrefix("#EXTINF:") }
        // The decoder starts a live playlist three segments back.
        guard let segment = segments.suffix(3).first, let title = field("title", in: segment) else { return nil }
        let artist = field("artist", in: segment)
        let name = [artist, title].compactMap { $0 }.joined(separator: " – ")
        let payload = field("url", in: segment) ?? ""
        let artwork = field("amgArtworkURL", in: payload, boundary: #"\b"#).flatMap(Catalog.webURL)
        if artist == nil, artwork == nil, let spot = field("song_spot", in: payload, boundary: #"\b"#), spot != "M" {
            return PlaylistMetadata(name: "", artwork: nil)
        }
        return PlaylistMetadata(name: name, artwork: artwork)
    }

    private static func field(_ key: String, in text: String, boundary: String = #"(?:^|,)\s*"#) -> String? {
        let pattern = boundary + key + #"="((?:\\.|[^"\\])*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\"#, with: "\\")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
