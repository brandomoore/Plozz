import XCTest
import CoreModels
import CoreUI
import AVFoundation
import MediaPlayer
@testable import FeatureMusic

@MainActor
final class MusicNowPlayingOwnershipTests: XCTestCase {
    func testGlobalScrobbleOrderDoesNotWaitForOutgoingProvider() async throws {
        let controller = AudioPlaybackController(nowPlayingPublisher: MusicPublisherSpy())
        let gate = MusicResolveGate()
        let oldStarted = expectation(description: "Old provider entered")
        let newStarted = expectation(description: "New track scrobbled")
        let oldStopped = expectation(description: "Old provider stopped")
        var scrobbles: [String] = []
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: file)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441000))
        buffer.frameLength = 441000
        let audio = try AVAudioFile(forWriting: file, settings: format.settings)
        try audio.write(from: buffer)
        controller.scrobbleObserver = { track, event, _, _ in
            scrobbles.append("\(track.id):\(event.rawValue)")
            if track.id == "new", event == .start { newStarted.fulfill() }
        }
        controller.play(
            tracks: [MusicTrack(id: "old", title: "Old", sourceAccountID: "a")],
            startIndex: 0, resolveStreamURL: { _ in .init(url: file) },
            reportPlayback: { _, event, _, _ in
                if event == .start {
                    oldStarted.fulfill()
                    await gate.wait()
                }
                if event == .stop { oldStopped.fulfill() }
            }
        )
        await fulfillment(of: [oldStarted], timeout: 2)
        controller.stop()
        controller.play(
            tracks: [MusicTrack(id: "new", title: "New", sourceAccountID: "b")],
            startIndex: 0, resolveStreamURL: { _ in .init(url: file) },
            reportPlayback: { _, _, _, _ in }
        )
        await fulfillment(of: [newStarted], timeout: 2)
        XCTAssertEqual(scrobbles, ["old:start", "old:stop", "new:start"])
        await gate.release()
        await fulfillment(of: [oldStopped], timeout: 2)
        XCTAssertEqual(scrobbles, ["old:start", "old:stop", "new:start"])
    }

    func testDeferredReportsKeepOutgoingSinksAndLifecycleOrder() async throws {
        let controller = AudioPlaybackController(nowPlayingPublisher: MusicPublisherSpy())
        let gate = MusicResolveGate()
        let started = expectation(description: "Outgoing start entered")
        let stopped = expectation(description: "Outgoing stop delivered")
        let scrobbled = expectation(description: "Outgoing scrobble delivered")
        var oldEvents: [PlaybackEvent] = []
        var oldScrobbles: [PlaybackEvent] = []
        var incomingEvents: [PlaybackEvent] = []
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: file)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        let audio = try AVAudioFile(forWriting: file, settings: format.settings)
        try audio.write(from: buffer)
        controller.scrobbleObserver = { _, event, _, _ in
            oldScrobbles.append(event)
            if event == .stop { scrobbled.fulfill() }
        }
        controller.play(
            tracks: [MusicTrack(id: "old", title: "Old", duration: 100)],
            startIndex: 0, resolveStreamURL: { _ in .init(url: file) },
            reportPlayback: { track, event, _, _ in
                XCTAssertEqual(track.id, "old")
                oldEvents.append(event)
                if event == .start {
                    started.fulfill()
                    await gate.wait()
                }
                if event == .stop { stopped.fulfill() }
            }
        )
        await fulfillment(of: [started], timeout: 2)
        controller.pause()
        controller.play(
            tracks: [MusicTrack(id: "new", title: "New")],
            startIndex: 0, resolveStreamURL: { _ in nil },
            reportPlayback: { _, event, _, _ in incomingEvents.append(event) }
        )
        controller.scrobbleObserver = { _, event, _, _ in incomingEvents.append(event) }
        await Task.yield()
        XCTAssertEqual(oldEvents, [.start], "Pause and stop must await the start report")
        await gate.release()
        await fulfillment(of: [stopped, scrobbled], timeout: 2)
        XCTAssertEqual(oldEvents, [.start, .pause, .stop])
        XCTAssertEqual(oldScrobbles, [.start, .pause, .stop])
        XCTAssertTrue(incomingEvents.isEmpty)
    }

    func testRepeatedPlaylistEntriesAndCrossAccountIDsDoNotReuseCurrentTrack() async {
        let provider = MusicTestProvider()
        let account = provider.resolved()
        let playlist = PlaylistDetailViewModel(
            playlist: MusicPlaylist(id: "list", title: "List", sourceAccountID: account.account.id),
            context: MusicContext(accounts: [account])
        )
        await playlist.load()
        XCTAssertEqual(playlist.tracks.map(\.id), ["song", "song"])
        XCTAssertNotEqual(playlist.tracks[0].playlistEntryID, playlist.tracks[1].playlistEntryID)

        let controller = AudioPlaybackController(nowPlayingPublisher: MusicPublisherSpy())
        defer { controller.stop() }
        controller.play(tracks: playlist.tracks, startIndex: 0, resolveStreamURL: { _ in nil })
        controller.play(tracks: playlist.tracks, startIndex: 1, resolveStreamURL: { _ in nil })
        XCTAssertEqual(controller.index, 1)
        controller.toggleShuffle()
        controller.toggleShuffle()
        XCTAssertEqual(controller.index, 1, "Unshuffle must retain the selected occurrence")
        var other = playlist.tracks[1]
        other.sourceAccountID = "other-account"
        controller.play(tracks: [other], startIndex: 0, resolveStreamURL: { _ in nil })
        XCTAssertEqual(controller.currentTrack?.sourceAccountID, "other-account")
    }

    func testVideoTakeoverCancelsPendingMusicAndExplicitResumeReclaimsIt() async {
        let publisher = MusicPublisherSpy()
        let controller = AudioPlaybackController(nowPlayingPublisher: publisher)
        let began = expectation(description: "Music resolution began")
        let gate = MusicResolveGate()
        controller.play(tracks: [MusicTrack(id: "track", title: "Track")], startIndex: 0,
                        resolveStreamURL: { _ in
            began.fulfill()
            await gate.wait()
            return nil
        })
        await fulfillment(of: [began], timeout: 1)
        publisher.resign()
        await gate.release()
        await Task.yield()

        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(publisher.isActive)
        XCTAssertEqual(publisher.activations, 1)
        XCTAssertEqual(controller.currentTrack?.id, "track", "Takeover preserves the queue")

        // A new explicit queue request may reclaim transport; asynchronous
        // completion of the old request must never do so.
        controller.play(tracks: [MusicTrack(id: "other", title: "Other")], startIndex: 0,
                        resolveStreamURL: { _ in nil })
        XCTAssertTrue(publisher.isActive)
        XCTAssertEqual(publisher.activations, 2)
        controller.stop()
        XCTAssertFalse(publisher.isActive)
    }

    @MainActor
    final class MusicAvailabilityTests: XCTestCase {
        func testFailedProbePreservesOnlyActiveEnabledCachedLibraries() async {
            let provider = MusicTestProvider(libraryProbe: { throw AppError.serverUnreachable })
            let store = EphemeralMusicAvailabilityStore(seed: ["account": ["music"], "removed": ["old"]])
            let model = MusicAvailabilityModel(store: store)
            await model.probe(accounts: [provider.resolved()], visibility: .default, retryDelays: [])
            XCTAssertTrue(model.hasMusic)
            XCTAssertEqual(store.load(), ["account": ["music"]])
            await model.probe(accounts: [provider.resolved()],
                              visibility: HomeLibraryVisibility(disabledKeys: ["account:music"]), retryDelays: [])
            XCTAssertFalse(model.hasMusic)
            XCTAssertEqual(store.load(), ["account": ["music"]])
        }

        func testSuccessfulEmptyResponseRemovesCachedMusic() async {
            let provider = MusicTestProvider(libraryProbe: { [] })
            let store = EphemeralMusicAvailabilityStore(seed: ["account": ["music"]])
            let model = MusicAvailabilityModel(store: store)
            await model.probe(accounts: [provider.resolved()], visibility: .default, retryDelays: [])
            XCTAssertFalse(model.hasMusic)
            XCTAssertTrue(store.load().isEmpty)
        }

        func testTransientFailureRecoversWithinBoundedRetry() async {
            let probe = MusicLibraryProbe(results: [.failure(.serverUnreachable), .success(["music"])])
            let provider = MusicTestProvider(libraryProbe: { try await probe.load() })
            let model = MusicAvailabilityModel(store: EphemeralMusicAvailabilityStore())
            await model.probe(accounts: [provider.resolved()], visibility: .default, retryDelays: [.zero])
            XCTAssertTrue(model.hasMusic)
            let calls = await probe.calls
            XCTAssertEqual(calls, 2)
        }

        func testPersistentFailureHasBoundedRetriesAndAuthenticationDoesNotRetry() async {
            for (error, expectedCalls) in [(AppError.serverUnreachable, 3), (.unauthorized, 1), (.rateLimited(retryAfter: 60), 1)] {
                let probe = MusicLibraryProbe(results: [.failure(error)])
                let provider = MusicTestProvider(libraryProbe: { try await probe.load() })
                let model = MusicAvailabilityModel(store: EphemeralMusicAvailabilityStore(seed: ["account": ["music"]]))
                await model.probe(accounts: [provider.resolved()], visibility: .default, retryDelays: [.zero, .zero])
                let calls = await probe.calls
                XCTAssertEqual(calls, expectedCalls)
                XCTAssertTrue(model.hasMusic)
            }
        }

        func testSupersededAndCancelledProbesCannotPublish() async {
            for cancel in [false, true] {
                let gate = MusicResolveGate()
                let entered = expectation(description: "Probe entered")
                let provider = MusicTestProvider(libraryProbe: {
                    entered.fulfill()
                    await gate.wait()
                    return [MediaLibrary(id: "stale", title: "Stale", kind: .folder)]
                })
                let store = EphemeralMusicAvailabilityStore()
                let model = MusicAvailabilityModel(store: store)
                let pending = Task {
                    await model.probe(accounts: [provider.resolved()], visibility: .default, retryDelays: [])
                }
                await fulfillment(of: [entered], timeout: 1)
                if cancel { pending.cancel() }
                else { await model.probe(accounts: [], visibility: .default, retryDelays: []) }
                await gate.release()
                await pending.value
                XCTAssertTrue(store.load().isEmpty)
                XCTAssertFalse(model.hasMusic)
            }
        }
    }

    private actor MusicLibraryProbe {
        let results: [Result<[String], AppError>]
        private(set) var calls = 0
        init(results: [Result<[String], AppError>]) { self.results = results }
        func load() throws -> [MediaLibrary] {
            let result = results[min(calls, results.count - 1)]
            calls += 1
            return try result.get().map { MediaLibrary(id: $0, title: $0, kind: .folder) }
        }
    }

    private final class MusicTestProvider: MediaProvider, MusicProvider, Sendable {
        let kind = ProviderKind.jellyfin
        let session = UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://music.example")!, provider: .jellyfin),
            userID: "user", userName: "User", deviceID: "device", accessToken: ""
        )
        let libraryProbe: @Sendable () async throws -> [MediaLibrary]
        init(libraryProbe: @escaping @Sendable () async throws -> [MediaLibrary] = { [] }) {
            self.libraryProbe = libraryProbe
        }
        func resolved() -> ResolvedAccount {
            ResolvedAccount(account: Account(id: "account", from: session), provider: self)
        }
        func musicLibraries() async throws -> [MediaLibrary] { try await libraryProbe() }
        func tracks(in containerID: String) async throws -> [CoreModels.MusicTrack] {
            [MusicTrack(id: "song", title: "Song"), MusicTrack(id: "song", title: "Song")]
        }
        func musicItems(in containerID: String, kind: MusicItemKind, page: PageRequest) async throws -> MusicPage { MusicPage() }
        func audioPlaybackInfo(for trackID: String, queueContext: [String]?) async throws -> AudioPlaybackRequest { throw AppError.notFound }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }
}

