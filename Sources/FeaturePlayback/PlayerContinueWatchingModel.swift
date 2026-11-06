import CoreModels
import Observation

@MainActor @Observable
final class PlayerContinueWatchingModel {
    private(set) var items: [MediaItem] = []
    @ObservationIgnored private var revision: UInt64 = 0

    // Derive on Home/playback changes, not on every controls or focus update.
    func observe(_ snapshot: @escaping @MainActor () -> [MediaItem]) {
        revision &+= 1
        let currentRevision = revision
        items = withObservationTracking {
            snapshot()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.revision == currentRevision else { return }
                self.observe(snapshot)
            }
        }
    }
}
