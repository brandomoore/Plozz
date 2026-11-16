import CoreModels
import Foundation

/// What the tvOS See all or search screen needs to show a resting title's pop-up details.
public struct SeeAllPopup {
    public var delay: Duration?
    /// How long the card stays before fading out; `nil` keeps it until focus moves.
    public var hideAfter: Duration?
    public var spoilers: SpoilerSettings
    /// The title's own server's detail record, or the listed item when it has none.
    public var detail: @MainActor (MediaItem) async -> MediaItem

    public init(
        delay: Duration?, hideAfter: Duration? = nil, spoilers: SpoilerSettings,
        detail: @escaping @MainActor (MediaItem) async -> MediaItem
    ) {
        self.delay = delay
        self.hideAfter = hideAfter
        self.spoilers = spoilers
        self.detail = detail
    }
}
