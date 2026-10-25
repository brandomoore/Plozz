import AppRuntime
import CoreModels
import CoreUI
import FeatureSettings
import Observation
import SwiftUI

struct TrackerHistoryImportFixture: View {
    @State private var model = HistoryImportFixtureModel()
    @State private var comparing = false

    var body: some View {
        VStack {
            Button("Compare history") { comparing = true }
                .accessibilityIdentifier("fixture.history.open")
        }
        .sheet(isPresented: $comparing) {
            VStack(alignment: .leading, spacing: 8) {
                NavigationStack {
                    TrackerHistoryImportView(makeSession: model.makeSession)
                }
                VStack(alignment: .leading, spacing: 8) {
                    report
                    if ProcessInfo.processInfo.arguments.contains("--history-ongoing-sync") {
                        Button("New tracker play") { model.newPlay += 1 }
                            .accessibilityIdentifier("fixture.history.new-play")
                    }
                    Button("Close comparison") { comparing = false }
                        .accessibilityIdentifier("fixture.history.close")
                }
                .frame(maxWidth: 1200, alignment: .leading)
                .frame(maxWidth: .infinity)
                #if os(tvOS)
                .focusSection()
                #endif
            }
            #if os(tvOS)
            .frame(minWidth: 1600, minHeight: 900)
            #endif
        }
        .environment(\.themePalette, .dark)
        .preferredColorScheme(.dark)
    }

    private var report: some View {
        Text(verbatim: model.report)
            .font(.caption)
            .accessibilityIdentifier("fixture.history.report")
    }
}

@MainActor @Observable
private final class HistoryImportFixtureModel {
    let providers: [HistoryImportFixtureProvider]
    let scope: WatchMutationServerScope
    let index: IdentityIndexSnapshot
    var authorized = true
    var trackerReads = 0
    var trackerWrites = 0
    var newPlay = 0
    var storageFailed = false
    private let arguments = ProcessInfo.processInfo.arguments

    @ObservationIgnored private let outbox = InMemoryWatchMutationStore()
    @ObservationIgnored private var syncStore: DurableLocalStateStore?
    @ObservationIgnored private lazy var sync: TrackerHistorySyncController? = {
        guard let syncStore else { return nil }
        return TrackerHistorySyncController(
            identity: .init(trackerID: "publicmetadb", connectionID: "fixture-connection"),
            scope: scope, store: syncStore, isAuthorized: { [weak self] in self?.authorized ?? false },
            makeSession: { [weak self] scope, allowed in
                guard let self else { throw TrackerHistoryError.scopeChanged }
                return self.makeSession(scope: scope, allowed: allowed)
            }
        )
    }()

    private func makeReconciler() -> WatchStateReconciler {
        let index = self.index
        return WatchStateReconciler(
            store: outbox,
            applier: AppShellWatchMutationApplier(
                isActive: { await self.authorized },
                validateServerScope: { try await self.requireScope($0) },
                resolveProvider: { await self.provider($0) },
                applyTrakt: { _ in try await self.unexpectedTrackerWrite() },
                applySimkl: { _ in try await self.unexpectedTrackerWrite() },
                applyAniList: { _ in try await self.unexpectedTrackerWrite() },
                applyMAL: { _ in try await self.unexpectedTrackerWrite() },
                wetrakrAccountIdentity: { "fixture-wetrakr" },
                applyWetrakr: { _, _, _, _ in try await self.unexpectedTrackerWrite() },
                applyTrackerPlayback: { _ in try await self.unexpectedTrackerWrite() },
                allAccountIDs: { await self.providers.map(\.account.id) },
                indexedSources: { identities, kind, _, _, _ in
                    index.sources(forIdentities: identities, kind: kind)
                },
                indexedAccountIDs: { index.indexedAccountIDs }
            )
        )
    }

    init() {
        providers = [.init(kind: .jellyfin), .init(kind: .plex)]
        scope = WatchMutationServerScope(
            profile: .init(id: "fixture-profile", name: "Fixture"),
            accounts: providers.map(\.account)
        )
        index = IdentityIndexSnapshot(byIdentity: [
            .external(source: "tmdb", value: "550"): providers.map {
                .init(accountID: $0.account.id, itemID: "movie", providerKind: $0.kind, kind: .movie)
            }
        ])
        do { syncStore = try DurableLocalStateStore(secureStore: HistoryImportFixtureStorage()) }
        catch { storageFailed = true }
    }

