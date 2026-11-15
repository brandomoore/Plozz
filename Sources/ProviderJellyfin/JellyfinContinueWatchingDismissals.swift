import CoreModels
import CoreNetworking
import Foundation

/// Titles the viewer took off Continue Watching on a Jellyfin or Emby server.
///
/// The MediaBrowser API has no dismissal of its own. Clearing a saved position
/// takes an in-progress title off `Items/Resume`, but `Shows/NextUp` then offers
/// the very same episode again as the next one to watch — so on the next Home
/// load the card the viewer just removed comes straight back, looking untouched.
/// Plozz therefore remembers the dismissal itself, and every Continue Watching
/// feed this provider serves leaves those titles out.
///
/// A dismissal holds until the title is played again. It records the server's
/// own last-played stamp for the title *as of the dismissal* and compares the
/// feed's stamp against that, so both sides of the comparison come from the
/// server's clock: a device clock that disagrees with the server's can neither
/// resurrect a title early nor hide a fresh play. A play after the dismissal is
/// the viewer changing their mind, and the title returns without anything having
/// to remember to undo this.
///
/// Scope: one durable record per Plozz profile, account and server user, beside
/// the rest of Plozz's local watch state. Without a durable store (tests, or a
/// provider built without a profile context) it is memory-only.
final class JellyfinContinueWatchingDismissals: @unchecked Sendable {
    struct Dismissal: Codable, Equatable, Sendable {
        /// The server's effective last-played stamp for the title when it was
        /// dismissed; `nil` when the server reported none.
        var lastPlayedAt: Date?
        /// When the viewer dismissed it, by the device clock. Only used to keep
        /// the newest dismissals when the record is bounded.
        var dismissedAt: Date
    }

    private struct PersistedState: DurableLocalStateValue {
        static let durableLocalStateSchemaID = "com.plozz.jellyfin-continue-watching-dismissals.v1"

        var dismissals: [String: Dismissal]
    }

    static let maximumCount = 500
    /// Provider instances are rebuilt on credential refresh and may briefly
    /// overlap, so read-modify-write is serialised across all of them.
    private static let persistenceLock = NSLock()

    private let durableStore: DurableLocalStateStore?
    private let durableKey: DurableLocalStateKey?
    private var memory: [String: Dismissal] = [:]

    init(localMediaContext: LocalMediaContext?, session: UserSession, durableStore: DurableLocalStateStore?) {
        guard let localMediaContext, let durableStore else {
            self.durableStore = nil
            self.durableKey = nil
            return
        }
        let identity = [session.server.id, localMediaContext.serverUserID ?? session.userID].map {
            Data($0.utf8).base64EncodedString()
        }.joined(separator: ":")
        do {
            self.durableKey = try DurableLocalStateKey(
                collection: .localMediaWatch,
                scope: .source(profileID: localMediaContext.profileID, sourceID: localMediaContext.accountID),
                recordID: "jellyfin-cw-dismissals:\(identity)"
            )
            self.durableStore = durableStore
        } catch {
            self.durableKey = nil
            self.durableStore = nil
            PlozzLog.networking.error("Continue Watching dismissal address invalid; using memory only")
        }
    }

    /// Records that `itemID` was taken off Continue Watching while the server's
    /// effective last-played stamp for it was `lastPlayedAt`.
    func dismiss(itemID: String, lastPlayedAt: Date?, at date: Date = Date()) {
        Self.persistenceLock.withLock {
            guard var all = load() else {
                PlozzLog.networking.error("Continue Watching dismissal not saved: stored dismissals unreadable")
                return
            }
            all[itemID] = Dismissal(lastPlayedAt: lastPlayedAt, dismissedAt: date)
            save(all)
        }
    }

    /// `items` without the ones the viewer dismissed and has not played since.
    /// Dismissals that a newer play has superseded are dropped as they are seen.
    func filtering(_ items: [MediaItem]) -> [MediaItem] {
        Self.persistenceLock.withLock {
            // Unreadable state fails open: showing a title the viewer removed is
            // a nuisance, hiding one they are part-way through is a loss.
            guard var all = load(), !all.isEmpty else { return items }
            var superseded = false
            let kept = items.filter { item in
                guard let dismissal = all[item.id] else { return true }
                if Self.isSuperseded(dismissal, by: item) {
                    all[item.id] = nil
                    superseded = true
                    return true
                }
                return false
            }
            if superseded { save(all) }
            return kept
        }
    }

    func dismissal(for itemID: String) -> Dismissal? {
        Self.persistenceLock.withLock { load()?[itemID] }
    }

    /// Whether `item` has been played since `dismissal` was recorded.
    static func isSuperseded(_ dismissal: Dismissal, by item: MediaItem) -> Bool {
        guard let played = item.lastPlayedAt else { return false }
        guard let dismissed = dismissal.lastPlayedAt else { return true }
        return played > dismissed
    }

    // MARK: - Persistence

    /// `nil` when durable state exists but cannot be read — callers must not
    /// overwrite it in that case.
    private func load() -> [String: Dismissal]? {
        guard let durableStore, let durableKey else { return memory }
        do {
            return try durableStore.load(PersistedState.self, for: durableKey)?.dismissals ?? [:]
        } catch {
            PlozzLog.networking.error("Continue Watching dismissals unavailable: \(String(describing: error))")
            return nil
        }
    }

    private func save(_ all: [String: Dismissal]) {
        let bounded = all.count <= Self.maximumCount ? all : Dictionary(
            uniqueKeysWithValues: all.sorted { $0.value.dismissedAt > $1.value.dismissedAt }
                .prefix(Self.maximumCount).map { ($0.key, $0.value) }
        )
        guard let durableStore, let durableKey else {
            memory = bounded
            return
        }
        do {
            if bounded.isEmpty {
                try durableStore.remove(durableKey)
            } else {
                try durableStore.save(PersistedState(dismissals: bounded), for: durableKey)
            }
        } catch {
            PlozzLog.networking.error("Continue Watching dismissals write failed: \(String(describing: error))")
        }
    }
}
