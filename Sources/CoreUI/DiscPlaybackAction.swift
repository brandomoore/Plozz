#if canImport(SwiftUI)
import SwiftUI
import CoreModels

private struct DiscPlaybackDefaultKey: EnvironmentKey {
    static let defaultValue = DiscPlaybackBehavior.playVideo
}

private struct ExternalPlaybackChoicesKey: EnvironmentKey {
    static let defaultValue: @MainActor (MediaItem) -> [ExternalPlayer] = { _ in [] }
}

public extension EnvironmentValues {
    var externalPlaybackChoices: @MainActor (MediaItem) -> [ExternalPlayer] {
        get { self[ExternalPlaybackChoicesKey.self] }
        set { self[ExternalPlaybackChoicesKey.self] = newValue }
    }
    var discPlaybackDefault: DiscPlaybackBehavior {
        get { self[DiscPlaybackDefaultKey.self] }
        set { self[DiscPlaybackDefaultKey.self] = newValue }
    }
}

public struct ExternalPlaybackActions: View {
    @Environment(\.externalPlaybackChoices) private var choices
    private let item: MediaItem
    private let onPlay: (ExternalPlayer) -> Void

    public init(item: MediaItem, onPlay: @escaping (ExternalPlayer) -> Void) {
        self.item = item
        self.onPlay = onPlay
    }

    public var body: some View {
        let players = choices(item)
        if !players.isEmpty {
            Menu {
                ForEach(players, id: \.self) { player in
                    Button(player.name) { onPlay(player) }
                }
            } label: {
                Label("Play in", systemImage: "arrow.up.forward.app")
            }
        }
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
