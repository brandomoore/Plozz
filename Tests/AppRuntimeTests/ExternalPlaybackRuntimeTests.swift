import CoreModels
import CoreNetworking
import TraktService
import XCTest
@testable import AppRuntime

@MainActor
final class ExternalPlaybackRuntimeTests: XCTestCase {
    func testDefaultAndNonVideoPlaybackDoNotOpenAnotherApp() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .builtIn
        let builtIn = try await fixture.launch()
        XCTAssertFalse(builtIn)
        fixture.selection.player = .infuse
        fixture.item.kind = .video
        let live = try await fixture.launch()
        XCTAssertFalse(live)
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    func testLaunchPreservesVersionResumeAndPersistsOnlyNonSecretReceipt() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.selectedVersion, "version-one")
        let query = try XCTUnwrap(URLComponents(url: fixture.opened[0], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "position" }?.value, "115")
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt"))
        let persisted = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(persisted.contains("synthetic-token"))
        XCTAssertFalse(persisted.contains("https://"))
        XCTAssertFalse(persisted.contains("Fixture movie"))
        XCTAssertNil(fixture.runtime.returnID)
        XCTAssertTrue(fixture.runtime.consumeForegroundDeparture(forProfile: fixture.profileID))
        XCTAssertFalse(fixture.runtime.consumeForegroundDeparture(forProfile: fixture.profileID))
    }

    func testUnavailableAndOpenFailureFallBackWithoutChangingTheSelection() async throws {
        for installed in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.installed = installed
            fixture.openSucceeds = false
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            XCTAssertEqual(fixture.selection.player, .infuse)
            XCTAssertNil(fixture.runtime.receipt)
            XCTAssertNil(fixture.runtime.error)
            XCTAssertFalse(fixture.runtime.consumeForegroundDeparture(forProfile: fixture.profileID))
        }
    }

    func testSourceRestrictionsFallBackAndReleaseRejectedStreamingSessions() async throws {
        for mode in 0..<6 {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            switch mode {
            case 0: fixture.request.streamURL = URL(fileURLWithPath: "/video.mkv")
            case 1: fixture.request.streamURL = URL(string: "http://127.0.0.1/video")
            case 2: fixture.request.externalAudioURL = fixture.media
            case 3: fixture.request.isTranscoding = true
            case 4:
                fixture.request.streamingSessionID = "converted-session"
                fixture.request.deliveryMode = .transcode
            default:
                fixture.request.playSessionID = "ordinary-conversion"
                fixture.request.deliveryMode = .remux
            }
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertEqual(fixture.releasedSessions, mode >= 4 ? 1 : 0)
            XCTAssertNil(fixture.runtime.error)
        }
    }

    func testIPTVNASAndSiloNeverNegotiateOrLaunchExternalPlayback() async throws {
        for kind in [ProviderKind.iptv, .mediaShare, .silo] {
            for player in [ExternalPlayer.nativePlayer, .infuse, .vlc, .custom] {
                for mediaKind in [MediaItemKind.movie, .episode, .video] {
                    let fixture = ExternalPlaybackFixture()
                    defer { fixture.cleanup() }
                    fixture.kind = kind
                    fixture.item.kind = mediaKind
                    fixture.selection = .init(player: player, customURLTemplate: "customplayer://play?url={url}")
                    let opened = try await fixture.launch()
                    XCTAssertFalse(opened, "\(kind) \(player) \(mediaKind)")
                    XCTAssertNil(fixture.selectedVersion)
                    XCTAssertTrue(fixture.opened.isEmpty)
                    XCTAssertEqual(fixture.installationChecks, 0)
                    XCTAssertNil(fixture.runtime.receipt)
                    XCTAssertNil(fixture.runtime.error)
                }
            }
        }
    }

    func testJellyfinEmbyAndPlexStillHandOffSupportedMoviesAndEpisodes() async throws {
        for kind in [ProviderKind.jellyfin, .emby, .plex] {
            for mediaKind in [MediaItemKind.movie, .episode] {
                let fixture = ExternalPlaybackFixture()
                defer { fixture.cleanup() }
                fixture.kind = kind
                fixture.item.kind = mediaKind
                let opened = try await fixture.launch()
                XCTAssertTrue(opened)
                XCTAssertEqual(fixture.opened.count, 1)
            }
        }
    }

    func testPreparationErrorFallsBackButCancellationDoesNotStartAnotherPlayer() async throws {
        for cancelled in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.requestError = cancelled ? CancellationError() : AppError.notFound
            do {
                let opened = try await fixture.launch()
                XCTAssertFalse(cancelled)
                XCTAssertFalse(opened)
            } catch { XCTAssertTrue(cancelled && error is CancellationError) }
            XCTAssertTrue(fixture.opened.isEmpty)
        }
    }

    func testProfileChangeDuringPreparationPreventsLaunch() async {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.beforeRequest = { fixture.profileID = "another-profile" }
        do {
            _ = try await fixture.launch()
            XCTFail("Expected canceled handoff")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testMobileConversionPolicyFallsBackBeforePreparingAStream() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        for options in [
            StreamingPlaybackOptions(quality: .hd720),
            StreamingPlaybackOptions(quality: .original, forceTranscoding: true)
        ] {
            let opened = try await fixture.runtime.launch(
                item: fixture.item, startPosition: 0, settings: fixture.settings, selection: fixture.selection,
                streamingOptions: options, context: { fixture.context }, isPresented: { true }
            )
            XCTAssertFalse(opened)
        }
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertNil(fixture.selectedVersion)
    }

    func testDownloadedVideoFallsBackBeforeResolvingRemotePlayback() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.offlineResolver = ExternalOfflineResolver()
        let opened = try await fixture.launch()
        XCTAssertFalse(opened)
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertNil(fixture.selectedVersion)
    }

    func testCallbackSchemeAndNonceAreCaseInsensitive() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        var callback = try XCTUnwrap(URLComponents(url: fixture.callback(position: "300"), resolvingAgainstBaseURL: false))
        callback.scheme = fixture.callbackScheme.uppercased()
        callback.queryItems = callback.queryItems?.map {
            $0.name == "session" ? .init(name: $0.name, value: $0.value?.lowercased()) : $0
        }
        XCTAssertTrue(fixture.runtime.receive(try XCTUnwrap(callback.url)))
        XCTAssertEqual(fixture.runtime.receipt?.position, 300)
    }

    func testChangedIdentityDuringReturnHydrationDoesNotPublishProgress() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        fixture.runtime.receive(try fixture.callback(position: "300"))
        fixture.beforeItem = { fixture.userID = "different-viewer" }
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in XCTFail("Changed viewer") }
        XCTAssertNotNil(fixture.runtime.returnID)
        fixture.userID = "user"
        fixture.beforeItem = nil
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in }
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testReturnedProgressSurvivesRelaunchAndWaitsForAuthorizedOwner() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        let receiptID = try XCTUnwrap(fixture.runtime.receipt?.id)
        fixture.runtime.receive(try fixture.callback(position: "300"))
        let restored = ExternalPlaybackRuntime(
            defaults: fixture.defaults, callbackScheme: fixture.callbackScheme,
            canOpen: { _ in false }, open: { _ in false }
        )
        fixture.profileID = "other"
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Wrong profile") }
        fixture.profileID = "profile"
        fixture.authorized = false
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Locked profile") }
        fixture.authorized = true
        fixture.userID = "other-user"
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Wrong server user") }
        fixture.userID = "user"
        let revision = fixture.account.credentialRevision
        fixture.account.credentialRevision = CredentialRevision()
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Rotated credentials") }
        fixture.account.credentialRevision = revision
        var result: ExternalPlaybackCompletion?
        await restored.processReturn(context: { fixture.context }) { result = $0 }
        XCTAssertEqual(result?.id, receiptID)
        XCTAssertEqual(result?.position, 300)
        XCTAssertEqual(result?.watchedPercent, 50)
        XCTAssertEqual(result?.item.sourceAccountID, fixture.account.id)
        XCTAssertNil(restored.receipt)
    }

    func testInvalidCallbacksDoNotWriteProgress() async throws {
        for position in ["NaN", "inf", "-1", "9999999999", "800", ""] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            _ = try await fixture.launch()
            fixture.runtime.receive(try fixture.callback(position: position))
            await fixture.runtime.processReturn(context: { fixture.context }) { _ in XCTFail("Invalid result") }
            XCTAssertEqual(fixture.runtime.error, .invalidCallback)
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testWrongURLDuplicateFieldsExpiredAndSupersededCallbacksAreRejected() async throws {
        for mode in 0..<4 {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            _ = try await fixture.launch()
            var callback = try XCTUnwrap(URLComponents(url: fixture.callback(position: "300"), resolvingAgainstBaseURL: false))
            if mode == 0 {
                callback.queryItems?.removeAll { $0.name == "lastPlayedUrl" }
                callback.queryItems?.append(.init(name: "lastPlayedUrl", value: "https://wrong.test/video"))
            } else if mode == 1 {
                callback.queryItems?.append(.init(name: "position", value: "20"))
            } else if mode == 3 {
                fixture.runtime.beginPlaybackIntent()
            }
            fixture.runtime.receive(
                try XCTUnwrap(callback.url),
                now: mode == 2 ? Date().addingTimeInterval(86_401) : Date()
            )
            await fixture.runtime.processReturn(context: { fixture.context }) { _ in XCTFail("Rejected callback") }
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testZeroPositionIsValidAndCallbackReplayIsIgnored() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        let callback = try fixture.callback(position: "0")
        fixture.runtime.receive(callback)
        fixture.runtime.receive(try fixture.callback(position: "600"))
        var count = 0
        await fixture.runtime.processReturn(context: { fixture.context }) {
            count += 1
            XCTAssertEqual($0.position, 0)
            XCTAssertEqual($0.watchedPercent, 0)
        }
        fixture.runtime.receive(callback)
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in count += 1 }
        XCTAssertEqual(count, 1)
    }

    func testReceiptIsRetainedUntilDurableOutboxAcceptsIt() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        fixture.runtime.receive(try fixture.callback(position: "300"))
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in
            throw ExternalPlayerError.persistence
        }
        XCTAssertNotNil(fixture.runtime.returnID)
        XCTAssertEqual(fixture.runtime.error, .progressSyncFailed)
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in }
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testFailureCallbackNeverUsesThirdPartyErrorTextOrCreatesProgress() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        var callback = try XCTUnwrap(URLComponents(url: fixture.callback(position: "300"), resolvingAgainstBaseURL: false))
        callback.path = "/error"
        callback.queryItems?.append(.init(name: "errorMessage", value: "synthetic-token"))
        fixture.runtime.receive(try XCTUnwrap(callback.url))
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in XCTFail("Player failure") }
        XCTAssertEqual(fixture.runtime.error, .playbackFailed)
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testVLCLaunchDoesNotPromiseAProgressReceipt() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .vlc
        _ = try await fixture.launch()
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testNativeProgressRejectsMalformedOrDuplicateValues() async throws {
        for values in [["NaN"], ["inf"], ["-0.1"], ["1.01"], [""], ["80"], ["0.5", "1"]] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.selection.player = .nativePlayer
            _ = try await fixture.launch()
            var callback = try XCTUnwrap(URLComponents(
                url: fixture.callback(position: "300"), resolvingAgainstBaseURL: false
            ))
            callback.queryItems?.append(contentsOf: values.map { .init(name: "progress", value: $0) })
            fixture.runtime.receive(try XCTUnwrap(callback.url))
            await fixture.runtime.processReturn(context: { fixture.context }) { _ in XCTFail("Invalid progress") }
            XCTAssertEqual(fixture.runtime.error, .invalidCallback, "\(values)")
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testNativeFractionSurvivesRelaunchAndRetainsOwnerChecks() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .nativePlayer
        fixture.item.runtime = nil
        _ = try await fixture.launch()
        fixture.runtime.receive(try fixture.callback(position: "600", progress: "1.0000"))
        let restored = ExternalPlaybackRuntime(
            defaults: fixture.defaults, callbackScheme: fixture.callbackScheme,
            canOpen: { _ in false }, open: { _ in false }
        )
        fixture.profileID = "another-profile"
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Wrong profile") }
        XCTAssertNotNil(restored.returnID)
        fixture.profileID = "profile"
        var result: ExternalPlaybackCompletion?
        await restored.processReturn(context: { fixture.context }) { result = $0 }
        XCTAssertEqual(result?.watchedPercent, 100)
        XCTAssertEqual(result?.position, 600)
        XCTAssertNil(restored.receipt)
    }

    func testNativeFractionDoesNotBypassPositionOrMediaValidation() async throws {
        for position in ["NaN", "inf", "-1", "9999999999"] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.selection.player = .nativePlayer
            _ = try await fixture.launch()
            fixture.runtime.receive(try fixture.callback(position: position, progress: "1"))
            XCTAssertEqual(fixture.runtime.error, .invalidCallback)
        }
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .nativePlayer
        _ = try await fixture.launch()
        var callback = try XCTUnwrap(URLComponents(
            url: fixture.callback(position: "600", progress: "1"), resolvingAgainstBaseURL: false
        ))
        callback.queryItems?.removeAll { $0.name == "lastPlayedUrl" }
        callback.queryItems?.append(.init(name: "lastPlayedUrl", value: "https://wrong.test/video"))
        fixture.runtime.receive(try XCTUnwrap(callback.url))
        XCTAssertEqual(fixture.runtime.error, .invalidCallback)
    }

    func testNativeMissingFractionAndInfuseKeepRuntimeFallback() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.selection.player = player
            _ = try await fixture.launch()
            // Infuse's unrelated query values must not gain Native Player semantics.
            let fraction = player == .infuse ? "1" : nil
            fixture.runtime.receive(try fixture.callback(position: "300", progress: fraction))
            var result: ExternalPlaybackCompletion?
            await fixture.runtime.processReturn(context: { fixture.context }) { result = $0 }
            XCTAssertEqual(result?.watchedPercent, 50)

            _ = try await fixture.launch()
            fixture.runtime.receive(try fixture.callback(position: "700", progress: fraction))
            XCTAssertEqual(fixture.runtime.error, .invalidCallback)
        }
    }

    func testLegacyReceiptWithoutFractionStillRestores() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .nativePlayer
        _ = try await fixture.launch()
        fixture.runtime.receive(try fixture.callback(position: "540"))
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["progress"])
        let restored = ExternalPlaybackRuntime(
            defaults: fixture.defaults, callbackScheme: fixture.callbackScheme,
            canOpen: { _ in false }, open: { _ in false }
        )
        var result: ExternalPlaybackCompletion?
        await restored.processReturn(context: { fixture.context }) { result = $0 }
        XCTAssertEqual(result?.watchedPercent, 90)
    }
}

