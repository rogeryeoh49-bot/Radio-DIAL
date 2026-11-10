import Foundation

struct Source: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var url: URL
    var subtitle = ""
    var country = ""
    var tags = ""
    var codec = ""
    var bitrate = 0
    var artwork: URL?
    var website: URL?
    var feed: URL?
    var episode = false
    var votes = 0

    var isRadio: Bool { feed == nil && !episode && !url.isFileURL }
}

struct Visit: Codable, Identifiable {
    var id = UUID()
    var source: Source
    var date = Date()
}

struct TimedAction: Codable, Identifiable {
    enum Mode: String, Codable, CaseIterable { case alarm = "Alarm", recording = "Recording" }
    enum Repeat: String, Codable, CaseIterable {
        case once = "Once", daily = "Daily", weekdays = "Weekdays", weekend = "Weekend", custom = "Selected days"
    }
    var id = UUID()
    var mode: Mode
    var name: String
    var source: Source
    var date: Date
    var repeatRule: Repeat
    var duration: Int
    var days: Set<Int> = []
    var enabled = true
    var lastRun: Date?

    func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, now >= date, lastRun.map({ !calendar.isDate($0, inSameDayAs: now) }) ?? true else { return false }
        if repeatRule == .once { return now.timeIntervalSince(date) < 60 }
        let target = calendar.dateComponents([.hour, .minute], from: date)
        let current = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard target.hour == current.hour, target.minute == current.minute else { return false }
        let weekday = current.weekday ?? 1
        switch repeatRule {
        case .once, .daily: return true
        case .weekdays: return (2...6).contains(weekday)
        case .weekend: return weekday == 1 || weekday == 7
        case .custom: return days.contains(weekday)
        }
    }
}

struct CaptureOptions: Codable, Equatable {
    var format = "mp3"
    var bitrate = 192
    var split = false
    var prefix = ""
    var artist = ""
    var album = ""
    var folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Radio Dial")
}

enum DialError: LocalizedError {
    case invalidResponse, noAudio, missingDecoder, invalidURL, noLyrics, noTrack
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The service didn’t return a usable response."
        case .noAudio: return "No audio was received from this source."
        case .missingDecoder: return "FFmpeg was not found. Install it with Homebrew or set the FFMPEG_PATH environment variable."
        case .invalidURL: return "Enter a valid HTTP or HTTPS address."
        case .noLyrics: return "No lyrics found for this track."
        case .noTrack: return "No track was identified. Try another part of the song."
        }
    }
}

enum Catalog {
    static let mirrors = ["https://all.api.radio-browser.info", "https://de1.api.radio-browser.info", "https://nl1.api.radio-browser.info"]
    static let featured = [
        Source(id: "rtl", title: "RTL", url: URL(string: "https://live.m6radio.quortex.io/webM89Hc99XApzgfhXNX8ASN5/grouprtl/national/short/audio-64000/index.m3u8")!, country: "France", tags: "news, talk", codec: "AAC", bitrate: 64),
        Source(id: "classic-vinyl", title: "Classic Vinyl HD", url: URL(string: "https://icecast.walmradio.com:8443/classic")!, country: "USA", tags: "oldies, jazz", codec: "MP3", bitrate: 320),
        Source(id: "mango", title: "MANGORADIO", url: URL(string: "https://mangoradio.stream.laut.fm/mangoradio")!, country: "Germany", tags: "pop, variety", codec: "MP3", bitrate: 128)
    ]

