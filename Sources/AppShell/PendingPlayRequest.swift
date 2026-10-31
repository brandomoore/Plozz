import Foundation
import Observation
import TopShelfKit

/// A Top Shelf deep link (`plozz://item/<id>`) waiting for the signed-in UI to
/// open it.
///
/// This exists as its own object purely so it can be passed **by reference**.
/// The obvious shape — a `String?` on `AppState`, threaded down as a
/// `Binding` — makes every view that stores the binding a subscriber of the
/// source, so each publish invalidates it whether or not the value moved.
/// Measured on the Apple TV: `HomeTab.body` re-evaluated 1,619 times in 50
/// seconds while the id stayed `nil` the entire time, rebuilding its
/// `NavigationStack` and every pushed destination on each pass, until the
/// watchdog terminated the app.
///
/// A stored `let` reference to this object is stable across `body` passes, so
/// intermediate views (`MainTabView`, `HomeTab`) can carry it without becoming
/// subscribers. Only the small leaf that reads ``request`` — the deep-link
/// router — is invalidated, and its body is empty.
@MainActor
@Observable
public final class PendingPlayRequest {
    public struct Request: Equatable, Sendable {
        public let id: UUID
        public let reference: TopShelf.ItemReference
    }

    private var pendingRequest: Request?
    @ObservationIgnored private let isAuthorized: @MainActor () -> Bool

    /// Keep locked-profile links queued without waking navigation or playback.
    public var request: Request? { isAuthorized() ? pendingRequest : nil }

    public init(isAuthorized: @escaping @MainActor () -> Bool = { true }) {
        self.isAuthorized = isAuthorized
    }

    public func enqueue(_ reference: TopShelf.ItemReference) {
        pendingRequest = Request(id: UUID(), reference: reference)
    }

    /// A completed fetch cannot consume a newer action, even for the same title.
    public func consume(_ expected: Request) -> Bool {
        guard request == expected else { return false }
        pendingRequest = nil
        return true
    }
}
