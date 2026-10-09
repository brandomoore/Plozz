import CoreModels
import CoreNetworking
import Foundation

public final class IPTVProvider: MediaProvider, CapabilityReporting, MediaSortFieldProviding,
    ServerLiveTVProviding, ProviderHTTPResourceResolving, PlayedStateWriting,
    ResumeStateWriting, ContinueWatchingRemovable, ProviderTeardown, Sendable {
    public let kind: ProviderKind = .iptv
    public let session: UserSession
    private let context: ProviderResolutionContext
    private let client: IPTVClient
    private let watch: LocalMediaWatchStore
    private let playback: IPTVPlaybackSessions
    private let guideLoader: IPTVGuideLoader?

    public init(
        context: ProviderResolutionContext, durableStore: DurableLocalStateStore? = nil,
        cacheDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        guideLoader: IPTVGuideLoader? = nil
    ) throws {
        guard context.session.server.provider == .iptv, let local = context.localMediaContext,
              local.accountID == context.accountID else { throw ProviderResolutionError.localMediaContextRequired(.iptv) }
        let credential = try IPTVCredential.decode(context.session.accessToken)
        self.context = context
        self.guideLoader = guideLoader
        session = context.session
        client = try IPTVClient(credential: credential, directory: cacheDirectory, configuration: configuration)
        watch = LocalMediaWatchStore(localMediaContext: local, durableStore: durableStore)
        playback = IPTVPlaybackSessions(client: client, configuration: configuration)
    }

    public var capabilities: ProviderCapability { [.video] }
    public var catalogIdentityRequiresEnrichment: Bool { true }

    public static func signIn(
        credential: IPTVCredential, name: String, deviceID: String,
        cacheDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        progress: @escaping @Sendable (IPTVImportProgress) -> Void = { _ in }
    ) async throws -> UserSession {
        IPTVSetupDiagnostics.current?.advance(to: .catalogOpen)
        let client = try IPTVClient(
            credential: credential, directory: cacheDirectory, configuration: configuration, progress: progress
        )
        // A playlist import validates the response itself. Probing it first
        // makes slow providers generate the same large playlist twice.
        if credential.mode != .playlist { try await client.authenticate() }
        for library in credential.mode == .xtream ? ["live", "movies", "series"] : ["live"] {
            try await client.ensureCatalog(library, force: credential.mode == .playlist)
        }
        try Task.checkCancellation()
        IPTVSetupDiagnostics.current?.advance(to: .sessionCreation)
        return try makeSession(credential: credential, name: name, deviceID: deviceID)
    }

    public static func importFile(
        _ url: URL, credential: IPTVCredential, name: String, deviceID: String,
        cacheDirectory: URL? = nil, progress: @escaping @Sendable (IPTVImportProgress) -> Void = { _ in }
    ) async throws -> UserSession {
        IPTVSetupDiagnostics.current?.advance(to: .catalogOpen)
        let client = try IPTVClient(credential: credential, directory: cacheDirectory, progress: progress)
        try await client.importFile(url)
        IPTVSetupDiagnostics.current?.advance(to: .sessionCreation)
        return try makeSession(credential: credential, name: name, deviceID: deviceID)
    }

    private static func makeSession(credential: IPTVCredential, name: String, deviceID: String) throws -> UserSession {
        guard var origin = URLComponents(url: credential.address, resolvingAgainstBaseURL: false) else {
            throw IPTVError.invalidAddress
        }
        origin.path = ""
        origin.query = nil
        origin.user = nil
        origin.password = nil
        guard let baseURL = origin.url else { throw IPTVError.invalidAddress }
        let serverID = credential.mode == .xtream
            ? "iptv:" + IPTVMapping.digest(baseURL.absoluteString + credential.address.path)
            : credential.identity.uuidString
        let server = MediaServer(
            id: serverID, name: name.isEmpty ? (baseURL.host ?? "IPTV") : name,
            baseURL: baseURL, provider: .iptv
        )
        return UserSession(
            server: server, userID: credential.mode == .xtream ? credential.username : credential.identity.uuidString,
            userName: credential.mode == .xtream ? credential.username : "IPTV",
            deviceID: deviceID, accessToken: try credential.encoded()
        )
    }

    public func libraries() async throws -> [MediaLibrary] {
        let candidates = [
            MediaLibrary(id: "movies", title: "Movies", kind: .movie, synthesizedName: .movies),
            MediaLibrary(id: "series", title: "TV Shows", kind: .series, synthesizedName: .tvShows)
        ]
        var result: [MediaLibrary] = []
        for library in candidates where try await client.hasItems(in: library.id, kind: library.kind) {
            result.append(library)
        }
        return result
    }

    public func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        let result = try await client.page(library: containerID, kind: kind, page: page)
        return MediaPage(items: await applyingWatch(result.items), startIndex: result.startIndex, totalCount: result.totalCount)
    }

    public func item(id: String) async throws -> MediaItem {
        let item = try await client.record(id, details: true).item
        return await applyingWatch([item])[0]
    }

    public func children(of itemID: String) async throws -> [MediaItem] {
        await applyingWatch(try await client.children(itemID))
    }

    public func latest(limit: Int) async throws -> [MediaItem] {
        try await latest(limit: limit, inLibraries: nil)
    }

    public func latest(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        var result: [MediaItem] = []
        for library in try await libraries() where libraryIDs?.contains(library.id) != false {
            var start = 0
            while start < limit {
                let page = try await items(in: library.id, kind: library.kind,
                    page: PageRequest(startIndex: start, limit: min(200, limit - start),
                                      sort: SortDescriptor(field: .dateAdded, direction: .descending)))
                result += page.items
                if !page.hasMore { break }
                guard !page.items.isEmpty else { throw IPTVError.malformed }
                start += page.items.count
            }
        }
        result.sort { ($0.librarySortValues?.dateAdded ?? .distantPast) > ($1.librarySortValues?.dateAdded ?? .distantPast) }
        return Array(result.prefix(limit))
    }

    public func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await continueWatching(limit: limit, inLibraries: nil)
    }

    public func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
        guard limit > 0 else { return [] }
        var result: [MediaItem] = []
        for entry in await watch.resumable(limit: Int.max) where !entry.record.isDismissedFromContinueWatching {
            do {
                let record = try await client.record(entry.itemID)
                guard libraryIDs == nil || record.item.libraryID.map({ libraryIDs!.contains($0) }) == true else { continue }
                result += await applyingWatch([record.item])
                if result.count == limit { break }
            } catch AppError.notFound {
                PlozzLog.playback.info("IPTV resume title is no longer in the provider catalogue")
            }
        }
        return result
    }

    public func search(query: String, limit: Int) async throws -> [MediaItem] {
        try await search(query: query, limit: limit, excludingLibraries: [])
    }

    public func search(query: String, limit: Int, excludingLibraries disabled: [String]) async throws -> [MediaItem] {
        let items = try await client.search(query, libraries: ["movies", "series"].filter { !disabled.contains($0) }, limit: limit)
        return await applyingWatch(items)
    }

    public func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        let record = try await client.record(itemID, details: true)
        guard record.item.kind == .movie || record.item.kind == .episode || record.item.kind == .video else {
            throw AppError.notFound
        }
        let item = await applyingWatch([record.item])[0]
        let locator = try await open(itemID, record: record)
        return PlaybackRequest(
            item: item, playbackSource: .authenticatedHTTP(locator),
            playSessionID: locator.playSessionID, startPosition: item.resumePosition ?? 0,
            sourceProvider: .iptv, serverName: session.server.name
        )
    }

    public func resolveHTTPResource(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        guard locator.provider == .iptv, locator.accountID == context.accountID,
              locator.credentialRevision == context.credentialRevision else { throw AppError.unauthorized }
        return try await playback.resolve(locator)
    }

    public func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        guard progress.positionSeconds.isFinite else { throw AppError.invalidResponse }
        if let id = progress.playSessionID {
            let wasStarted = try await playback.recordEvent(event, sessionID: id, itemID: progress.itemID)
            if event == .stop, !wasStarted { await playback.close(id); return }
        }
        if event == .progress || event == .pause || event == .stop {
            await watch.setResume(progress.positionSeconds, itemID: progress.itemID,
                                  capturedAt: Date(), duration: progress.durationSeconds)
        }
        if event == .stop, let session = progress.playSessionID { await playback.close(session) }
    }

    public func setPlayed(_ played: Bool, itemID: String) async throws {
        try await setPlayed(played, itemID: itemID, capturedAt: Date())
    }

    public func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async throws {
        let record = try await client.record(itemID)
        if record.item.kind == .series || record.item.kind == .season {
            for child in try await children(of: itemID) {
                try await setPlayed(played, itemID: child.id, capturedAt: capturedAt)
            }
        } else { await watch.setPlayed(played, itemID: itemID, capturedAt: capturedAt) }
    }

    public func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        guard seconds.isFinite else { throw AppError.invalidResponse }
        await watch.setResume(seconds, itemID: itemID, capturedAt: capturedAt)
    }

    public func removeFromContinueWatching(itemID: String) async throws {
        await watch.dismissFromContinueWatching(itemID: itemID)
    }

    public func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    public func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        [.name, .dateAdded, .year]
    }

    public func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        let count = try await client.liveChannelCount()
        return ServerLiveTVAvailability(status: count > 0 ? .available : .noChannels, channelCount: count)
    }

    public func refreshLiveTVAvailability() async throws -> ServerLiveTVAvailability {
        try await client.ensureCatalog("live", force: true)
        return try await liveTVAvailability()
    }

    public func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        try await client.liveChannels()
    }

    public func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard from < to, to.timeIntervalSince(from) <= 172_800, channelIDs.count <= 2_000 else {
            throw ServerLiveTVError.invalidGuideWindow
        }
        let credential = await client.credential
        if credential.mode == .xtream, credential.explicitGuideURLs.isEmpty {
            var result: [ServerLiveTVProgramme] = []
            var fallbackIDs: [String] = []
            var endpointUnavailable = false
            for id in channelIDs {
                try Task.checkCancellation()
                if endpointUnavailable {
                    fallbackIDs.append(id)
                    continue
                }
                do {
                    let programmes = try await client.guide(channelID: id, from: from, to: to)
                    if programmes.isEmpty { fallbackIDs.append(id) }
                    else { result += programmes }
                } catch AppError.notFound, IPTVError.unsupported {
                    PlozzLog.networking.info("IPTV guide endpoint is unavailable; using XMLTV for remaining channels")
                    endpointUnavailable = true
                    fallbackIDs.append(id)
                } catch IPTVError.malformed {
                    PlozzLog.networking.info("IPTV channel guide API returned malformed listings; trying XMLTV")
                    fallbackIDs.append(id)
                }
            }
            if !fallbackIDs.isEmpty {
                PlozzLog.networking.info("IPTV XMLTV fallback requested for channels without API listings")
                result += try await xmlTVGuide(channelIDs: fallbackIDs, from: from, to: to)
            }
            return result
        }
        return try await xmlTVGuide(channelIDs: channelIDs, from: from, to: to)
    }

    private func xmlTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard !channelIDs.isEmpty else { return [] }
        let urls = try await client.guideURLs()
        guard !urls.isEmpty else { return [] }
        guard let guideLoader else { throw ServerLiveTVError.unsupportedAPI }
        var channels: [IPTVGuideChannel] = []
        for id in channelIDs {
            let record = try await client.record(id)
            channels.append(IPTVGuideChannel(
                id: id, name: record.item.title, guideID: record.guideID,
                guideName: record.guideName, country: record.guideCountry
            ))
        }
        var result: [ServerLiveTVProgramme] = []
        var covered = Set<String>()
        for url in urls {
            let remaining = channels.filter { !covered.contains($0.id) }
            if remaining.isEmpty { break }
            let programmes = try await guideLoader(
                client.guideData(from: url), url, remaining, from, to
            )
            result += programmes
            covered.formUnion(programmes.map(\.channelID))
        }
        return result
    }

    public struct IPTVGuideChannel: Sendable {
        public let id: String
        public let name: String
        public let guideID: String?
        public let guideName: String?
        public let country: String?

        public init(id: String, name: String, guideID: String?, guideName: String? = nil, country: String? = nil) {
            self.id = id
            self.name = name
            self.guideID = guideID
            self.guideName = guideName
            self.country = country
        }
    }

    public typealias IPTVGuideLoader = @Sendable (
        Data, URL, [IPTVGuideChannel], Date, Date
    ) async throws -> [ServerLiveTVProgramme]

    public func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        let record = try await client.record(id)
        guard record.isLive else { throw ServerLiveTVError.invalidChannel }
        let locator = try await open(id, record: record)
        return IPTVLiveLease(locator: locator, sessions: playback)
    }

    public func teardown() async {
        await client.cancel()
        await playback.closeAll()
    }

    private func open(_ id: String, record: IPTVRecord) async throws -> AuthenticatedHTTPPlaybackLocator {
        let session = UUID().uuidString
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .iptv, accountID: context.accountID, credentialRevision: context.credentialRevision,
            itemID: id, deliveryMode: record.streamURL?.pathExtension.lowercased() == "m3u8" ? .hls : .directFile,
            resource: AuthenticatedHTTPResource(pathBase: .configuredBaseURL, path: "iptv/" + session),
            playSessionID: session
        )
        try await playback.register(locator, isLive: record.isLive)
        return locator
    }

    private func applyingWatch(_ items: [MediaItem]) async -> [MediaItem] {
        let records = await watch.records(for: items.map(\.id))
        return items.map { original in
            var item = original
            item.sourceAccountID = context.accountID
            if let record = records[item.id] {
                item.resumePosition = record.position
                item.isPlayed = record.played
                item.lastPlayedAt = record.updatedAt
                item.runtime = record.duration ?? item.runtime
            }
            return item
        }
    }
}

