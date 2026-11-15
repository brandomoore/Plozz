import CoreModels
import Foundation

/// What the tvOS See all or search screen needs to show a resting title's pop-up details.
public struct SeeAllPopup {
    public var delay: Duration?
    public var spoilers: SpoilerSettings
    /// The title's own server's detail record, or the listed item when it has none.
    public var detail: @MainActor (MediaItem) async -> MediaItem

    public init(
        delay: Duration?, spoilers: SpoilerSettings, detail: @escaping @MainActor (MediaItem) async -> MediaItem
    ) {
        self.delay = delay
        self.spoilers = spoilers
        self.detail = detail
    }
}
