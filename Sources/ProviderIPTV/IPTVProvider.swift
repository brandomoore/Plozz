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
    private let guideIndex: (any IPTVGuideIndexLoading)?

    public init(
        context: ProviderResolutionContext, durableStore: DurableLocalStateStore? = nil,
        cacheDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        guideLoader: IPTVGuideLoader? = nil, guideIndex: (any IPTVGuideIndexLoading)? = nil
    ) throws {
        guard context.session.server.provider == .iptv, let local = context.localMediaContext,
              local.accountID == context.accountID else { throw ProviderResolutionError.localMediaContextRequired(.iptv) }
        let credential = try IPTVCredential.decode(context.session.accessToken)
        self.context = context
        self.guideLoader = guideLoader
        self.guideIndex = guideIndex
        session = context.session
        client = try IPTVClient(credential: credential, directory: cacheDirectory, configuration: configuration)
        watch = LocalMediaWatchStore(localMediaContext: local, durableStore: durableStore)
        playback = IPTVPlaybackSessions(client: client, configuration: configuration)
        LiveTVSourceDiagnostics.shared.record(
            .providerCreated,
            identities: [.account: context.accountID, .catalog: credential.identity.uuidString],
            flags: [.xtream: credential.mode == .xtream, .localFile: credential.mode == .file]
        )
    }

    public var capabilities: ProviderCapability { [.video] }
    public var catalogIdentityRequiresEnrichment: Bool { true }

    public static func signIn(
        credential: IPTVCredential, name: String, deviceID: String,
        cacheDirectory: URL? = nil, configuration: URLSessionConfiguration? = nil,
        progress: @escaping @Sendable (IPTVImportProgress) -> Void = { _ in }
    ) async throws -> UserSession {
        let detected = try IPTVXtreamDetection.candidate(for: credential)
        if let detected, IPTVXtreamDetection.isAPIEndpoint(credential.address) {
            PlozzLog.auth.info("IPTV setup recognized an Xtream API address")
            return try await signIn(
                credential: detected, name: name, deviceID: deviceID,
                cacheDirectory: cacheDirectory, configuration: configuration, progress: progress
            )
        }
        IPTVSetupDiagnostics.current?.advance(to: .catalogOpen)
        let client = try IPTVClient(
            credential: credential, directory: cacheDirectory, configuration: configuration, progress: progress
        )
        // A playlist import validates the response itself. Probing it first
        // makes slow providers generate the same large playlist twice.
        do {
            if credential.mode != .playlist { try await client.authenticate() }
            for library in credential.mode == .xtream ? ["live", "movies", "series"] : ["live"] {
                try await client.ensureCatalog(library, force: credential.mode == .playlist)
            }
        } catch {
            guard let detected, IPTVXtreamDetection.permitsFallback(after: error) else { throw error }
            await client.cancel()
            try Task.checkCancellation()
            PlozzLog.auth.info("IPTV address is not a playlist; trying Xtream with the supplied login")
            progress(IPTVImportProgress(stage: .connecting))
            return try await signIn(
                credential: detected, name: name, deviceID: deviceID,
                cacheDirectory: cacheDirectory, configuration: configuration, progress: progress
            )
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
        let supportsGuide = try await client.hasGuideSource()
        return ServerLiveTVAvailability(
            status: count > 0 ? .available : .noChannels, channelCount: count, supportsGuide: supportsGuide
        )
    }

    public func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot? {
        try await client.cachedLiveTVCatalog()
    }

    public func refreshLiveTVAvailability() async throws -> ServerLiveTVAvailability {
        await guideIndex?.invalidate()
        await client.invalidateGuideCache()
        try await client.ensureCatalog("live", force: true)
        return try await liveTVAvailability()
    }

    public func completeLiveTVGuideDiscovery() async throws -> Bool? {
        try await client.completeGuideDiscovery()
    }

    public func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        try await client.liveChannels()
    }

    public func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        guard from < to, to.timeIntervalSince(from) <= 172_800, channelIDs.count <= 2_000 else {
            throw ServerLiveTVError.invalidGuideWindow
        }
        let performance = PerformanceDiagnostics.shared.begin(
            .guideFetch, provider: .iptv, metrics: .init(items: channelIDs.count)
        )
        let metrics = performance == nil ? nil : IPTVPerformanceMetrics()
        let diagnostics = IPTVGuideDiagnostics(credential: await client.credential, channels: channelIDs.count)
        do {
            let programmes = try await IPTVHTTP.$performanceMetrics.withValue(metrics) {
                try await retrieveGuide(channelIDs: channelIDs, from: from, to: to, diagnostics: diagnostics)
            }
            diagnostics.finish(rows: programmes.count)
            let counts = metrics?.snapshot
            performance?.finish(
                .succeeded,
                metrics: .init(bytes: counts?.bytes, rows: programmes.count, requests: counts?.requests)
            )
            return programmes
        } catch {
            let partial = error as? ServerLiveTVPartialGuideError
            diagnostics.finish(rows: partial?.programmes.count, error: partial?.failure ?? error)
            let counts = metrics?.snapshot
            performance?.finish(
                IPTVPerformanceMetrics.outcome(for: error),
                metrics: .init(bytes: counts?.bytes, rows: partial?.programmes.count, requests: counts?.requests)
            )
            throw error
        }
    }

    private func retrieveGuide(
        channelIDs: [String], from: Date, to: Date, diagnostics: IPTVGuideDiagnostics
    ) async throws -> [ServerLiveTVProgramme] {
        let credential = await client.credential
        if credential.mode == .xtream, credential.explicitGuideURLs.isEmpty {
            var result: [ServerLiveTVProgramme] = []
            var fallbackIDs: [String] = []
            var endpointUnavailable = false
            for id in channelIDs {
                try Task.checkCancellation()
                if endpointUnavailable {
                    diagnostics.fallback(.unavailable)
                    fallbackIDs.append(id)
                    continue
                }
                do {
                    let request = IPTVGuideDiagnostics.Request()
                    let programmes: [ServerLiveTVProgramme]
                    do {
                        programmes = try await IPTVGuideDiagnostics.$request.withValue(request) {
                            try await client.guide(channelID: id, from: from, to: to)
                        }
                        diagnostics.record(request, endpoint: .xtream, rows: programmes.count)
                    } catch {
                        diagnostics.record(request, endpoint: .xtream, error: error)
                        throw error
                    }
                    if programmes.isEmpty {
                        diagnostics.fallback(.empty)
                        fallbackIDs.append(id)
                    }
                    else { result += programmes }
                } catch AppError.notFound, IPTVError.unsupported {
                    diagnostics.fallback(.unavailable)
                    endpointUnavailable = true
                    fallbackIDs.append(id)
                } catch IPTVError.malformed {
                    diagnostics.fallback(.malformed)
                    fallbackIDs.append(id)
                }
            }
            if !fallbackIDs.isEmpty {
                do {
                    result += try await xmlTVGuide(channelIDs: fallbackIDs, from: from, to: to, diagnostics: diagnostics)
                } catch let partial as ServerLiveTVPartialGuideError {
                    throw ServerLiveTVPartialGuideError(
                        programmes: result + partial.programmes, failure: partial.failure
                    )
                } catch {
                    try Task.checkCancellation()
                    guard !result.isEmpty, Self.canIsolateGuideFailure(error) else { throw error }
                    throw ServerLiveTVPartialGuideError(programmes: result, failure: error)
                }
            }
            return result
        }
        return try await xmlTVGuide(channelIDs: channelIDs, from: from, to: to, diagnostics: diagnostics)
    }

    private func xmlTVGuide(
        channelIDs: [String], from: Date, to: Date, diagnostics: IPTVGuideDiagnostics
    ) async throws -> [ServerLiveTVProgramme] {
        guard !channelIDs.isEmpty else { return [] }
        let urls = try await client.guideURLs()
        guard !urls.isEmpty else { return [] }
        guard guideLoader != nil || guideIndex != nil else { throw ServerLiveTVError.unsupportedAPI }
        let indexedCatalog = guideIndex == nil ? nil : try await client.guideChannels()
        var channels: [IPTVGuideChannel] = []
        if let indexedCatalog {
            let byID = Dictionary(uniqueKeysWithValues: indexedCatalog.map { ($0.id, $0) })
            channels = try channelIDs.map {
                guard let channel = byID[$0] else { throw AppError.notFound }
                return channel
            }
        } else {
            for id in channelIDs {
                let record = try await client.record(id)
                channels.append(IPTVGuideChannel(
                    id: id, name: record.item.title, guideID: record.guideID,
                    guideName: record.guideName, country: record.guideCountry
                ))
            }
        }
        var result: [ServerLiveTVProgramme] = []
        var covered = Set<String>()
        var successfulURLs = Set<URL>()
        let credential = await client.credential
        let canRecoverMissingGuide = credential.mode == .xtream && !credential.explicitGuideURLs.isEmpty
        var missingGuide = false
        var firstFailure: (any Error)?
        for url in urls {
            let remaining = channels.filter { !covered.contains($0.id) }
            if remaining.isEmpty { break }
            do {
                let programmes = try await loadXMLTVGuide(
                    url: url, channels: remaining, from: from, to: to, loader: guideLoader,
                    catalog: indexedCatalog, diagnostics: diagnostics
                )
                result += programmes
                covered.formUnion(programmes.map(\.channelID))
                successfulURLs.insert(url)
            } catch AppError.notFound where canRecoverMissingGuide {
                missingGuide = true
            } catch {
                try Task.checkCancellation()
                guard Self.canIsolateGuideFailure(error) else { throw error }
                if firstFailure == nil { firstFailure = error }
            }
        }
        let remaining = channels.filter { !covered.contains($0.id) }
        if missingGuide, !remaining.isEmpty {
            try Task.checkCancellation()
            let fallback = try await client.xtreamGuideURL()
            if let fallback, !successfulURLs.contains(fallback) {
                if urls.contains(fallback) {
                    if firstFailure == nil { firstFailure = AppError.notFound }
                } else {
                    // Use one whole-guide endpoint, never a per-channel recovery fan-out.
                    diagnostics.fallback(.unavailable, channels: remaining.count)
                    do {
                        result += try await loadXMLTVGuide(
                            url: fallback, channels: remaining, from: from, to: to,
                            loader: guideLoader, catalog: indexedCatalog, diagnostics: diagnostics
                        )
                    } catch {
                        try Task.checkCancellation()
                        guard Self.canIsolateGuideFailure(error) else { throw error }
                        if firstFailure == nil { firstFailure = error }
                    }
                }
            } else if fallback == nil, firstFailure == nil {
                firstFailure = AppError.notFound
            }
        }
        if let firstFailure {
            guard !result.isEmpty else { throw firstFailure }
            throw ServerLiveTVPartialGuideError(programmes: result, failure: firstFailure)
        }
        return result
    }

    private static func canIsolateGuideFailure(_ error: any Error) -> Bool {
        switch error {
        case AppError.notFound, AppError.rateLimited, AppError.serverUnreachable,
             IPTVError.malformed, IPTVError.unsupported:
            return true
        case IPTVError.httpStatus(let status):
            return status == 408 || (500...599).contains(status)
        case let error as LiveTVSourceImportError:
            return [.invalidGuide, .guideTooLarge, .redirectBlocked, .downloadFailed,
                    .invalidResponse, .temporarilyUnavailable, .tooManyRequests].contains(error)
        default:
            let error = error as NSError
            return error.domain == NSURLErrorDomain && [
                NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
                NSURLErrorDNSLookupFailed, NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet, NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid
            ].contains(error.code)
        }
    }

    private func loadXMLTVGuide(
        url: URL, channels: [IPTVGuideChannel], from: Date, to: Date,
        loader: IPTVGuideLoader?, catalog: [IPTVGuideChannel]?, diagnostics: IPTVGuideDiagnostics
    ) async throws -> [ServerLiveTVProgramme] {
        try Task.checkCancellation()
        let request = IPTVGuideDiagnostics.Request()
        do {
            let programmes = try await IPTVGuideDiagnostics.$request.withValue(request) {
                if let guideIndex, let catalog {
                    return try await guideIndex.programmes(
                        url: url, channels: channels, from: from, to: to,
                        catalog: { catalog },
                        download: { [client] in
                            let response = try await client.guideDocument(from: url)
                            request.parsing()
                            return response
                        }
                    )
                }
                guard let loader else { throw ServerLiveTVError.unsupportedAPI }
                let data = try await client.guideData(from: url)
                request.parsing()
                return try await loader(data, url, channels, from, to)
            }
            try Task.checkCancellation()
            diagnostics.record(request, endpoint: .xmltv, rows: programmes.count)
            return programmes
        } catch {
            if let failure = error as? LiveTVSourceImportError,
               failure == .invalidGuide || failure == .guideTooLarge {
                await client.discardInvalidGuideData(from: url, failure: failure)
            }
            diagnostics.record(request, endpoint: .xmltv, error: error)
            throw error
        }
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
        await guideIndex?.cancel()
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
