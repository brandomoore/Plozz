import Foundation

struct PipelineDiagnosticCadence {
    private var identity: String?
    private var lastEmission: TimeInterval?

    mutating func shouldEmit(identity: String, paused: Bool, now: TimeInterval) -> Bool {
        let changed = self.identity != identity
        guard changed || lastEmission.map({ now - $0 >= (paused ? 30 : 2) }) != false else { return false }
        self.identity = identity
        lastEmission = now
        return true
    }
}
