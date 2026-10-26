import AppRuntime
import CoreModels
import CoreNetworking
import CoreTrackerAuth
import CoreUI
import FeatureSettings
import Observation
import SimklService
import SwiftUI
import TraktService
import WetrakrService

struct TrackerHistoryImportFixture: View {
    @State private var model = HistoryImportFixtureModel()
    @State private var comparing = false

    var body: some View {
        VStack {
            Button("Compare history") { comparing = true }
                .disabled(ProcessInfo.processInfo.arguments.contains("--history-wetrakr-export")
                          && model.wetrakr.historyConnectionID == nil
                          || ProcessInfo.processInfo.arguments.contains("--history-simkl-export")
                          && model.simkl.historyConnectionID == nil
                          || ProcessInfo.processInfo.arguments.contains("--history-trakt-export")
                          && model.trakt.historyConnectionID == nil)
                .accessibilityIdentifier("fixture.history.open")
        }
        .sheet(isPresented: $comparing) {
            VStack(alignment: .leading, spacing: 8) {
                NavigationStack {
                    if ProcessInfo.processInfo.arguments.contains("--history-wetrakr-export") {
                        WetrakrHistoryExportView(service: model.wetrakr)
                    } else if ProcessInfo.processInfo.arguments.contains("--history-simkl-export") {
                        SimklHistoryExportView(service: model.simkl)
                    } else if ProcessInfo.processInfo.arguments.contains("--history-trakt-export") {
                        TraktHistoryExportView(service: model.trakt)
                    } else if ProcessInfo.processInfo.arguments.contains("--history-export") {
                        TrackerHistoryExportView(
                            summary: "Copies movie completion only.", libraryKinds: [.movie],
                            makeSession: model.makeExportSession
                        )
                    } else {
                        TrackerHistoryImportView(makeSession: model.makeSession)
                    }
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
        .task {
            if ProcessInfo.processInfo.arguments.contains("--history-wetrakr-export") {
                await model.wetrakr.refreshStatus()
            } else if ProcessInfo.processInfo.arguments.contains("--history-simkl-export") {
                await model.simkl.refreshStatus()
            } else if ProcessInfo.processInfo.arguments.contains("--history-trakt-export") {
                await model.trakt.refreshStatus()
            }
        }
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
    var exported = false
    var storageFailed = false
    private let arguments = ProcessInfo.processInfo.arguments

    @ObservationIgnored private let outbox = InMemoryWatchMutationStore()
    @ObservationIgnored private var syncStore: DurableLocalStateStore?
    @ObservationIgnored lazy var wetrakr: WetrakrService = {
        let http = WetrakrExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = WetrakrService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemoryTrackerTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
            )), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored lazy var simkl: SimklService = {
        let http = SimklExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = SimklService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemorySimklTokenStore(tokens: .init(accessToken: "fixture")), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored lazy var trakt: TraktService = {
        let http = TraktExportFixtureHTTP(
            read: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerReads += 1
                return self.exported
            },
            wrote: { [weak self] in
                guard let self else { throw CancellationError() }
                self.trackerWrites += 1
                self.exported = true
            }
        )
        let service = TraktService(
            config: .init(clientID: "native-export-fixture"), http: http,
            tokenStore: InMemoryTraktTokenStore(tokens: .init(
                accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture
            )), namespace: scope.profileID
        )
        service.makeHistoryExport = { [weak self, weak service] in
            guard let self, let service else { throw CancellationError() }
            guard let store = self.syncStore else { throw DurableLocalStateError.storageUnavailable }
            return try service.makeHistoryExportSession(source: self.makeExportSource(), store: store)
        }
        return service
    }()
    @ObservationIgnored private lazy var sync: TrackerHistorySyncController? = {
        guard let syncStore else { return nil }
        return TrackerHistorySyncController(
            identity: .init(
                trackerID: "publicmetadb", connectionID: "fixture-connection",
                allowsForegroundChecks: !arguments.contains("--history-manual-sync")
            ),
            scope: scope, store: syncStore,
            supportedCategories: arguments.contains("--history-watched-only") ? [.watched] : [.watched, .resume],
            isAuthorized: { [weak self] in self?.authorized ?? false },
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

    private func makeExportSource() -> TrackerServerHistorySource {
        TrackerServerHistorySource(
            scope: scope, accounts: providers.map {
                .init(id: $0.account.id, serverName: $0.account.server.name, userName: $0.account.userName)
            },
            resolveProvider: {
                guard let provider = self.provider($0) else { throw TrackerHistoryError.scopeChanged }
                return provider
            },
            isAuthorized: { self.authorized }, isPlaying: { _, _ in false }
        )
    }

    func makeExportSession() throws -> TrackerHistoryExportSession<String> {
        guard let syncStore else { throw DurableLocalStateError.storageUnavailable }
        let source = makeExportSource()
        return .init(
            trackerID: "fixture", trackerName: "Fixture", connectionID: "fixture", snapshotConnectionID: "fixture",
            source: source, store: syncStore, preservesWatchDates: false,
            isConnected: { self.authorized }, supports: { $0.kind == .movie },
            readAll: { try self.exportSnapshot() },
            resolve: { _ in "550" },
            readTarget: { _ in try .init(observations: self.exportSnapshot().observations) },
            write: { _, _, _, validate in
                try await validate()
                self.trackerWrites += 1
                self.exported = true
                if self.arguments.contains("--history-lost-write-reply") {
                    throw TrackerHistoryExportError.uncertainWrite
                }
            }
        )
    }

    @MainActor
    private final class WetrakrExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            guard endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            var count = 0
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/account/settings"):
                json = #"{"id":42,"info":{"username":"fixture"}}"#
            case (.get, "/sync/last_activities"):
                json = #"{"all":"2020-01-02T03:04:05.000Z"}"#
            case (.get, "/media/external/tmdb/550"):
                json = #"{"id":10,"type":"movie"}"#
            case (.get, "/movies/10"):
                json = #"{"id":10,"type":"movie","ids":{"tmdb":550},"interactions":{"user":{"tracking":{"last":{"status":"\#(exported ? "watched" : "none")"}}}}}"#
            case (.get, "/movies/10/tracking/history"):
                json = exported
                    ? #"{"data":[{"tracks":[{"_track_log_id":"play","target":"movie","status":"watched","tracked_at":"2020-01-02T03:04:05.000Z","tracked_at_unknown":true}]}],"meta":{"page":1,"limit":20,"total":1,"totalPages":1}}"#
                    : #"{"data":[],"meta":{"page":1,"limit":20,"total":0,"totalPages":0}}"#
            case (.get, "/sync/tracking/watched/history/movies"):
                count = exported ? 1 : 0
                json = exported
                    ? #"[{"id":10,"type":"movie","ids":{"tmdb":550},"play_id":"play","watched_at":"2020-01-02T03:04:05.000Z","watched_at_unknown":true}]"#
                    : "[]"
            case (.get, let path) where [
                "/sync/tracking/watched/history/episodes", "/sync/tracking/playing/movies", "/sync/tracking/playing/episodes",
                "/sync/tracking/planning/movies", "/sync/tracking/planning/shows",
                "/sync/tracking/dropped/movies", "/sync/tracking/dropped/shows", "/sync/tracking/hold/shows"
            ].contains(path):
                json = "[]"
            case (.post, "/sync/tracking"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      body["allow_rewatch"] as? Bool == false,
                      let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      movies[0]["id"] as? Int == 10, movies[0]["status"] as? String == "watched",
                      movies[0]["tracked_at_unknown"] as? Bool == true,
                      Set(body.keys) == ["movies", "allow_rewatch"],
                      Set(movies[0].keys) == ["id", "status", "tracked_at_unknown"],
                      endpoint.headers["Idempotency-Key"]?.isEmpty == false else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                json = #"{"added":{"plays":[{"id":10,"type":"movie","play_id":"play","watched_at":"2020-01-02T03:04:05.000Z"}]}}"#
            default:
                throw AppError.notFound
            }
            guard let response = HTTPURLResponse(
                url: baseURL, statusCode: 200, httpVersion: nil, headerFields: ["X-Pagination-Item-Count": String(count)]
            ) else { throw AppError.invalidResponse }
            return (Data(json.utf8), response)
        }
    }

    @MainActor
    private final class SimklExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let isPublic = ["/redirect", "/movies/10"].contains(endpoint.path)
            guard isPublic ? endpoint.headers["Authorization"] == nil
                : endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            var status = 200
            var headers: [String: String] = [:]
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/users/settings"):
                json = #"{"account":{"id":42},"user":{"name":"fixture"}}"#
            case (.get, "/redirect"):
                guard endpoint.redirectPolicy == .doNotFollow else { throw AppError.invalidResponse }
                status = 301
                headers["Location"] = "https://simkl.com/movies/10/fixture"
                json = ""
            case (.get, "/movies/10"):
                json = #"{"type":"movie","ids":{"simkl":10,"tmdb":550}}"#
            case (.get, "/sync/activities"):
                let stamp = exported ? "2020-01-03T00:00:00Z" : "2020-01-02T00:00:00Z"
                let fields = Dictionary(uniqueKeysWithValues: [
                    "all", "plantowatch", "watching", "completed", "hold", "dropped", "removed_from_list", "playback"
                ].map { ($0, stamp) })
                json = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "all": stamp, "movies": fields, "tv_shows": fields, "anime": fields
                ]), as: UTF8.self)
            case (.get, "/sync/all-items/movies"):
                json = exported
                    ? #"{"movies":[{"status":"completed","last_watched_at":"1970-01-01T00:00:01Z","movie":{"ids":{"simkl":10,"tmdb":550}}}]}"#
                    : "{}"
            case (.get, "/sync/all-items/shows"), (.get, "/sync/all-items/anime"): json = "{}"
            case (.get, "/sync/playback"): json = "[]"
            case (.post, "/sync/history"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(body.keys) == ["movies"], let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      Set(movies[0].keys) == ["ids", "watched_at", "is_rewatch"],
                      movies[0]["ids"] as? [String: Int] == ["simkl": 10],
                      movies[0]["watched_at"] as? String == "1970-01-01T00:00:01Z",
                      movies[0]["is_rewatch"] as? Bool == false,
                      !endpoint.queryItems.contains(where: { $0.name == "allow_rewatch" }) else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                status = 201
                json = #"{"added":{"movies":1,"shows":0,"episodes":0,"statuses":[{"request":{"type":"movie","ids":{"simkl":10},"watched_at":"1970-01-01T00:00:01Z"},"response":{"status":"completed","simkl_type":"movie"}}]},"not_found":{"movies":[],"shows":[],"episodes":[]}}"#
            default: throw AppError.notFound
            }
            guard let response = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers) else {
                throw AppError.invalidResponse
            }
            return (Data(json.utf8), response)
        }
    }

    @MainActor
    private final class TraktExportFixtureHTTP: HTTPClient {
        let read: @MainActor () throws -> Bool
        let wrote: @MainActor () throws -> Void
        init(read: @escaping @MainActor () throws -> Bool, wrote: @escaping @MainActor () throws -> Void) {
            self.read = read
            self.wrote = wrote
        }

        func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            try await sendRaw(endpoint, baseURL: baseURL)
        }

        func sendRaw(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
            let isPublic = ["/search/tmdb/550", "/movies/10"].contains(endpoint.path)
            guard isPublic ? endpoint.headers["Authorization"] == nil
                : endpoint.headers["Authorization"] == "Bearer fixture" else { throw AppError.unauthorized }
            let exported = try read()
            let stamp = exported ? "2020-01-03T00:00:00Z" : "2020-01-02T00:00:00Z"
            let movie = #"{"ids":{"trakt":10,"tmdb":550}}"#
            var status = 200
            var headers: [String: String] = [:]
            let json: String
            switch (endpoint.method, endpoint.path) {
            case (.get, "/users/settings"):
                json = #"{"user":{"username":"fixture","ids":{"uuid":"fixture-owner"}}}"#
            case (.get, "/search/tmdb/550"): json = #"[{"type":"movie","movie":\#(movie)}]"#
            case (.get, "/movies/10"): json = movie
            case (.get, "/sync/last_activities"):
                json = #"{"all":"\#(stamp)","movies":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"episodes":{"watched_at":"\#(stamp)","paused_at":"\#(stamp)"},"watchlist":{"updated_at":"\#(stamp)"}}"#
            case (.get, "/users/me/history"), (.get, "/users/me/history/movies/10"):
                json = exported
                    ? #"[{"id":1,"type":"movie","action":"watch","watched_at":"2020-01-02T03:04:05.000Z","movie":\#(movie)}]"#
                    : "[]"
            case (.get, "/sync/watchlist/seasons/added/desc"), (.get, "/sync/watchlist/episodes/added/desc"),
                 (.get, "/sync/playback"), (.get, "/sync/watchlist/movies/added/desc"),
                 (.get, "/sync/watchlist/shows/added/desc"): json = "[]"
            case (.get, "/users/me/watching"): status = 204; json = ""
            case (.post, "/sync/history"):
                guard let data = endpoint.body,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(body.keys) == ["movies"], let movies = body["movies"] as? [[String: Any]], movies.count == 1,
                      Set(movies[0].keys) == ["ids", "watched_at"],
                      movies[0]["ids"] as? [String: Int] == ["trakt": 10],
                      movies[0]["watched_at"] as? String == "2020-01-02T03:04:05.000Z" else {
                    throw HTTPRequestNotSentError(underlying: .invalidResponse)
                }
                try wrote()
                json = #"{"added":{"movies":1,"episodes":0},"updated":{"movies":0,"episodes":0},"not_found":{"movies":[],"shows":[],"seasons":[],"episodes":[]}}"#
            default: throw AppError.notFound
            }
            if endpoint.queryItems.contains(where: { $0.name == "page" }) {
                guard let count = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.count else {
                    throw AppError.invalidResponse
                }
                headers = [
                    "X-Pagination-Page": "1", "X-Pagination-Limit": "100",
                    "X-Pagination-Page-Count": count == 0 ? "0" : "1", "X-Pagination-Item-Count": String(count)
                ]
            }
            guard let response = HTTPURLResponse(url: baseURL, statusCode: status, httpVersion: nil, headerFields: headers) else {
                throw AppError.invalidResponse
            }
            return (Data(json.utf8), response)
        }
    }

    private func exportSnapshot() throws -> TrackerHistorySnapshot {
        trackerReads += 1
        if trackerReads > 1, arguments.contains("--history-revoke-on-recheck") { authorized = false }
        let changed = trackerReads > 1 && arguments.contains("--history-change-on-recheck")
        let observations: [TrackerHistoryObservation]
        if changed || exported {
            observations = [try .init(
                recordID: "watch", kind: .movie, identities: [.external(source: "tmdb", value: "550")],
                fact: changed ? .resume(seconds: 50, runtime: 1_000, updatedAt: nil) : .watched(at: nil)
            )]
        } else { observations = [] }
        return try .init(trackerID: "fixture", connectionID: "fixture", observations: observations, completeness: .completeResponse)
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
            isPlayed: arguments.contains("--history-export"),
            providerIDs: ["Tmdb": "550"], sourceAccountID: account.id
        )
        if arguments.contains("--history-trakt-export") {
            current.lastPlayedAt = Date(timeIntervalSince1970: 1_577_934_245)
        }
    }

    func libraries() async throws -> [MediaLibrary] {
        arguments.contains("--history-export") ? [.init(id: "movies", title: "Movies", kind: .movie)] : []
    }
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
        guard arguments.contains("--history-export"), containerID == "movies", kind == .movie else {
            throw AppError.notFound
        }
        return .init(items: page.startIndex == 0 ? [current] : [], startIndex: page.startIndex, totalCount: 1)
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
