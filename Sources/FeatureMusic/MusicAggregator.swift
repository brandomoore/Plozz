import Foundation
import Observation
import CoreModels
import CoreNetworking

/// A signed-in account whose provider advertises (and actually exposes) music.
public struct ResolvedMusicAccount: Sendable {
    public let accountID: String
    public let provider: any MusicProvider
    /// The visible music library IDs to scope queries to, or `nil` for "all
    /// libraries" (the unscoped default). Driven by the per-profile library
    /// visibility toggles.
    public let libraryIDs: [String]?

    public init(accountID: String, provider: any MusicProvider, libraryIDs: [String]? = nil) {
        self.accountID = accountID
        self.provider = provider
        self.libraryIDs = libraryIDs
    }
}

/// Resolves `MusicProvider`s from the app's `[ResolvedAccount]` aggregation seam
/// and routes a tapped music item back to its owning provider via
/// `sourceAccountID`, exactly like the video Home does for `MediaItem`s.
public struct MusicContext: Sendable {
    public let accounts: [ResolvedAccount]
    /// Visible music library IDs per account (post visibility-filter), or `nil`
    /// to leave every library in scope. Scopes the landing/grid/recently-played
    /// queries so hidden libraries contribute no content.
    public let visibleLibraryIDs: [String: [String]]?

    public init(accounts: [ResolvedAccount], visibleLibraryIDs: [String: [String]]? = nil) {
        self.accounts = accounts
        self.visibleLibraryIDs = visibleLibraryIDs
    }

    /// Every account that exposes a `MusicProvider`, in stable order, each tagged
    /// with its visible library scope.
    public var musicAccounts: [ResolvedMusicAccount] {
        accounts.compactMap { resolved in
            (resolved.provider as? MusicProvider).map {
                ResolvedMusicAccount(
                    accountID: resolved.account.id,
                    provider: $0,
                    libraryIDs: visibleLibraryIDs?[resolved.account.id]
                )
            }
        }
    }

    /// The music provider that owns `accountID`, falling back to the first
    /// music-capable account for untagged items.
    public func provider(for accountID: String?) -> (any MusicProvider)? {
        if let accountID,
           let match = accounts.first(where: { $0.account.id == accountID }),
           let music = match.provider as? MusicProvider {
            return music
        }
        return musicAccounts.first?.provider
    }
}

/// Detects whether any signed-in account actually exposes a music *library*
/// (not merely whether the provider could). Drives the conditional Music tab:
/// the tab and mini-player appear only when `hasMusic` is `true`, so video-only
/// users see the app exactly as before.
@MainActor
@Observable
public final class MusicAvailabilityModel {
    /// Accounts confirmed to have at least one *visible* music library.
    public private(set) var detectedAccounts: [ResolvedAccount] = []
    /// Visible music library IDs per detected account, after applying the
    /// per-profile visibility toggles. Scopes the tab's content.
    public private(set) var visibleLibraryIDs: [String: [String]] = [:]
    public private(set) var hasMusic = false
    /// `true` once a probe has completed, so the UI can avoid flicker on launch.
    public private(set) var didProbe = false

    private let store: MusicAvailabilityStoring
    @ObservationIgnored private var probeRevision = 0

    public init(store: MusicAvailabilityStoring = MusicAvailabilityStore()) {
        self.store = store
        // Decide tab PRESENCE on the very first frame, from the persisted map
        // alone (a UserDefaults read; no accounts, no visibility, no network).
        //
        // `seedFromCache` below does the accurate job but runs from a `.task`,
        // which is one render too late. The Music tab therefore appeared *after*
        // the tab set had already been built — and adding a tab re-assigns
        // SwiftUI identity to its siblings, tearing down the Home tab's `@State`
        // mid-launch. Measured on device: every cold launch ran TWO complete
        // four-account Home fan-outs (~2.5s each) and threw the first away,
        // along with Home's navigation path and scroll position.
        hasMusic = !store.load().isEmpty
    }

    /// Synchronously shows the Music tab on the first frame using the last
    /// persisted set of libraries, with **no network**, applying the *current*
    /// visibility so a library hidden while the app was closed never resurrects a
    /// phantom tab. The subsequent `probe` refreshes and corrects this.
    public func seedFromCache(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) {
        let stored = store.load()
        apply(accounts: accounts, rawLibraries: stored, visibility: visibility)
        // Authoritative over the provisional value `init` set from the raw map:
        // the persisted libraries may no longer resolve against the signed-in
        // accounts, or may all be hidden. Correcting here — one render in —
        // keeps a stale cache from leaving an empty Music tab up until the
        // network probe returns.
    }

