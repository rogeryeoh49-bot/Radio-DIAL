import Foundation
import Combine

struct RadioMarket: Identifiable {
    let id, name, state: String
    let latitude, longitude: Double
    var label: String { "\(name), \(state)" }
    static let all: [RadioMarket] = [
        .init(id: "nyc", name: "New York City", state: "NY", latitude: 40.7128, longitude: -74.0060),
        .init(id: "la", name: "Los Angeles", state: "CA", latitude: 34.0522, longitude: -118.2437),
        .init(id: "miami", name: "Miami", state: "FL", latitude: 25.7617, longitude: -80.1918),
        .init(id: "chicago", name: "Chicago", state: "IL", latitude: 41.8781, longitude: -87.6298),
        .init(id: "sf", name: "San Francisco", state: "CA", latitude: 37.7749, longitude: -122.4194),
        .init(id: "dc", name: "Washington", state: "DC", latitude: 38.9072, longitude: -77.0369),
        .init(id: "boston", name: "Boston", state: "MA", latitude: 42.3601, longitude: -71.0589),
        .init(id: "seattle", name: "Seattle", state: "WA", latitude: 47.6062, longitude: -122.3321),
        .init(id: "houston", name: "Houston", state: "TX", latitude: 29.7604, longitude: -95.3698),
        .init(id: "dfw", name: "Dallas–Fort Worth", state: "TX", latitude: 32.8998, longitude: -97.0403),
        .init(id: "atlanta", name: "Atlanta", state: "GA", latitude: 33.7490, longitude: -84.3880),
        .init(id: "philly", name: "Philadelphia", state: "PA", latitude: 39.9526, longitude: -75.1652),
        .init(id: "detroit", name: "Detroit", state: "MI", latitude: 42.3314, longitude: -83.0458),
        .init(id: "vegas", name: "Las Vegas", state: "NV", latitude: 36.1699, longitude: -115.1398),
        .init(id: "orlando", name: "Orlando", state: "FL", latitude: 28.5383, longitude: -81.3792)
    ]
}

enum BroadcastBand: String, Codable { case fm = "FM", am = "AM" }
struct BroadcastStation: Codable, Identifiable {
    let callsign: String
    let frequency: Int // FM in tenths of MHz; AM in kHz
    let band: BroadcastBand
    let community, state, facility: String
    var id: String { "\(band.rawValue)-\(facility)-\(frequency)" }
}

@MainActor final class MarketDirectory: ObservableObject {
    @Published var stations: [BroadcastStation] = []
    @Published var loading = false
    @Published var error: String?
    private var task: Task<Void, Never>?
    private var selectedID: String?
    private let cacheDirectory = DialState.storage.appendingPathComponent("MarketCache", isDirectory: true)
    private struct Cache: Codable { var saved: Date; var stations: [BroadcastStation] }

    func load(_ market: RadioMarket) {
        task?.cancel()
        selectedID = market.id
        let file = cacheDirectory.appendingPathComponent(market.id + ".json")
        let cached = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
        stations = cached?.stations ?? []
        error = nil
        loading = true
        task = Task {
            do {
                async let fm = Self.fetch(market, band: .fm)
                async let am = Self.fetch(market, band: .am)
                let result = try await fm + am
                guard !Task.isCancelled, selectedID == market.id else { return }
                stations = result
                loading = false
                try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                if let data = try? JSONEncoder().encode(Cache(saved: Date(), stations: result)) { try? data.write(to: file, options: .atomic) }
            } catch {
                guard !Task.isCancelled, selectedID == market.id else { return }
                loading = false
                self.error = cached == nil ? "FCC data unavailable" : "Using cached FCC data"
            }
        }
    }