    static let session = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": "RadioDial/1.0 (macOS radio and podcast player)"]
        return config
    }())

    static let downloads = URLSession(configuration: {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": "RadioDial/1.0 (macOS radio and podcast player)"]
        return config
    }())

    static func request(_ url: URL, using session: URLSession = session) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw DialError.invalidResponse }
        return data
    }

    static func url(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        return components.url!
    }

    static func radio<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        var last: Error = DialError.invalidResponse
        for host in mirrors {
            try Task.checkCancellation()
            do { return try JSONDecoder().decode(T.self, from: await request(url(host + path, query))) }
            catch { last = error }
        }
        throw last
    }

    struct Station: Decodable {
        var stationuuid, name, url, url_resolved, homepage, favicon, country, tags, codec: String
        var bitrate, votes: Int
        var source: Source? {
            guard let stream = webURL(url_resolved) ?? webURL(url) else { return nil }
            return Source(id: stationuuid, title: name.trimmingCharacters(in: .whitespacesAndNewlines), url: stream,
                          country: country, tags: tags, codec: codec, bitrate: bitrate,
                          artwork: webURL(favicon), website: webURL(homepage), votes: votes)
        }
    }
    struct Stats: Decodable { var stations: Int }
    struct Country: Decodable, Identifiable {
        var name: String
        var iso_3166_1: String
        var id: String { iso_3166_1 }
    }
    struct Tag: Decodable { var name: String }

    static func stations(name: String, country: String, tag: String, min: Int, sort: String, offset: Int) async throws -> [Source] {
        var query = ["hidebroken": "true", "order": sort, "reverse": sort == "name" ? "false" : "true", "limit": "120", "offset": String(offset)]
        if !name.isEmpty { query["name"] = name }
        if !country.isEmpty { query["countrycode"] = country }
        if !tag.isEmpty { query["tag"] = tag }
        if min > 0 { query["bitrateMin"] = String(min) }
        let rows: [Station] = try await radio("/json/stations/search", query)
        return rows.compactMap(\.source)
    }

    struct Podcasts: Decodable {
        struct Item: Decodable {
            var collectionId: Int?
            var collectionName, artistName, feedUrl, artworkUrl600, collectionViewUrl: String?
            var source: Source? {
                guard let id = collectionId, let name = collectionName, let feed = webURL(feedUrl) else { return nil }
                return Source(id: "podcast-\(id)", title: name, url: feed, subtitle: artistName ?? "", artwork: webURL(artworkUrl600), website: webURL(collectionViewUrl), feed: feed)
            }
        }
        var results: [Item]
    }

    static func podcasts(_ term: String, country: String) async throws -> [Source] {
        let data = try await request(url("https://itunes.apple.com/search", ["term": term, "media": "podcast", "entity": "podcast", "limit": "40", "country": country]))
        return try JSONDecoder().decode(Podcasts.self, from: data).results.compactMap(\.source)
    }

    static func episodes(_ podcast: Source) async throws -> [Source] {
        let parser = XMLParser(data: try await request(podcast.feed ?? podcast.url))
        let delegate = FeedReader(podcast: podcast)
        parser.delegate = delegate
        guard parser.parse() || !delegate.episodes.isEmpty else { throw parser.parserError ?? DialError.invalidResponse }
        return delegate.episodes
    }

    static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    static func artwork(_ track: String) async throws -> URL? {
        struct Result: Decodable {
            struct Track: Decodable { var artworkUrl100: String? }
            var results: [Track]
        }
        let data = try await request(url("https://itunes.apple.com/search", ["term": track, "entity": "song", "limit": "1"]))
        return webURL(try JSONDecoder().decode(Result.self, from: data).results.first?.artworkUrl100)
    }

    struct Lyric: Decodable {
        var trackName, artistName: String
        var plainLyrics, syncedLyrics: String?
        var instrumental: Bool?
    }

    static func lyrics(_ track: String) async throws -> Lyric {
        let data = try await request(url("https://lrclib.net/api/search", ["q": track]))
        let lyrics = try JSONDecoder().decode([Lyric].self, from: data)
        let words = CharacterSet.alphanumerics.inverted
        func normalized(_ value: String) -> String {
            value.lowercased().components(separatedBy: words).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let exact = lyrics.filter {
            normalized($0.artistName + " " + $0.trackName) == normalized(track) ||
            normalized($0.trackName + " " + $0.artistName) == normalized(track)
        }
        let candidates = exact.isEmpty ? lyrics : exact
        guard let result = candidates.first(where: { $0.syncedLyrics != nil }) ?? candidates.first else { throw DialError.noLyrics }
        return result
    }
}

private final class FeedReader: NSObject, XMLParserDelegate {
    let podcast: Source
    var episodes: [Source] = []
    private var stack: [String] = []
    private var title = ""
    private var date = ""
    private var media: URL?
    private var cover: URL?

    init(podcast: Source) { self.podcast = podcast }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let key = element.lowercased()
        stack.append(key)
        if key == "item" || key == "entry" { title = ""; date = ""; media = nil; cover = nil }
        guard stack.contains("item") || stack.contains("entry") else { return }
        if key == "enclosure" || (key == "link" && attributes["rel"] == "enclosure") {
            media = Catalog.webURL(attributes["url"] ?? attributes["href"])
        }
        if key == "itunes:image" { cover = Catalog.webURL(attributes["href"]) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let key = stack.last, stack.contains("item") || stack.contains("entry") else { return }
        if key == "title" { title += string }
        if ["pubdate", "published", "updated"].contains(key) { date += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let value = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        if ["item", "entry"].contains(element.lowercased()), let media, !title.isEmpty {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            episodes.append(Source(id: media.absoluteString, title: clean, url: media, subtitle: podcast.title,
                                   tags: date.trimmingCharacters(in: .whitespacesAndNewlines), artwork: cover ?? podcast.artwork, episode: true))
        }
        _ = stack.popLast()
    }
}

enum Playlist {
    static func read(_ file: URL) throws -> [Source] {
        let data = try Data(contentsOf: file)
        let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var title = ""
        var files: [Int: URL] = [:]
        var titles: [Int: String] = [:]
        var result: [Source] = []
        for line in content.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if line.hasPrefix("#EXTINF:"), let comma = line.firstIndex(of: ",") {
                title = String(line[line.index(after: comma)...])
            } else if let url = Catalog.webURL(line) {
                result.append(Source(id: url.absoluteString, title: title.isEmpty ? url.host ?? line : title, url: url))
                title = ""
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].lowercased()
                let value = String(line[line.index(after: equals)...])
                if key.hasPrefix("file"), let number = Int(key.dropFirst(4)), let url = Catalog.webURL(value) { files[number] = url }
                if key.hasPrefix("title"), let number = Int(key.dropFirst(5)) { titles[number] = value }
            }
        }
        result += files.keys.sorted().compactMap { key in
            files[key].map { Source(id: $0.absoluteString, title: titles[key] ?? $0.host ?? "Station", url: $0) }
        }
        return result
    }

    static func write(_ stations: [Source], to file: URL) throws {
        let lines = stations.enumerated().map { index, source -> String in
            let title = source.title.components(separatedBy: .newlines).joined(separator: " ")
            return file.pathExtension.lowercased() == "pls"
                ? "File\(index + 1)=\(source.url)\nTitle\(index + 1)=\(title)\nLength\(index + 1)=-1\n"
                : "#EXTINF:-1,\(title)\n\(source.url)\n"
        }.joined()
        let text = file.pathExtension.lowercased() == "pls"
            ? "[playlist]\n\(lines)NumberOfEntries=\(stations.count)\nVersion=2\n"
            : "#EXTM3U\n\(lines)"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}