    /// Probes every account's `musicLibraries()` **in parallel**, persists the raw
    /// library map for the next launch's instant seed, then applies the current
    /// visibility to decide the tab and its content scope. Failed accounts retain
    /// their last known libraries; only successful empty responses remove them.
    public func probe(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility) async {
        await probe(accounts: accounts, visibility: visibility, retryDelays: [.seconds(2), .seconds(8)])
    }

    func probe(accounts: [ResolvedAccount], visibility: HomeLibraryVisibility, retryDelays: [Duration]) async {
        probeRevision += 1
        let revision = probeRevision
        let eligible = accounts.filter { $0.provider is MusicProvider }
        let accountIDs = Set(eligible.map(\.account.id))
        var rawMap = store.load().filter { accountIDs.contains($0.key) }
        apply(accounts: accounts, rawLibraries: rawMap, visibility: visibility)
        var pending = eligible

        for attempt in 0...retryDelays.count {
            if attempt > 0 {
                do { try await Task.sleep(for: retryDelays[attempt - 1]) }
                catch { return }
            }
            guard !Task.isCancelled, revision == probeRevision else { return }
            let fetched = await withTaskGroup(of: (String, [String]?, Bool).self) { group in
                for account in pending {
                    guard let music = account.provider as? MusicProvider else { continue }
                    group.addTask {
                        do {
                            return (account.account.id, try await music.musicLibraries().map(\.id), false)
                        } catch {
                            if !Task.isCancelled {
                                PlozzLog.discovery.error("Music library probe failed for account \(account.account.id); retaining cached availability")
                            }
                            let retry: Bool
                            switch error {
                            case AppError.serverUnreachable, AppError.invalidResponse, is URLError:
                                retry = !Task.isCancelled
                            default:
                                retry = false
                            }
                            return (account.account.id, nil, retry)
                        }
                    }
                }
                var results: [(String, [String]?, Bool)] = []
                for await result in group { results.append(result) }
                return results
            }
            guard !Task.isCancelled, revision == probeRevision else { return }
            var failed = Set<String>()
            for (id, libraries, retry) in fetched {
                if let libraries {
                    rawMap[id] = libraries.isEmpty ? nil : libraries
                } else if retry {
                    failed.insert(id)
                }
            }
            store.save(rawMap)
            didProbe = true
            apply(accounts: accounts, rawLibraries: rawMap, visibility: visibility)
            pending = pending.filter { failed.contains($0.account.id) }
            if pending.isEmpty { return }
        }
    }

    private func apply(accounts: [ResolvedAccount], rawLibraries: [String: [String]], visibility: HomeLibraryVisibility) {
        let resolved = Self.resolve(accounts: accounts, rawLibraries: rawLibraries, visibility: visibility)
        let changed = resolved.visible != visibleLibraryIDs
            || resolved.detected.map(\.account) != detectedAccounts.map(\.account)
        if changed {
            detectedAccounts = resolved.detected
            visibleLibraryIDs = resolved.visible
        }
        if hasMusic != !resolved.detected.isEmpty { hasMusic = !resolved.detected.isEmpty }
    }

    /// Applies visibility to a raw `accountID → libraryIDs` map, yielding the
    /// detected accounts (those with ≥1 enabled library, in `accounts` order) and
    /// the per-account enabled library IDs. The key scheme `"<accountID>:<libraryID>"`
    /// matches `AggregatedLibrary.key`. The Music tab keys off the **app-wide
    /// enabled** state (`disabledKeys`), NOT the Home-only "Show on Home" bit — a
    /// library hidden from Home still appears in Music; only disabling it app-wide
    /// removes it here, matching the two-level visibility model.
    private static func resolve(
        accounts: [ResolvedAccount],
        rawLibraries: [String: [String]],
        visibility: HomeLibraryVisibility
    ) -> (detected: [ResolvedAccount], visible: [String: [String]]) {
        var detected: [ResolvedAccount] = []
        var visible: [String: [String]] = [:]
        for account in accounts where account.provider is MusicProvider {
            guard let raw = rawLibraries[account.account.id], !raw.isEmpty else { continue }
            let visibleLibs = raw.filter { visibility.isEnabled("\(account.account.id):\($0)") }
            guard !visibleLibs.isEmpty else { continue }
            detected.append(account)
            visible[account.account.id] = visibleLibs
        }
        return (detected, visible)
    }
}