    var report: String {
        providers.map {
            "\($0.kind.rawValue)=\($0.writes),played=\($0.current.isPlayed),playback=\($0.playbackWrites),resume=\(Int($0.current.resumePosition ?? 0))"
        }.joined(separator: ";") + ";trackers=\(trackerWrites)"
            + (arguments.contains("--history-ongoing-sync")
                ? ";sync=\(sync?.isEnabled ?? false);destinations=\(sync?.grant?.scope.accounts.map(\.accountID).sorted().joined(separator: ",") ?? "");storageFailed=\(storageFailed)"
                : "")
            + ";reads=\(trackerReads)"
    }

    func makeSession() -> TrackerHistoryImportSession {
        let session = makeSession(scope: scope, allowed: { true })
        if arguments.contains("--history-ongoing-sync") { session.ongoingSync = sync }
        return session
    }

    private func makeSession(
        scope: WatchMutationServerScope, allowed: @escaping @MainActor @Sendable () -> Bool
    ) -> TrackerHistoryImportSession {
        return TrackerHistoryImportSession(
            scope: scope,
            destinations: providers.map {
                .init(id: $0.account.id, serverName: $0.account.server.name, userName: $0.account.userName)
            },
            reconciler: makeReconciler(),
            readSnapshot: { try self.snapshot() },
            index: { self.index },
            resolveProvider: {
                guard let provider = self.provider($0) else { throw AppError.serverUnreachable }
                return provider
            },
            isAuthorized: { self.authorized && allowed() }
        )
    }

    private func snapshot() throws -> TrackerHistorySnapshot {
        trackerReads += 1
        if trackerReads > 1, arguments.contains("--history-revoke-on-recheck") {
            authorized = false
        }
        let changed = trackerReads > 1 && arguments.contains("--history-change-on-recheck")
        return try TrackerHistorySnapshot(
            trackerID: "publicmetadb", connectionID: "fixture-connection",
            observations: [
                .init(
                    recordID: "watch-\(newPlay)", kind: .movie,
                    identities: [.external(source: "tmdb", value: "550")],
                    fact: .watched(at: Date(timeIntervalSince1970: changed ? 1_700_000_001 : 1_700_000_000))
                )
            ],
            completeness: .completeResponse
        )
    }

    private func requireScope(_ requested: WatchMutationServerScope) throws {
        guard authorized, requested.profileID == scope.profileID,
              Set(requested.accounts).isSubset(of: Set(scope.accounts)) else {
            throw WatchMutationServerScopeError.unavailable
        }
    }

    private final class HistoryImportFixtureStorage: SecureStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func setString(_ value: String, for key: String) throws {
            lock.lock(); defer { lock.unlock() }; values[key] = value
        }
        func string(for key: String) -> String? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func readString(for key: String) throws -> String? { string(for: key) }
        func removeValue(for key: String) throws { lock.lock(); defer { lock.unlock() }; values[key] = nil }
    }

    private func provider(_ accountID: String) -> (any MediaProvider)? {
        guard authorized else { return nil }
        return providers.first { $0.account.id == accountID }
    }

    private func unexpectedTrackerWrite() throws {
        trackerWrites += 1
        throw AppError.invalidResponse
    }
}

@MainActor @Observable
private final class HistoryImportFixtureProvider: MediaProvider, WatchStateProviding {
    let kind: ProviderKind
    let account: Account
    let session: UserSession
    var current: MediaItem
    var writes = 0
    var playbackWrites = 0
    private var reads = 0
    private let arguments = ProcessInfo.processInfo.arguments

    init(kind: ProviderKind) {
        self.kind = kind
        let name = kind == .plex ? "Plex" : "Jellyfin"
        let server = MediaServer(
            id: kind.rawValue, name: "\(name) fixture",
            baseURL: URL(string: "https://example.test")!, provider: kind
        )
        account = Account(
            id: kind.rawValue, server: server, userID: "\(kind.rawValue)-viewer",
            userName: "\(name) viewer", deviceID: "fixture-device"
        )
        session = UserSession(
            server: server, userID: account.userID, userName: account.userName,
            deviceID: account.deviceID, accessToken: ""
        )
        current = MediaItem(
            id: "movie", title: "Fixture movie", kind: .movie, runtime: 1_000,
            providerIDs: ["Tmdb": "550"], sourceAccountID: account.id
        )
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        guard id == current.id else { throw AppError.notFound }
        reads += 1
        if reads > 1, arguments.contains("--history-server-change-on-recheck") {
            current.resumePosition = 50
        }
        return current
    }
    func children(of itemID: String) async throws -> [MediaItem] { throw AppError.notFound }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        throw AppError.notFound
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        playbackWrites += 1
        throw AppError.invalidResponse
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func setPlayed(_ played: Bool, itemID: String) async throws {
        guard itemID == current.id else { throw AppError.notFound }
        current.isPlayed = played
        writes += 1
        if arguments.contains("--history-lost-write-reply") { throw AppError.serverUnreachable }
    }
}