private actor MusicResolveGate {
    var continuation: CheckedContinuation<Void, Never>?
    var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    @MainActor
    final class MusicPlaybackReportQueueTests: XCTestCase {
        func testHeartbeatsCoalesceAndAnotherAccountDoesNotWaitForSlowServer() async {
            let queue = MusicPlaybackReportQueue()
            let gate = MusicResolveGate()
            let started = expectation(description: "Slow server entered")
            let healthy = expectation(description: "Other server delivered")
            let latest = expectation(description: "Latest heartbeat delivered")
            var positions: [Int] = []
            queue.enqueue(accountID: "slow", event: .start) {
                started.fulfill()
                await gate.wait()
            }
            await fulfillment(of: [started], timeout: 1)
            for position in 1...20 {
                queue.enqueue(accountID: "slow", event: .progress) {
                    positions.append(position)
                    if position == 20 { latest.fulfill() }
                }
            }
            queue.enqueue(accountID: "healthy", event: .start) { healthy.fulfill() }
            await fulfillment(of: [healthy], timeout: 1)
            XCTAssertTrue(positions.isEmpty)
            await gate.release()
            await fulfillment(of: [latest], timeout: 1)
            XCTAssertEqual(positions, [20])
        }

        func testStopDiscardsPendingHeartbeatsButRetainsLifecycleOrder() async {
            let queue = MusicPlaybackReportQueue()
            let gate = MusicResolveGate()
            let started = expectation(description: "Start entered")
            let stopped = expectation(description: "Stop delivered")
            var events: [PlaybackEvent] = []
            queue.enqueue(accountID: "account", event: .start) {
                events.append(.start)
                started.fulfill()
                await gate.wait()
            }
            await fulfillment(of: [started], timeout: 1)
            for _ in 0..<20 {
                queue.enqueue(accountID: "account", event: .progress) { events.append(.progress) }
            }
            queue.enqueue(accountID: "account", event: .pause) { events.append(.pause) }
            queue.enqueue(accountID: "account", event: .stop) {
                events.append(.stop)
                stopped.fulfill()
            }
            await gate.release()
            await fulfillment(of: [stopped], timeout: 1)
            XCTAssertEqual(events, [.start, .pause, .stop])
        }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class MusicPublisherSpy: NowPlayingPublishing {
    var isActive = false
    var activations = 0
    var resigned: (@MainActor () -> Void)?
    func bind(player: AVPlayer?) {}
    func activate(onCommand: @escaping @MainActor (NowPlayingCommand) -> Void,
                  onResigned: @escaping @MainActor () -> Void) {
        isActive = true
        activations += 1
        resigned = onResigned
    }
    func publish(_ info: [String: Any], state: MPNowPlayingPlaybackState,
                 transport: NowPlayingTransport) {}
    func invalidate() { isActive = false }
    func resign() {
        isActive = false
        resigned?()
    }
}

final class MusicFormatTests: XCTestCase {
    func testDurationUnderAnHour() {
        XCTAssertEqual(MusicFormat.duration(187), "3:07")
        XCTAssertEqual(MusicFormat.duration(0), "0:00")
        XCTAssertEqual(MusicFormat.duration(59), "0:59")
    }

    func testDurationOverAnHour() {
        XCTAssertEqual(MusicFormat.duration(3753), "1:02:33")
    }

    func testDurationHandlesNilAndInvalid() {
        XCTAssertEqual(MusicFormat.duration(nil), "--:--")
        XCTAssertEqual(MusicFormat.duration(-5), "--:--")
        XCTAssertEqual(MusicFormat.duration(.infinity), "--:--")
    }
}

final class MusicPagePagingTests: XCTestCase {
    func testCountAndHasMore() {
        let page = MusicPage(
            albums: [MusicAlbum(id: "a", title: "A"), MusicAlbum(id: "b", title: "B")],
            startIndex: 0,
            totalCount: 10
        )
        XCTAssertEqual(page.count, 2)
        XCTAssertEqual(page.endIndex, 2)
        XCTAssertTrue(page.hasMore)
    }

    func testNoMoreWhenExhausted() {
        let page = MusicPage(
            tracks: [MusicTrack(id: "t", title: "T")],
            startIndex: 9,
            totalCount: 10
        )
        XCTAssertFalse(page.hasMore)
    }
}

final class MusicTrackSubtitleTests: XCTestCase {
    func testSubtitleCombinesArtistAndAlbum() {
        let track = MusicTrack(id: "t", title: "Song", albumTitle: "LP", artistName: "Artist")
        XCTAssertEqual(track.subtitle, "Artist · LP")
    }

    func testSubtitleFallsBackToWhateverIsPresent() {
        XCTAssertEqual(MusicTrack(id: "t", title: "S", artistName: "Only Artist").subtitle, "Only Artist")
        XCTAssertNil(MusicTrack(id: "t", title: "S").subtitle)
    }
}

/// Authority matrix for caching a *negative* (no synced lyrics) resolve. These
/// guard the v2→v5 cache-poisoning regression history — particularly H1a, where
/// a background prefetch (title-only fallback disabled) that finds nothing for a
/// track filed under a different artist must NOT cache an authoritative negative,
/// or it suppresses the visible play's full fallback for 7 days.
final class LyricsNegativeAuthorityTests: XCTestCase {
    /// Baseline: every needed source answered with full effort → authoritative.
    func testFullEffortReachableNegativeIsAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// H1a: a prefetch that skipped the title-only fallback while a duration was
    /// available is reduced-effort — the fallback that finds different-artist
    /// filings never ran — so its negative is NOT authoritative.
    func testPrefetchWithoutTitleOnlyFallbackIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: true
        ))
    }

    /// Without a usable duration the visible resolve couldn't run the title-only
    /// fallback either (it's duration-gated), so a fallback-disabled negative is
    /// as complete as it'll get and stays authoritative.
    func testFallbackDisabledButNoDurationStaysAuthoritative() {
        XCTAssertTrue(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: false,
            hasUsableDuration: false
        ))
    }

    /// An unreachable server (offline/DNS/TLS) can never produce a trusted
    /// negative regardless of the other signals.
    func testUnreachableServerIsNeverAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: false,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: true,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB skipped purely for a missing artist → incomplete → not authoritative.
    func testMissingArtistSkipIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: true,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// LRCLIB available but unreachable (throttled/cancelled mid-skip) → the song
    /// it might have had goes unconfirmed → not authoritative.
    func testAvailableButUnreachableLRCLIBIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: false,
            lrclibAvailable: true,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// B / H1b: lyrics were turned OFF, so LRCLIB was skipped and only the server
    /// was consulted. That skip is a temporary user setting, not a verdict — the
    /// server-only negative must NOT be cached as authoritative, or enabling
    /// lyrics and replaying would keep reading the poisoned negative for 7 days.
    func testLyricsDisabledServerOnlyNegativeIsNotAuthoritative() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: true
        ))
    }

    /// The disabled-skip guard holds even with no usable duration: re-enabling
    /// lyrics should still trigger a fresh LRCLIB lookup, so the negative formed
    /// while disabled is never authoritative.
    func testLyricsDisabledStaysNonAuthoritativeWithoutDuration() {
        XCTAssertFalse(LyricsNegativeAuthority.isAuthoritative(
            serverReachable: true,
            lrclibSkippedForMissingArtist: false,
            lrclibSkippedForDisabled: true,
            lrclibAvailable: false,
            lrclibReachable: false,
            allowedTitleOnlyFallback: true,
            hasUsableDuration: false
        ))
    }
}

