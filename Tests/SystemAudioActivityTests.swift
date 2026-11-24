import Foundation
@main struct Tests {
    static func main() {
        var gate = SystemAudioActivityGate()
        for n in 0...50 { precondition(!gate.consume(rms: 0, at: Double(n) / 10)) }
        // A short click must not announce a playing station.
        precondition(!gate.consume(rms: 0.1, at: 6))
        precondition(!gate.consume(rms: 0, at: 6.1))
        precondition(!gate.consume(rms: 0.01, at: 7))
        precondition(gate.consume(rms: 0.01, at: 7.3))
        // Hysteresis holds through low-level passages, brief silence and jitter.
        precondition(gate.consume(rms: 0.001, at: 8))
        precondition(gate.consume(rms: 0, at: 9))
        precondition(gate.consume(rms: 0.001, at: 9.5))
        precondition(gate.consume(rms: 0, at: 10))
        precondition(gate.consume(rms: 0, at: 11.4))
        precondition(!gate.consume(rms: 0, at: 11.6))
        precondition(!gate.consume(rms: .nan, at: 12))
        precondition(!gate.consume(rms: .infinity, at: 13))
        gate.reset()
        precondition(!gate.active)
        print("System audio silence, transient rejection, activation, hysteresis, stop debounce and invalid levels passed")
    }
}
