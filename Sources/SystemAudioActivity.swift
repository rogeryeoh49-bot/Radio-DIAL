import Foundation

/// Operates only on scalar levels; it never retains audio samples.
struct SystemAudioActivityGate {
    private(set) var active = false
    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?

    mutating func consume(rms: Double, at time: TimeInterval) -> Bool {
        let db = 20 * log10(max(1e-10, rms.isFinite ? rms : 0))
        if !active {
            quietSince = nil
            if db >= -52 {
                if loudSince == nil { loudSince = time }
                if time - loudSince! >= 0.25 { active = true; loudSince = nil }
            } else { loudSince = nil }
        } else {
            loudSince = nil
            if db < -62 {
                if quietSince == nil { quietSince = time }
                if time - quietSince! >= 1.5 { active = false; quietSince = nil }
            } else { quietSince = nil }
        }
        return active
    }

    mutating func reset() { self = Self() }
}