@MainActor
final class MusicStreamResolutionTests: XCTestCase {
    func testResolverMaterializesAuthenticatedSourceAtPlaybackBoundary() async throws {
        let credentialRevision = CredentialRevision(rawValue: UUID())
        let locator = try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin,
            accountID: "account",
            credentialRevision: credentialRevision,
            itemID: "track",
            deliveryMode: .directFile,
            formatHint: MediaFormatHint(container: "flac"),
            purpose: .audioStream,
            resource: try AuthenticatedHTTPResource(
                pathBase: .serverRoot,
                path: "/Audio/track/universal"
            )
        )
        let provider = ResolverMusicProvider(
            request: AudioPlaybackRequest(
                track: MusicTrack(id: "track", title: "Track"),
                playbackSource: .authenticatedHTTP(locator)
            )
        )
        let expectedURL = URL(
            string: "https://media.example/Audio/track/universal?api_key=secret"
        )!
        let resolver = RecordingAuthenticatedResolver(url: expectedURL)

        let resolved = await streamURLResolver(
            for: provider,
            authenticatedHTTPResolver: resolver
        )(MusicTrack(id: "track", title: "Track"))

        XCTAssertEqual(resolved?.url, expectedURL)
        let captured = await resolver.capturedLocator()
        XCTAssertEqual(captured, locator)
    }
}

private final class ResolverMusicProvider: MusicProvider, @unchecked Sendable {
    let accountID = "account"
    let providerKind = ProviderKind.jellyfin
    private let request: AudioPlaybackRequest

    init(request: AudioPlaybackRequest) {
        self.request = request
    }

    func musicLibraries() async throws -> [MediaLibrary] { [] }

    func musicItems(
        in containerID: String,
        kind: MusicItemKind,
        page: PageRequest
    ) async throws -> MusicPage {
        MusicPage()
    }

    func audioPlaybackInfo(
        for trackID: String,
        queueContext: [String]?
    ) async throws -> AudioPlaybackRequest {
        request
    }
}

@MainActor
private final class RecordingAuthenticatedResolver:
    AuthenticatedHTTPResourceResolving
{
    private let url: URL
    private var locator: AuthenticatedHTTPPlaybackLocator?

    init(url: URL) {
        self.url = url
    }

    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        self.locator = locator
        return url
    }

    func capturedLocator() -> AuthenticatedHTTPPlaybackLocator? {
        locator
    }
}