    nonisolated static func fetch(_ market: RadioMarket, band: BroadcastBand) async throws -> [BroadcastStation] {
        func parts(_ coordinate: Double) -> (String, String, String) {
            let value = abs(coordinate), degrees = Int(value), minutes = Int((value - Double(degrees)) * 60)
            return (String(degrees), String(minutes), String(format: "%.2f", (value - Double(degrees) - Double(minutes) / 60) * 3600))
        }
        let lat = parts(market.latitude), lon = parts(market.longitude)
        let query = ["list":"4", "status":"3", "dist":"45", "dlat2":lat.0, "mlat2":lat.1, "slat2":lat.2, "NS":"N", "dlon2":lon.0, "mlon2":lon.1, "slon2":lon.2, "EW":"W"]
        let url = Catalog.url("https://transition.fcc.gov/fcc-bin/\(band == .fm ? "fmq" : "amq")", query)
        let data = try await Catalog.request(url)
        guard let body = String(data: data, encoding: .utf8), body.contains("|") else { throw DialError.invalidResponse }
        var seen = Set<String>()
        return body.components(separatedBy: .newlines).compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard f.count > 20, f[3] == band.rawValue, f[9] == "LIC", let value = Double(f[2].components(separatedBy: .whitespaces).first ?? "") else { return nil }
            let facilityIndex = 18
            guard f.count > facilityIndex, !f[1].isEmpty, !f[facilityIndex].isEmpty else { return nil }
            let station = BroadcastStation(callsign: f[1], frequency: Int((band == .fm ? value * 10 : value).rounded()), band: band, community: f[10], state: f[11], facility: f[facilityIndex])
            return seen.insert(station.id).inserted ? station : nil
        }
    }

    private struct RememberedStream: Codable {
        var source: Source
        var verifiedAt: Date
    }

    private var streamCacheURL: URL { cacheDirectory.appendingPathComponent("streams-v1.json") }
    private func streamKey(_ station: BroadcastStation, market: RadioMarket) -> String {
        "\(market.id)|\(station.id)"
    }

    func rememberedStream(for station: BroadcastStation, market: RadioMarket) -> Source? {
        guard let data = try? Data(contentsOf: streamCacheURL),
              let cache = try? JSONDecoder().decode([String: RememberedStream].self, from: data),
              let item = cache[streamKey(station, market: market)],
              Date().timeIntervalSince(item.verifiedAt) < 90 * 24 * 60 * 60,
              Self.matches(item.source, station: station) else { return nil }
        return item.source
    }

    func remember(_ source: Source, for station: BroadcastStation, market: RadioMarket) {
        guard Self.matches(source, station: station) else { return }
        let old = (try? Data(contentsOf: streamCacheURL)).flatMap { try? JSONDecoder().decode([String: RememberedStream].self, from: $0) } ?? [:]
        var cache = old.filter { Date().timeIntervalSince($0.value.verifiedAt) < 90 * 24 * 60 * 60 }
        cache[streamKey(station, market: market)] = RememberedStream(source: source, verifiedAt: Date())
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(cache).write(to: streamCacheURL, options: .atomic)
        } catch { /* Playback should not fail if the optional cache is unavailable. */ }
    }

    nonisolated static func matches(_ source: Source, station: BroadcastStation) -> Bool {
        guard source.isRadio else { return false }
        let country = source.country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard country.isEmpty || country == "us" || country == "usa" || country.contains("united states") else { return false }
        let call = station.callsign.uppercased().replacingOccurrences(of: #"-FM$"#, with: "", options: .regularExpression)
        guard !call.isEmpty else { return false }
        let pattern = "(?i)(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: call) + "(?:[ -]*FM)?(?![A-Z0-9])"
        guard source.title.range(of: pattern, options: .regularExpression) != nil else { return false }
        if station.band == .fm, let namedFrequency = source.fmFrequency,
           Int((namedFrequency * 10).rounded()) != station.frequency { return false }
        return true
    }

    nonisolated static func matchingSources(_ sources: [Source], station: BroadcastStation) -> [Source] {
        var seenURLs = Set<URL>()
        return sources.filter { matches($0, station: station) && seenURLs.insert($0.url).inserted }
    }

    nonisolated static func streams(for station: BroadcastStation) async throws -> [Source] {
        // Searching the base call sign also finds listings that write KIIS-FM as KIIS FM.
        let call = station.callsign.replacingOccurrences(of: #"(?i)-FM$"#, with: "", options: .regularExpression)
        let candidates = try await Catalog.stations(name: call, country: "US", tag: "", min: 0, sort: "votes", offset: 0)
        return matchingSources(candidates, station: station)
    }
}
