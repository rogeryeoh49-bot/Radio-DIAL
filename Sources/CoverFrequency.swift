import Combine
import Foundation

/// Resolves a US station's call sign against the same FCC records used by FR-01.
@MainActor final class CoverFrequency: ObservableObject {
    @Published private(set) var frequencies: [String: Double] = [:]
    private var attempted = Set<String>()

    func resolve(_ source: Source) async {
        guard frequencies[source.id] == nil, !attempted.contains(source.id),
              Self.isUS(source.country), let callsign = Self.callsign(in: source.title) else { return }
        if let frequency = Self.cachedFrequency(callsign) {
            frequencies[source.id] = frequency
            return
        }
        attempted.insert(source.id)
        do {
            let url = Catalog.url("https://transition.fcc.gov/fcc-bin/fmq", ["call": callsign, "serv": "FM", "status": "3", "list": "4"])
            let data = try await Catalog.request(url)
            guard !Task.isCancelled else { attempted.remove(source.id); return }
            guard let text = String(data: data, encoding: .utf8), let frequency = Self.frequency(in: text, callsign: callsign) else { return }
            frequencies[source.id] = frequency
        } catch {
            // Retry on a later visit if the FCC service is temporarily unavailable.
            attempted.remove(source.id)
        }
    }

    nonisolated static func callsign(in name: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])[KW][A-Z]{2,4}(?:-FM)?(?![A-Za-z0-9])"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return nil }
        return normalized(String(name[range]))
    }

    nonisolated private static func normalized(_ callsign: String) -> String {
        callsign.uppercased().replacingOccurrences(of: #"-FM$"#, with: "", options: .regularExpression)
    }

    nonisolated private static func isUS(_ country: String) -> Bool {
        let name = country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "us" || name == "usa" || name.contains("united states")
    }

    nonisolated private static func frequency(in text: String, callsign: String) -> Double? {
        let matches = text.components(separatedBy: .newlines).compactMap { line -> Double? in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count > 9, normalized(fields[1]) == callsign, fields[3] == "FM", fields[9] == "LIC",
                  let value = Double(fields[2].split(whereSeparator: \.isWhitespace).first ?? ""), (87.5...108.0).contains(value) else { return nil }
            return value
        }
        let unique = Set(matches)
        return unique.count == 1 ? unique.first : nil
    }

    nonisolated private static func cachedFrequency(_ callsign: String) -> Double? {
        struct Cache: Decodable { let stations: [BroadcastStation] }
        let folder = DialState.storage.appendingPathComponent("MarketCache", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        let frequencies = files.filter { $0.pathExtension == "json" }.flatMap { file -> [Double] in
            guard let data = try? Data(contentsOf: file), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
            return cache.stations.filter { $0.band == .fm && normalized($0.callsign) == callsign }.map { Double($0.frequency) / 10 }
        }
        let unique = Set(frequencies)
        return unique.count == 1 ? unique.first : nil
    }
}