@MainActor
private final class ExternalPlaybackFixture {
    let suite = "ExternalPlaybackRuntimeTests.\(UUID().uuidString)"
    let media = URL(string: "https://server.test/movie.mkv?token=synthetic-token")!
    let callbackScheme = "com.test.external-player"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var runtime = ExternalPlaybackRuntime(
        defaults: defaults, callbackScheme: callbackScheme,
        canOpen: { [unowned self] _ in installationChecks += 1; return installed },
        open: { [unowned self] url in opened.append(url); return openSucceeds }
    )
    var profileID = "profile"
    var userID = "user"
    var authorized = true
    var installed = true
    var installationChecks = 0
    var kind: ProviderKind = .jellyfin
    var requestError: (any Error)?
    var openSucceeds = true
    var opened: [URL] = []
    var selectedVersion: String?
    var releasedSessions = 0
    var playedWrites: [Bool] = []
    var resumeWrites: [TimeInterval] = []
    var itemReads: [String] = []
    var series: MediaItem?
    var beforeRequest: (@MainActor () -> Void)?
    var beforeItem: (@MainActor () -> Void)?
    var offlineResolver: (any OfflinePlaybackResolving)?
    var item = MediaItem(
        id: "movie", title: "Fixture movie", kind: .movie, runtime: 600,
        sourceAccountID: "account", selectedVersionID: "version-one"
    )
    lazy var request = PlaybackRequest(item: item, streamURL: media, startPosition: 120)
    var settings = PlaybackSettings.default
    var selection = ExternalPlayerSettings(player: .infuse)
    lazy var account = Account(id: "account", from: session)
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "server", name: "Fixture", baseURL: URL(string: "https://server.test")!, provider: kind),
            userID: userID, userName: "Fixture", deviceID: "fixture", accessToken: "synthetic-token"
        )
    }
    var context: ExternalPlaybackContext {
        ExternalPlaybackContext(
            profileID: profileID, authorizationID: "authorization", accounts: [
                ResolvedAccount(account: account, provider: ExternalPlaybackProvider(session: session, fixture: self))
            ], isAuthorized: authorized, resolver: ExternalPlaybackResolver(url: media),
            offlineResolver: offlineResolver
        )
    }
    func launch() async throws -> Bool {
        runtime.beginPlaybackIntent()
        return try await runtime.launch(
            item: item, startPosition: 120, settings: settings, selection: selection,
            context: { self.context }, isPresented: { true }
        )
    }
    func callback(position: String, progress: String? = nil) throws -> URL {
        let openedURL = try XCTUnwrap(opened.last)
        let query = try XCTUnwrap(URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?.queryItems)
        let success = try XCTUnwrap(query.first { $0.name == "x-success" }?.value)
        var components = try XCTUnwrap(URLComponents(string: success))
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "position", value: position),
            .init(name: "lastPlayedUrl", value: media.absoluteString)
        ]
        if let progress { components.queryItems?.append(.init(name: "progress", value: progress)) }
        return try XCTUnwrap(components.url)
    }
    func cleanup() { defaults.removePersistentDomain(forName: suite) }
}

