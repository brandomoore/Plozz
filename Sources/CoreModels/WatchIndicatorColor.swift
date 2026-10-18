import Foundation

/// The colour of the watch-status mark on media cards: the unwatched corner flag
/// and the watched check badge (pure data model).
///
/// A per-profile display preference stored alongside `WatchStatusIndicator`. The
/// concrete colours live in `CoreUI` (`MediaWatchIndicatorStyle`), so this stays
/// Foundation-only. White keeps the long-standing look; the rest are fixed hues
/// that read over arbitrary artwork in every theme.
public enum WatchIndicatorColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case white, blue, green, yellow, orange, red, pink, purple

    public var id: String { rawValue }

    public var displayName: LocalizedStringResource {
        switch self {
        case .white: "White"
        case .blue: "Blue"
        case .green: "Green"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .red: LocalizedStringResource(
            "Red",
            comment: "Color name for the watched-indicator color option in Settings > Appearance > Cards. Refers to the plain red color."
        )
        case .pink: "Pink"
        case .purple: "Purple"
        }
    }

    public static let `default`: WatchIndicatorColor = .white
}
