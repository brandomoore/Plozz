#if canImport(SwiftUI)
import SwiftUI
import CoreModels

private struct DiscPlaybackDefaultKey: EnvironmentKey {
    static let defaultValue = DiscPlaybackBehavior.playVideo
}

public extension EnvironmentValues {
    var discPlaybackDefault: DiscPlaybackBehavior {
        get { self[DiscPlaybackDefaultKey.self] }
        set { self[DiscPlaybackDefaultKey.self] = newValue }
    }
}

public struct DiscPlaybackAlternativeAction: View {
    @Environment(\.discPlaybackDefault) private var defaultBehavior
    private let item: MediaItem
    private let onPlay: (MediaItem) -> Void

    public init(item: MediaItem, onPlay: @escaping (MediaItem) -> Void) {
        self.item = item
        self.onPlay = onPlay
    }

    public var body: some View {
        if let availability = item.discMenuAvailability,
           let alternative = DiscPlaybackChoice(
               default: defaultBehavior, availability: availability
           ).alternative {
            Button {
                onPlay(item.requestingDiscPlayback(alternative))
            } label: {
                Label(alternative.title, systemImage: alternative == .openMenu ? "opticaldisc" : "play.fill")
            }
        }
    }
}
#endif