private struct ExternalPlaybackResolver: AuthenticatedHTTPResourceResolving {
    let url: URL
    func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL { url }
}

private struct ExternalOfflineResolver: OfflinePlaybackResolving {
    func localPlaybackURL(for item: MediaItem, versionID: String?) async -> URL? {
        URL(fileURLWithPath: "/private/offline/video.mkv")
    }
}

private struct ExternalPlaybackProvider: StreamingQualityProviding, WatchStateProviding, ResumeStateWriting {
    var kind: ProviderKind { session.server.provider }
    let session: UserSession
    let fixture: ExternalPlaybackFixture
    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem {
        await MainActor.run {
            fixture.itemReads.append(id)
            fixture.beforeItem?()
            if let series = fixture.series, id == series.id { return series }
            return fixture.item
        }
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage { throw AppError.notFound }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { await fixture.request }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await MainActor.run {
            fixture.selectedVersion = mediaSourceID
            fixture.beforeRequest?()
            if let error = fixture.requestError { throw error }
            return fixture.request
        }
    }
    func playbackInfo(
        for itemID: String, mediaSourceID: String?, forceTranscode: Bool, streaming: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest { await fixture.request }
    func releaseStreamingSession(_ request: PlaybackRequest) async { await MainActor.run { fixture.releasedSessions += 1 } }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func setPlayed(_ played: Bool, itemID: String) async throws {
        await MainActor.run { fixture.playedWrites.append(played) }
    }
    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async throws {
        await MainActor.run { fixture.resumeWrites.append(seconds) }
    }
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
final class NativePlayerTraktDeliveryTests: XCTestCase {
    func testCompletedCallbacksReachTraktDespiteMissingOrMismatchedRuntime() async throws {
        for provider in [ProviderKind.jellyfin, .emby, .plex] {
            for kind in [MediaItemKind.movie, .episode] {
                for runtime in [nil, 580, 600, 900] as [TimeInterval?] {
                    let fixture = fixture(provider: provider, kind: kind)
                    defer { fixture.cleanup() }
                    fixture.item.runtime = runtime
                    let probe = delivery(fixture)
                    let result = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1.0000")
                    await probe.reconciler.drain()
                    XCTAssertEqual(result?.watchedPercent, 100)
                    XCTAssertEqual(fixture.playedWrites, [true])
                    XCTAssertEqual(fixture.resumeWrites, [0])
                    let requests = await probe.http.requests
                    XCTAssertEqual(requests.map(\.path), ["/scrobble/stop"])
                    let json = try payload(requests)
                    XCTAssertEqual(json["progress"] as? Double, 100)
                    if kind == .movie {
                        let movie = try XCTUnwrap(json["movie"] as? [String: Any])
                        XCTAssertEqual((movie["ids"] as? [String: Any])?["imdb"] as? String, "tt0111161")
                    } else {
                        let show = try XCTUnwrap(json["show"] as? [String: Any])
                        XCTAssertEqual((show["ids"] as? [String: Any])?["tvdb"] as? Int, 12345)
                        let episode = try XCTUnwrap(json["episode"] as? [String: Any])
                        XCTAssertEqual(episode["season"] as? Int, 1)
                        XCTAssertEqual(episode["number"] as? Int, 2)
                    }
                    let state = await probe.reconciler.snapshot()
                    XCTAssertTrue(state.pending.isEmpty)
                    XCTAssertNil(fixture.runtime.error)
                }
            }
        }
    }

    func testNativeCompletionThresholdUsesFractionNotCatalogRuntime() async throws {
        for (fraction, finished) in [("0.0000", false), ("0.8000", false), ("0.8999", false), ("0.9000", true)] {
            let fixture = fixture()
            defer { fixture.cleanup() }
            fixture.item.runtime = 300
            let probe = delivery(fixture)
            _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: fraction)
            await probe.reconciler.drain()
            let requests = await probe.http.requests
            let hasProgress = fraction != "0.0000"
            XCTAssertEqual(requests.map(\.path), hasProgress ? [finished ? "/scrobble/stop" : "/scrobble/pause"] : [])
            if hasProgress {
                let json = try payload(requests)
                XCTAssertEqual(json["progress"] as? Double, finished ? 100 : try XCTUnwrap(Double(fraction)) * 100)
            }
            XCTAssertEqual(fixture.playedWrites, finished ? [true] : [])
            XCTAssertEqual(fixture.resumeWrites, finished ? [0] : [600])
        }
    }

    func testPartialReturnsSendPausedProgressForSupportedPlayersAndProviders() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse] {
            for provider in [ProviderKind.jellyfin, .emby, .plex] {
                for kind in [MediaItemKind.movie, .episode] {
                    let fixture = fixture(provider: provider, kind: kind)
                    defer { fixture.cleanup() }
                    fixture.selection.player = player
                    fixture.item.runtime = 1200
                    let probe = delivery(fixture)
                    _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "0.5000")
                    await probe.reconciler.drain()
                    let requests = await probe.http.requests
                    XCTAssertEqual(requests.map(\.path), ["/scrobble/pause"])
                    let json = try payload(requests)
                    XCTAssertEqual(json["progress"] as? Double, 50)
                    XCTAssertTrue(fixture.playedWrites.isEmpty)
                    XCTAssertEqual(fixture.resumeWrites, [600])
                    let state = await probe.reconciler.snapshot()
                    XCTAssertTrue(state.pending.isEmpty)
                    XCTAssertTrue(state.appliedTrakt.isEmpty, "Partial playback must not suppress later completion")
                }
            }
        }
    }

    func testPartialProgressRecoversEpisodeIdentityAfterRelaunchWithoutRepeatingResumeWrite() async throws {
        let fixture = fixture(kind: .episode)
        defer { fixture.cleanup() }
        fixture.item.providerIDs = [:]
        fixture.item.seriesID = "show"
        let probe = delivery(fixture)
        _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "0.5")
        await probe.reconciler.drain()
        let pending = await probe.reconciler.snapshot()
        XCTAssertEqual(pending.pending.first?.traktProgress?.progress, 50)
        XCTAssertEqual(fixture.resumeWrites, [600])
        XCTAssertTrue(fixture.playedWrites.isEmpty)
        let stored = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(pending))
        try probe.store.save(stored)
        fixture.series = MediaItem(id: "show", title: "Fixture show", kind: .series, providerIDs: ["Tvdb": "12345"])
        let restored = WatchStateReconciler(store: probe.store, applier: probe.applier)
        await restored.drain()
        let requests = await probe.http.requests
        XCTAssertEqual(requests.map(\.path), ["/scrobble/pause"])
        let json = try payload(requests)
        XCTAssertEqual(json["progress"] as? Double, 50)
        let show = try XCTUnwrap(json["show"] as? [String: Any])
        XCTAssertEqual((show["ids"] as? [String: Any])?["tvdb"] as? Int, 12345)
        XCTAssertEqual(fixture.resumeWrites, [600])
        let final = await restored.snapshot()
        XCTAssertTrue(final.pending.isEmpty)
    }

    func testPartialProgressWaitsForOriginalProfileAndServerUser() async throws {
        for changeProfile in [false, true] {
            let fixture = fixture()
            defer { fixture.cleanup() }
            let probe = delivery(fixture)
            _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "0.5")
            if changeProfile { fixture.profileID = "other" } else { fixture.userID = "other" }
            await probe.reconciler.drain()
            let blockedRequests = await probe.http.requests
            XCTAssertTrue(blockedRequests.isEmpty)
            let blocked = await probe.reconciler.snapshot()
            XCTAssertEqual(blocked.pending.first?.traktProgress?.progress, 50)
            fixture.profileID = "profile"
            fixture.userID = "user"
            await probe.reconciler.drain()
            let requests = await probe.http.requests
            XCTAssertEqual(requests.map(\.path), ["/scrobble/pause"])
        }
    }

    func testOrdinaryPlaybackCheckpointsDoNotQueuePausedExternalProgress() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
            item: fixture.item, position: 600, watchedPercent: 50,
            primaryAccountID: "account", crossServerSync: false
        ))
        XCTAssertEqual(mutation.resumePosition, 600)
        XCTAssertNil(mutation.traktProgress)
        XCTAssertNil(mutation.trakt)
    }

    func testMissingIDsRemainPendingAndRecoverWithoutRepeatingServerWrite() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        fixture.item.providerIDs = [:]
        let probe = delivery(fixture)
        _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1")
        await probe.reconciler.drain()
        let blocked = await probe.reconciler.snapshot()
        XCTAssertEqual(fixture.playedWrites, [true])
        XCTAssertEqual(blocked.pending.count, 1)
        XCTAssertEqual(blocked.pending.first?.traktPending, true)
        XCTAssertTrue(blocked.appliedTrakt.isEmpty)
        XCTAssertTrue(blocked.pending.first?.targets.isEmpty == true)
        let requestsBefore = await probe.http.requests
        XCTAssertTrue(requestsBefore.isEmpty)
        // The original target must survive serialization after its server write.
        let stored = try JSONDecoder().decode(WatchOutboxState.self, from: JSONEncoder().encode(blocked))
        try probe.store.save(stored)
        let restored = WatchStateReconciler(store: probe.store, applier: probe.applier)
        fixture.item.providerIDs = ["Imdb": "tt0111161"]
        await restored.drain()
        await restored.drain()
        let requests = await probe.http.requests
        XCTAssertEqual(requests.map(\.path), ["/scrobble/stop"])
        XCTAssertEqual(fixture.playedWrites, [true])
        XCTAssertEqual(fixture.resumeWrites, [0])
        let final = await restored.snapshot()
        XCTAssertTrue(final.pending.isEmpty)
        XCTAssertEqual(final.appliedTrakt.count, 1)
    }

    func testEpisodeCanRecoverFromItsOwnSeriesIDs() async throws {
        let fixture = fixture(kind: .episode)
        defer { fixture.cleanup() }
        fixture.item.providerIDs = [:]
        fixture.item.seriesID = "show"
        fixture.series = MediaItem(id: "show", title: "Fixture show", kind: .series, providerIDs: ["Tvdb": "12345"])
        let probe = delivery(fixture)
        _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1")
        await probe.reconciler.drain()
        let requests = await probe.http.requests
        let json = try payload(requests)
        let show = try XCTUnwrap(json["show"] as? [String: Any])
        XCTAssertEqual((show["ids"] as? [String: Any])?["tvdb"] as? Int, 12345)
        let episode = try XCTUnwrap(json["episode"] as? [String: Any])
        XCTAssertEqual(episode["number"] as? Int, 2)
        XCTAssertEqual(fixture.itemReads, ["movie", "movie", "show"])
    }

    func testMetadataRecoveryCannotCrossProfileOrServerUserSwitch() async throws {
        for changeProfile in [false, true] {
            let fixture = fixture()
            defer { fixture.cleanup() }
            fixture.item.providerIDs = [:]
            let probe = delivery(fixture)
            _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1")
            fixture.beforeItem = {
                fixture.item.providerIDs = ["Imdb": "tt0111161"]
                if changeProfile { fixture.profileID = "other" } else { fixture.userID = "other" }
            }
            await probe.reconciler.drain()
            let requests = await probe.http.requests
            XCTAssertTrue(requests.isEmpty)
            let state = await probe.reconciler.snapshot()
            XCTAssertEqual(state.pending.first?.traktPending, true)
            XCTAssertTrue(state.appliedTrakt.isEmpty)
            fixture.beforeItem = nil
            fixture.profileID = "profile"
            fixture.userID = "user"
            await probe.reconciler.drain()
            let retried = await probe.http.requests
            XCTAssertEqual(retried.map(\.path), ["/scrobble/stop"])
        }
    }

    func testChangedEpisodeCoordinatesCannotRecoverToAnotherEpisode() async throws {
        let fixture = fixture(kind: .episode)
        defer { fixture.cleanup() }
        fixture.item.providerIDs = [:]
        let probe = delivery(fixture)
        _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1")
        fixture.item.episodeNumber = 3
        fixture.item.providerIDs = ["SeriesTvdb": "12345"]
        await probe.reconciler.drain()
        let requests = await probe.http.requests
        XCTAssertTrue(requests.isEmpty)
        let state = await probe.reconciler.snapshot()
        XCTAssertEqual(state.pending.first?.traktPending, true)
    }

    func testTraktTransportFailureRetriesWithoutRepeatingServerWrites() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let probe = delivery(fixture)
        await probe.http.setFailure(true)
        _ = try await returnPlayback(fixture, to: probe.reconciler, position: 600, progress: "1")
        await probe.reconciler.drain()
        let blocked = await probe.reconciler.snapshot()
        XCTAssertEqual(blocked.pending.first?.traktPending, true)
        XCTAssertTrue(blocked.appliedTrakt.isEmpty)
        await probe.http.setFailure(false)
        await probe.reconciler.drain()
        let requests = await probe.http.requests
        XCTAssertEqual(requests.map(\.path), ["/scrobble/stop", "/scrobble/stop"])
        XCTAssertEqual(fixture.playedWrites, [true])
        XCTAssertEqual(fixture.itemReads.count, 1, "Transport failures must not trigger metadata recovery")
    }

    private func fixture(
        provider: ProviderKind = .jellyfin, kind: MediaItemKind = .movie
    ) -> ExternalPlaybackFixture {
        let fixture = ExternalPlaybackFixture()
        fixture.selection.player = .nativePlayer
        fixture.kind = provider
        fixture.item.kind = kind
        fixture.item.providerIDs = kind == .movie ? ["Imdb": "tt0111161"] : ["SeriesTvdb": "12345"]
        if kind == .episode {
            fixture.item.seasonNumber = 1
            fixture.item.episodeNumber = 2
            fixture.item.parentTitle = "Fixture show"
        }
        return fixture
    }

    private func delivery(_ fixture: ExternalPlaybackFixture) -> (
        reconciler: WatchStateReconciler, http: NativeTraktHTTP,
        store: InMemoryWatchMutationStore, applier: AppShellWatchMutationApplier
    ) {
        let http = NativeTraktHTTP()
        let scrobbler = TraktScrobbler(
            config: TraktConfig(clientID: "synthetic-client"), http: http,
            tokenStore: InMemoryTraktTokenStore(tokens: TraktTokens(
                accessToken: "synthetic-access", refreshToken: "synthetic-refresh", expiresAt: .distantFuture
            ))
        )
        let identity = fixture.context.identity
        let provider = ExternalPlaybackProvider(session: fixture.session, fixture: fixture)
        let applier = AppShellWatchMutationApplier(
            isActive: { await MainActor.run { fixture.context.identity == identity } },
            validateServerScope: { _ in
                guard await MainActor.run(body: { fixture.context.identity == identity }) else {
                    throw WatchMutationServerScopeError.unavailable
                }
            },
            resolveProvider: { _ in provider },
            applyTrakt: { intent in
                try await scrobbler.scrobbleResult(
                    item: intent.makeScrobbleItem(), progress: intent.progress, event: intent.playbackEvent
                )
            },
            applySimkl: { _ in }, applyAniList: { _ in }, applyMAL: { _ in }
        )
        let store = InMemoryWatchMutationStore()
        return (WatchStateReconciler(store: store, applier: applier), http, store, applier)
    }

    private func returnPlayback(
        _ fixture: ExternalPlaybackFixture, to reconciler: WatchStateReconciler,
        position: Int, progress: String
    ) async throws -> ExternalPlaybackCompletion? {
        let launched = try await fixture.launch()
        XCTAssertTrue(launched)
        XCTAssertEqual(fixture.opened.first?.scheme, fixture.selection.player == .infuse ? "infuse" : "nativeplayer")
        XCTAssertTrue(fixture.runtime.receive(try fixture.callback(position: String(position), progress: progress)))
        let scope = WatchMutationServerScope(
            profile: Profile(id: fixture.profileID, name: "Fixture"), accounts: [fixture.account]
        )
        var completion: ExternalPlaybackCompletion?
        await fixture.runtime.processReturn(context: { fixture.context }) { result in
            completion = result
            var mutation = try XCTUnwrap(WatchMutationFactory.playbackStop(
                item: result.item, position: result.position, watchedPercent: result.watchedPercent,
                primaryAccountID: result.item.sourceAccountID, crossServerSync: false, reportTraktProgress: true
            )?.bindingServerScope(scope))
            mutation.id = result.id
            mutation.capturedAt = result.reportedAt
            let accepted = await reconciler.enqueue(mutation)
            XCTAssertTrue(accepted)
        }
        XCTAssertNotNil(completion)
        return completion
    }

    private func payload(_ requests: [NativeTraktHTTP.Request]) throws -> [String: Any] {
        XCTAssertEqual(requests.count, 1)
        let data = try XCTUnwrap(requests.first?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor NativeTraktHTTP: HTTPClient {
    struct Request: Sendable {
        let path: String
        let body: Data?
    }
    private var fails = false
    private(set) var requests: [Request] = []
    func setFailure(_ value: Bool) { fails = value }
    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        requests.append(Request(path: endpoint.path, body: endpoint.body))
        if fails { throw AppError.serverUnreachable }
        return (Data(), try XCTUnwrap(HTTPURLResponse(
            url: baseURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil
        )))
    }
}