private struct IPTVLiveLease: LiveTVStreamLease {
    let locator: AuthenticatedHTTPPlaybackLocator
    let sessions: IPTVPlaybackSessions
    var playbackSource: PlaybackSource { .authenticatedHTTP(locator) }
    func report(_ update: LiveTVPlaybackUpdate) async {}
    func close() async {
        if let id = locator.playSessionID { await sessions.close(id) }
    }
}

private actor IPTVPlaybackSessions {
    private struct Delivery: Sendable {
        let url: URL
        let proxy: IPTVPlaybackProxy?
    }
    private struct Entry {
        let locator: AuthenticatedHTTPPlaybackLocator
        let isLive: Bool
        var pending: Task<Delivery, Error>?
        var delivery: Delivery?
        var started = false
    }
    private let client: IPTVClient
    private let configuration: URLSessionConfiguration?
    private var entries: [String: Entry] = [:]

    init(client: IPTVClient, configuration: URLSessionConfiguration?) {
        self.client = client
        self.configuration = configuration
    }

    func register(_ locator: AuthenticatedHTTPPlaybackLocator, isLive: Bool) throws {
        guard let id = locator.playSessionID, entries.count < 32 else { throw AppError.invalidResponse }
        entries[id] = Entry(locator: locator, isLive: isLive)
    }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        guard let id = locator.playSessionID, let entry = entries[id], entry.locator == locator else {
            throw AppError.unauthorized
        }
        if let delivery = entry.delivery { return delivery.url }
        let task: Task<Delivery, Error>
        if let pending = entry.pending { task = pending }
        else {
            task = Task { [client, configuration, isLive = entry.isLive] in
                let (url, headers, formatHint) = try await client.delivery(locator.itemID)
                let credential = await client.credential
                let proxy = try IPTVPlaybackProxy(
                    origin: url, headers: headers, formatHint: formatHint, configuration: configuration,
                    sensitiveValues: [credential.password], content: isLive ? .live : .onDemand
                )
                do { return try await Delivery(url: proxy.start(), proxy: proxy) }
                catch { await proxy.stop(); throw error }
            }
            entries[id]?.pending = task
        }
        let delivery: Delivery
        do {
            delivery = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
        } catch {
            await close(id)
            throw error
        }
        guard entries[id] != nil, !Task.isCancelled else {
            await delivery.proxy?.stop()
            await close(id)
            throw CancellationError()
        }
        entries[id]?.delivery = delivery
        entries[id]?.pending = nil
        return delivery.url
    }

    func recordEvent(_ event: PlaybackEvent, sessionID: String, itemID: String) throws -> Bool {
        guard var entry = entries[sessionID] else {
            if event == .stop { return false }
            throw AppError.unauthorized
        }
        guard entry.locator.itemID == itemID else { throw AppError.unauthorized }
        if event == .start { entry.started = true; entries[sessionID] = entry }
        return entry.started
    }

    func close(_ id: String) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        entry.pending?.cancel()
        await entry.delivery?.proxy?.stop()
        if let pending = entry.pending, case .success(let delivery) = await pending.result {
            await delivery.proxy?.stop()
        }
    }

    func closeAll() async {
        for id in Array(entries.keys) { await close(id) }
    }
}
