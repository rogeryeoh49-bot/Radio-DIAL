import Foundation

enum TrackMetadataQuality {
    case song, ambiguous, promotional

    static func assess(_ title: String, station: String?) -> TrackMetadataQuality {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .promotional }
        if let station, text.compare(station, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return .promotional }
        let promo = #"(?i)(?:https?://|www\.|#\s*1\s+(?:hit|music|radio)|\b(?:hit music station|radio station|advertisement|commercial break|station identification|all rights reserved)\b)"#
        if text.range(of: promo, options: .regularExpression) != nil { return .promotional }
        let parts = TrackDisplayInfo.parse(text)
        if !parts.artist.isEmpty, !isMissing(parts.artist), !isMissing(parts.title),
           parts.artist.compare(parts.title, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
            return .song
        }
        return .ambiguous
    }

    static func isMissing(_ value: String?) -> Bool {
        guard let value else { return true }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["", "-", "–", "—", "?", "unknown", "unknown title", "unknown song", "unknown artist", "untitled", "n/a"].contains(text)
    }

    static func availableLabel(_ text: String) -> String {
        let parts = TrackDisplayInfo.parse(text)
        if isMissing(parts.title) || parts.title.caseInsensitiveCompare(parts.artist) == .orderedSame { return parts.artist }
        if isMissing(parts.artist) { return parts.title }
        return text
    }
}

struct TrackDisplayInfo {
    let title: String
    let artist: String

    static func parse(_ raw: String, matchedTitle: String? = nil, matchedArtist: String? = nil) -> Self {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let matchedTitle, !matchedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Self(title: matchedTitle, artist: matchedArtist ?? "")
        }
        let separator = [" – ", " — ", " - "].compactMap { text.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        if let separator {
            let artist = text[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let title = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty, !title.isEmpty { return Self(title: title, artist: artist) }
        }
        return Self(title: text, artist: "")
    }
}
