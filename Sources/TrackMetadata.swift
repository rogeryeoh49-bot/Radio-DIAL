import Foundation

enum TrackMetadataQuality {
    case song, ambiguous, promotional

    static func assess(_ title: String, station: String?) -> TrackMetadataQuality {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .promotional }
        if let station, text.compare(station, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return .promotional }
        let promo = #"(?i)(?:https?://|www\.|#\s*1\s+(?:hit|music|radio)|\b(?:hit music station|radio station|advertisement|commercial break|station identification|all rights reserved)\b)"#
        if text.range(of: promo, options: .regularExpression) != nil { return .promotional }
        for separator in [" – ", " — ", " - "] {
            if let range = text.range(of: separator) {
                let first = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let second = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !first.isEmpty && !second.isEmpty { return .song }
            }
        }
        return .ambiguous
    }
}
