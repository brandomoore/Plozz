import CoreModels
import CoreNetworking
import MediaTransportCore
import TraktService
import XCTest
@testable import AppRuntime

@MainActor
final class ExternalPlaybackRuntimeTests: XCTestCase {
    func testOwnedRelayOpensExactFileAndCallbackRevokesItWithoutPersistingCapability() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        let resolver = try fixture.enableLocalRelay()
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        let link = try XCTUnwrap(fixture.opened.last)
        let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        let media = try XCTUnwrap(query.first { $0.name == "url" }?.value.flatMap(URL.init(string:)))
        XCTAssertEqual(media.host, "127.0.0.1")
        let (bytes, _) = try await URLSession.shared.data(from: media)
        XCTAssertEqual(bytes, Data(repeating: 42, count: 1000))
        let persisted = String(decoding: try XCTUnwrap(
            fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt")
        ), as: UTF8.self)
        XCTAssertFalse(persisted.contains(media.path))
        XCTAssertFalse(persisted.contains("127.0.0.1"))
        fixture.runtime.receive(try fixture.callback(position: "140", playedURL: media))
        await resolver.source.waitForShutdown()
        XCTAssertEqual(fixture.execution.completions, [true])
        let resolved = await resolver.resolved
        XCTAssertEqual(resolved.map(\.relativePath), ["movie.mkv"])
    }

    func testRelayAdmissionFailureNeverOpensAnotherAppAndDrainsSource() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        let resolver = try fixture.enableLocalRelay()
        fixture.runtime.acquireRelayExecution = { _, _, _ in throw ExternalPlayerError.unavailable }
        let opened = try await fixture.launch()
        XCTAssertFalse(opened)
        XCTAssertTrue(fixture.opened.isEmpty)
        await resolver.source.waitForShutdown()
    }

    func testTerminalRelayReadFailureEndsBackgroundExecutionAndSurfacesFailure() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        let resolver = try fixture.enableLocalRelay()
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        await resolver.source.fail(.trust(reason: "test"))
        let link = try XCTUnwrap(fixture.opened.last)
        let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        let media = try XCTUnwrap(query.first { $0.name == "url" }?.value.flatMap(URL.init(string:)))
        do {
            let (_, response) = try await URLSession.shared.data(from: media)
            XCTAssertNotEqual((response as? HTTPURLResponse)?.statusCode, 200)
        } catch {}
        await resolver.source.waitForShutdown()
        XCTAssertEqual(fixture.execution.completions, [false])
        XCTAssertEqual(fixture.runtime.error, .playbackFailed)
    }

    func testRelayStopsOnExpirationContextChangeNewIntentAndForegroundReturn() async throws {
        for mode in 0..<4 {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            let resolver = try fixture.enableLocalRelay()
            let opened = try await fixture.launch()
            XCTAssertTrue(opened)
            switch mode {
            case 0:
                fixture.execution.expire()
                XCTAssertEqual(fixture.runtime.error, .playbackFailed)
            case 1:
                fixture.profileID = "another-profile"
                fixture.runtime.updateRelayContext(fixture.context, isActive: false, isBackground: true)
            case 2: fixture.runtime.beginPlaybackIntent(context: fixture.context)
            default:
                fixture.runtime.updateRelayContext(fixture.context, isActive: false, isBackground: true)
                fixture.runtime.updateRelayContext(fixture.context, isActive: true, isBackground: false)
            }
            await resolver.source.waitForShutdown()
            XCTAssertFalse(fixture.execution.isValid)
        }
    }

    func testRelayOpenFailureAndOwnershipChangeDuringAdmissionReleaseGrant() async throws {
        for changeOwner in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            let resolver = try fixture.enableLocalRelay()
            fixture.openSucceeds = false
            if changeOwner {
                fixture.runtime.acquireRelayExecution = { _, _, _ in
                    fixture.profileID = "another"
                    return fixture.execution
                }
            }
            do {
                let opened = try await fixture.launch()
                XCTAssertFalse(opened)
                XCTAssertFalse(changeOwner)
            } catch is CancellationError { XCTAssertTrue(changeOwner) }
            await resolver.source.waitForShutdown()
            XCTAssertEqual(fixture.execution.completions, [false])
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testNoRelayAdmissionOnUnsupportedPlatformOrForForeignCredentials() async throws {
        for wrongRevision in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            let resolver = try fixture.enableLocalRelay()
            if wrongRevision { fixture.account.credentialRevision = CredentialRevision() }
            else { fixture.runtime.relayAvailable = false }
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            let resolved = await resolver.resolved
            XCTAssertTrue(resolved.isEmpty)
            XCTAssertTrue(fixture.opened.isEmpty)
        }
    }

    func testOnePlayOverrideDoesNotChangeTheDefault() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .builtIn
        fixture.item = fixture.item.requestingExternalPlayer(.infuse)
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.selection.player, .builtIn)
        XCTAssertEqual(fixture.selectedVersion, "version-one")
        fixture.item = fixture.item.requestingExternalPlayer(.builtIn)
        fixture.selection.player = .infuse
        let internalPlayback = try await fixture.launch()
        XCTAssertFalse(internalPlayback)
        XCTAssertEqual(fixture.selection.player, .infuse)
        XCTAssertEqual(fixture.opened.count, 1)
    }

    func testChooserUsesInstalledPlayersAndAuthorizedSupportedSources() {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        func choices() -> [ExternalPlayer] {
            fixture.runtime.availablePlayers(
                for: fixture.item, context: fixture.context, selection: fixture.selection
            )
        }
        XCTAssertFalse(choices().contains(.infuse), "The saved default is not an alternative")
        XCTAssertTrue(choices().contains(.builtIn))
        XCTAssertTrue(choices().contains(.vlc))
        fixture.installed = false
        XCTAssertEqual(choices(), [.builtIn])
        fixture.authorized = false
        XCTAssertEqual(choices(), [])
        fixture.authorized = true
        fixture.kind = .mediaShare
        fixture.baseURL = URL(string: "smb://nas.test/media")!
        XCTAssertEqual(choices(), [])
    }

    func testDefaultAndNonVideoPlaybackDoNotOpenAnotherApp() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .builtIn
        let builtIn = try await fixture.launch()
        XCTAssertFalse(builtIn)
        fixture.selection.player = .infuse
        fixture.item.kind = .series
        let live = try await fixture.launch()
        XCTAssertFalse(live)
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    func testServerVideosTrailersAndExtrasKeepTheirOwnIdentityOnReturn() async throws {
        for kind in [ProviderKind.jellyfin, .emby, .plex] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.kind = kind
            fixture.item.kind = .video
            fixture.item.isTrailer = true
            fixture.item.isExtra = true
            let opened = try await fixture.launch()
            XCTAssertTrue(opened)
            // Some item endpoints omit classification supplied by the extras list.
            fixture.item.isTrailer = false
            fixture.item.isExtra = false
            let restored = ExternalPlaybackRuntime(defaults: fixture.defaults, callbackScheme: fixture.callbackScheme)
            restored.receive(try fixture.callback(position: "140"))
            var completed: MediaItem?
            await restored.processReturn(context: { fixture.context }) { completed = $0.item }
            XCTAssertEqual(completed?.id, fixture.item.id)
            XCTAssertEqual(completed?.sourceAccountID, "account")
            XCTAssertEqual(completed?.isTrailer, true)
            XCTAssertEqual(completed?.isExtra, true)
            XCTAssertEqual(fixture.itemReads, [fixture.item.id])
        }
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
        for mode in 0..<4 {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            switch mode {
            case 0: fixture.request.streamURL = URL(fileURLWithPath: "/video.mkv")
            case 1: fixture.request.streamURL = URL(string: "http://127.0.0.1/video")
            case 2: fixture.request.externalAudioURL = fixture.media
            default:
                fixture.request.externalAudioURL = fixture.media
                fixture.request.playSessionID = "ordinary-conversion"
                fixture.request.deliveryMode = .remux
            }
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertEqual(fixture.releasedSessions, mode == 3 ? 1 : 0)
            XCTAssertNil(fixture.runtime.error)
        }
    }

    func testNASNeverNegotiatesOrLaunchesExternalPlayback() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse, .vlc, .custom] {
            for mediaKind in [MediaItemKind.movie, .episode, .video] {
                let fixture = ExternalPlaybackFixture()
                defer { fixture.cleanup() }
                fixture.kind = .mediaShare
                fixture.baseURL = URL(string: "smb://nas.test/media")!
                fixture.item.kind = mediaKind
                fixture.selection = .init(player: player, customURLTemplate: "customplayer://play?url={url}")
                let opened = try await fixture.launch()
                XCTAssertFalse(opened, "\(player) \(mediaKind)")
                XCTAssertNil(fixture.selectedVersion)
                XCTAssertTrue(fixture.opened.isEmpty)
                XCTAssertEqual(fixture.installationChecks, 0)
                XCTAssertNil(fixture.runtime.receipt)
                XCTAssertNil(fixture.runtime.error)
            }
        }
    }

    func testSiloUsesExternalNegotiationAndRetainsEvenDirectPlaySessions() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.selection.player = player
            let options: StreamingPlaybackOptions? = player == .nativePlayer ? nil : .init(quality: .hd720)
            fixture.kind = .silo
            fixture.request.playSessionID = "silo-session"
            fixture.request.streamingSessionID = "silo-session"
            XCTAssertTrue(fixture.runtime.availablePlayers(
                for: fixture.item, context: fixture.context, selection: fixture.selection
            ).contains(.vlc))
            let opened = try await fixture.runtime.launch(
                item: fixture.item, startPosition: 120, settings: fixture.settings,
                selection: fixture.selection, streamingOptions: options,
                context: { fixture.context }, isPresented: { true }
            )
            XCTAssertTrue(opened)
            XCTAssertEqual(fixture.externalRequests, 1)
            XCTAssertEqual(fixture.selectedVersion, "version-one")
            XCTAssertEqual(fixture.streamingOptions?.quality, options?.quality)
            XCTAssertEqual(fixture.streamingOptions?.startPosition, options == nil ? nil : 0)
            XCTAssertEqual(fixture.runtime.receipt?.streamingSessionID, "silo-session")
            XCTAssertTrue(fixture.releasedSessionIDs.isEmpty)
            let restored = ExternalPlaybackRuntime(defaults: fixture.defaults, callbackScheme: fixture.callbackScheme)
            XCTAssertTrue(restored.receive(try fixture.callback(position: "300")))
            await restored.processReturn(context: { fixture.context }) { completion in
                XCTAssertEqual(completion.position, 300)
            }

            XCTAssertEqual(fixture.releasedSessionIDs, ["silo-session"])
        }
    }

    func testWebDAVUsesIndependentNegotiationAndCorrelatesReturnsWithoutSavingURLs() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse, .vlc] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.kind = .mediaShare
            fixture.selection.player = player
            XCTAssertTrue(fixture.runtime.availablePlayers(
                for: fixture.item, context: fixture.context, selection: fixture.selection
            ).contains(.builtIn))
            let opened = try await fixture.launch()
            XCTAssertTrue(opened)
            XCTAssertEqual(fixture.externalRequests, 1)
            XCTAssertEqual(fixture.selectedVersion, "version-one")
            XCTAssertEqual(fixture.opened.count, 1)
            if player.returnsProgress {
                let data = try XCTUnwrap(fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt"))
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-token"))
                XCTAssertTrue(fixture.runtime.receive(try fixture.callback(position: "300")))
                var returnedPosition: TimeInterval?
                await fixture.runtime.processReturn(context: { fixture.context }) {
                    returnedPosition = $0.position
                }
                XCTAssertEqual(returnedPosition, 300)
            }
        }
    }

    func testWebDAVSubtitlesUseOnlyIndependentURLsAndNeverEnterTheReceipt() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.kind = .mediaShare
        let subtitle = try XCTUnwrap(URL(string: "https://delivery.test/sub.srt?grant=subtitle-ticket"))
        fixture.request.externalSubtitleURLs = [
            URL(fileURLWithPath: "/private/sidecar.srt"),
            try XCTUnwrap(URL(string: "http://127.0.0.1/sidecar.srt")),
            subtitle
        ]
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        let query = try XCTUnwrap(URLComponents(url: fixture.opened[0], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.filter { $0.name == "sub" }.compactMap(\.value), [subtitle.absoluteString])
        let data = try XCTUnwrap(fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("subtitle-ticket"))
    }

    func testWebDAVPasswordHandoffKeepsCredentialsEphemeralAndAcceptsSanitizedReturns() async throws {
        for player in [ExternalPlayer.nativePlayer, .infuse, .vlc] {
            for stripPassword in [false, true] {
                let fixture = ExternalPlaybackFixture()
                defer { fixture.cleanup() }
                fixture.kind = .mediaShare
                fixture.selection.player = player
                let resource = fixture.media
                var components = try XCTUnwrap(URLComponents(url: resource, resolvingAgainstBaseURL: false))
                components.user = "webdav-fixture"
                components.password = "ephemeral-secret"
                fixture.media = try XCTUnwrap(components.url)
                fixture.request.sourceProvider = .mediaShare
                fixture.request.externalSubtitleURLs = [fixture.media]
                let opened = try await fixture.launch()
                XCTAssertTrue(opened)
                let query = try XCTUnwrap(URLComponents(url: fixture.opened[0], resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(query.first { $0.name == "url" }?.value, fixture.media.absoluteString)
                XCTAssertEqual(query.first { $0.name == "sub" }?.value, fixture.media.absoluteString)
                if player.returnsProgress {
                    let data = try XCTUnwrap(fixture.defaults.data(forKey: "com.plozz.externalPlaybackReceipt"))
                    let saved = String(decoding: data, as: UTF8.self)
                    for secret in ["webdav-fixture", "ephemeral-secret", "server.test", "synthetic-token"] {
                        XCTAssertFalse(saved.contains(secret))
                    }
                    let restored = ExternalPlaybackRuntime(defaults: fixture.defaults, callbackScheme: fixture.callbackScheme)
                    XCTAssertTrue(restored.receive(try fixture.callback(
                        position: "300", playedURL: stripPassword ? resource : fixture.media
                    )))
                    var position: TimeInterval?
                    await restored.processReturn(context: { fixture.context }) { position = $0.position }
                    XCTAssertEqual(position, 300)
                }
            }
        }
    }

    func testPasswordOptInDoesNotEnableOtherProvidersCustomLinksOrIncompatibleCredentials() async throws {
        for mode in 0..<4 {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            var source = try XCTUnwrap(URLComponents(url: fixture.media, resolvingAgainstBaseURL: false))
            source.user = "fixture"
            source.password = mode == 3 ? "synthetic@secret" : "synthetic"
            fixture.media = try XCTUnwrap(source.url)
            fixture.kind = mode == 0 ? .jellyfin : .mediaShare
            fixture.request.sourceProvider = mode == 1 ? .jellyfin : .mediaShare
            if mode == 2 {
                fixture.selection = .init(player: .custom, customURLTemplate: "player://play?url={url}")
            }
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testPasswordStrippingDoesNotPermitAnotherResourceCallback() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.kind = .mediaShare
        var source = try XCTUnwrap(URLComponents(url: fixture.media, resolvingAgainstBaseURL: false))
        source.user = "fixture"
        source.password = "synthetic"
        fixture.media = try XCTUnwrap(source.url)
        fixture.request.sourceProvider = .mediaShare
        _ = try await fixture.launch()
        source.user = nil
        source.password = nil
        source.path = "/another.mkv"
        XCTAssertTrue(fixture.runtime.receive(try fixture.callback(
            position: "300", playedURL: XCTUnwrap(source.url)
        )))
        XCTAssertEqual(fixture.runtime.error, .invalidCallback)
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testOrdinaryCallbackCannotOptIntoPasswordStripping() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        _ = try await fixture.launch()
        var source = try XCTUnwrap(URLComponents(url: fixture.media, resolvingAgainstBaseURL: false))
        source.user = "fixture"
        source.password = "synthetic"
        XCTAssertTrue(fixture.runtime.receive(try fixture.callback(
            position: "300", playedURL: XCTUnwrap(source.url)
        )))
        XCTAssertEqual(fixture.runtime.error, .invalidCallback)
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testWebDAVRejectedDeliveryFallsBackAndProfileChangeCancelsHandoff() async throws {
        for cancelled in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.kind = .mediaShare
            if cancelled { fixture.beforeRequest = { fixture.profileID = "another-profile" } }
            else { fixture.requestError = ExternalPlayerError.unsupportedSource }
            do {
                let opened = try await fixture.launch()
                XCTAssertFalse(opened)
                XCTAssertFalse(cancelled)
            } catch { XCTAssertTrue(cancelled && error is CancellationError) }
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testSiloFailedAndCancelledHandoffsReleaseTheirOwnedSession() async throws {
        for cancelled in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.kind = .silo
            fixture.request.playSessionID = "silo-session"
            fixture.request.streamingSessionID = "silo-session"
            fixture.openSucceeds = false
            if cancelled { fixture.beforeRequest = { fixture.profileID = "other" } }
            do {
                let opened = try await fixture.launch()
                XCTAssertFalse(opened)
                XCTAssertFalse(cancelled)
            } catch { XCTAssertTrue(cancelled && error is CancellationError) }
            XCTAssertEqual(fixture.releasedSessionIDs, ["silo-session"])
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testDASHDeliveryUsesPlayerCapabilityEvenWithoutAnMPDExtension() async throws {
        for player in [ExternalPlayer.infuse, .vlc, .custom] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.selection = .init(player: player, customURLTemplate: "player://play?url={url}")
            fixture.request.playbackSource = .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
                provider: .jellyfin, accountID: "account", credentialRevision: .init(),
                itemID: "movie", deliveryMode: .dash,
                resource: .init(pathBase: .configuredBaseURL, path: "manifest")
            ))
            let opened = try await fixture.launch()
            XCTAssertEqual(opened, player == .vlc)
            XCTAssertEqual(fixture.opened.count, player == .vlc ? 1 : 0)
        }
    }

    func testCancelledLaunchReleasesSessionInAnUncancelledTask() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.kind = .silo
        fixture.request.playSessionID = "silo-session"
        fixture.request.streamingSessionID = "silo-session"
        var task: Task<Bool, Error>?
        fixture.beforeOpen = { task?.cancel() }
        task = Task { try await fixture.launch() }
        do {
            _ = try await task?.value
            XCTFail("The handoff task was cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.releasedSessionIDs, ["silo-session"])
        XCTAssertEqual(fixture.cancelledReleaseAttempts, 0)
        XCTAssertNil(fixture.runtime.receipt)
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

    func testMobileConversionPolicyIsNegotiatedWithoutBypassingQualityOrVersion() async throws {
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
            XCTAssertTrue(opened)
            XCTAssertEqual(fixture.streamingOptions?.quality, options.quality)
            XCTAssertEqual(fixture.streamingOptions?.forceTranscoding, options.forceTranscoding)
            XCTAssertEqual(fixture.streamingOptions?.startPosition, 0)
            XCTAssertEqual(fixture.selectedVersion, "version-one")
        }
        XCTAssertEqual(fixture.opened.count, 2)
    }

    func testServerHLSRemuxAndTranscodeHandOffWithoutLocalMaintenance() async throws {
        for kind in [ProviderKind.jellyfin, .emby, .plex] {
            for mode in [AuthenticatedHTTPDeliveryMode.hls, .serverRemux, .serverTranscode] {
                let fixture = ExternalPlaybackFixture()
                defer { fixture.cleanup() }
                fixture.kind = kind
                fixture.request.playbackSource = .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
                    provider: kind, accountID: "account", credentialRevision: .init(),
                    itemID: "movie", deliveryMode: mode,
                    resource: .init(pathBase: .configuredBaseURL, path: "stream.m3u8")
                ))
                fixture.request.isTranscoding = mode == .serverTranscode
                fixture.request.deliveryMode = mode == .serverRemux ? .remux
                    : mode == .serverTranscode ? .transcode : .directPlay
                fixture.request.playSessionID = "converted-session"
                let opened = try await fixture.launch()
                XCTAssertTrue(opened, "\(kind) \(mode)")
                XCTAssertEqual(fixture.releasedSessions, 0, "Opening another app must not stop its stream")
                XCTAssertEqual(fixture.runtime.receipt?.streamingSessionID, mode == .hls ? nil : "converted-session")
                XCTAssertTrue(fixture.runtime.receive(try fixture.callback(position: "300")))
                var completions = 0
                await fixture.runtime.processReturn(context: { fixture.context }) { completion in
                    XCTAssertEqual(completion.position, 300)
                    completions += 1
                }
                XCTAssertEqual(completions, 1)
                XCTAssertEqual(fixture.releasedSessions, mode == .hls ? 0 : 1)
            }
        }
    }

    func testConvertedSessionCleanupSurvivesRelaunchAndRequiresItsOwner() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.request.isTranscoding = true
        fixture.request.playSessionID = "converted-session"
        _ = try await fixture.launch()
        let restored = ExternalPlaybackRuntime(defaults: fixture.defaults, callbackScheme: fixture.callbackScheme)
        XCTAssertTrue(restored.receive(try fixture.callback(position: "300")))
        fixture.profileID = "different-profile"
        await restored.processReturn(context: { fixture.context }) { _ in XCTFail("Wrong profile") }
        XCTAssertEqual(fixture.releasedSessions, 0)
        fixture.profileID = "profile"
        await restored.processReturn(context: { fixture.context }) { _ in }
        XCTAssertEqual(fixture.releasedSessionIDs, ["converted-session"])
        XCTAssertNil(restored.receipt)
    }

    func testNextPlaybackReleasesConvertedVLCSessionWithoutInventingProgress() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.selection.player = .vlc
        fixture.request.isTranscoding = true
        fixture.request.playSessionID = "converted-session"
        _ = try await fixture.launch()
        XCTAssertEqual(fixture.runtime.receipt?.streamingSessionID, "converted-session")
        XCTAssertNil(fixture.runtime.returnID)
        var unsolicited = URLComponents()
        unsolicited.scheme = fixture.callbackScheme
        unsolicited.host = "external-player"
        unsolicited.path = "/success"
        unsolicited.queryItems = [
            .init(name: "session", value: try XCTUnwrap(fixture.runtime.receipt).id.uuidString),
            .init(name: "position", value: "500"),
            .init(name: "lastPlayedUrl", value: fixture.media.absoluteString)
        ]
        XCTAssertTrue(fixture.runtime.receive(try XCTUnwrap(unsolicited.url)))
        XCTAssertNil(fixture.runtime.returnID)
        await fixture.runtime.processReturn(context: { fixture.context }) { _ in
            XCTFail("A cleanup-only receipt must never authorize watch progress")
        }
        XCTAssertEqual(fixture.releasedSessions, 0)
        fixture.selection.player = .builtIn
        _ = try await fixture.launch()
        XCTAssertEqual(fixture.releasedSessionIDs, ["converted-session"])
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testFailedConvertedHandoffReleasesSessionAndClearsReceipt() async throws {
        for cancel in [false, true] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.request.isTranscoding = true
            fixture.request.playSessionID = "converted-session"
            if cancel {
                fixture.beforeRequest = { fixture.profileID = "different" }
            } else {
                fixture.openSucceeds = false
            }
            do {
                let opened = try await fixture.launch()
                XCTAssertFalse(cancel)
                XCTAssertFalse(opened)
            } catch { XCTAssertTrue(cancel && error is CancellationError) }
            XCTAssertEqual(fixture.releasedSessionIDs, ["converted-session"])
            XCTAssertNil(fixture.runtime.receipt)
        }
    }

    func testSupersedingAnInFlightHandoffReleasesItsSessionOnlyOnce() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.request.isTranscoding = true
        fixture.request.playSessionID = "converted-session"
        fixture.beforeOpen = { fixture.runtime.beginPlaybackIntent(context: fixture.context) }
        do {
            _ = try await fixture.launch()
            XCTFail("The old handoff must be canceled")
        } catch { XCTAssertTrue(error is CancellationError) }
        fixture.beforeOpen = nil
        fixture.selection.player = .builtIn
        _ = try await fixture.launch()
        XCTAssertEqual(fixture.releasedSessionIDs, ["converted-session"])
        XCTAssertNil(fixture.runtime.receipt)
    }

    func testIPTVUsesIndependentDeliveryAndNeverItsOrdinaryLocalProxy() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.kind = .iptv
        let opened = try await fixture.launch()
        XCTAssertTrue(opened)
        XCTAssertEqual(fixture.externalRequests, 1)
        XCTAssertNil(fixture.selectedVersion)
        XCTAssertTrue(fixture.runtime.availablePlayers(
            for: fixture.item, context: fixture.context, selection: fixture.selection
        ).contains(.vlc))
        fixture.requestError = ExternalPlayerError.unsupportedSource
        let unsupported = try await fixture.launch()
        XCTAssertFalse(unsupported)
        XCTAssertEqual(fixture.externalRequests, 2)
        XCTAssertNil(fixture.selectedVersion)
        XCTAssertEqual(fixture.opened.count, 1)
    }

    func testInfuseDASHAndScheduledPlaybackRemainInternal() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        fixture.request.playbackSource = .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
            provider: .jellyfin, accountID: "account", credentialRevision: .init(),
            itemID: "movie", deliveryMode: .dash,
            resource: .init(pathBase: .configuredBaseURL, path: "manifest")
        ))
        let dash = try await fixture.launch()
        XCTAssertFalse(dash)
        fixture.request.playbackSource = nil
        fixture.request.suppressOrdinaryWatchReporting = true
        let scheduled = try await fixture.launch()
        XCTAssertFalse(scheduled)
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    func testInvalidQualityAndFailedConversionNeverRetryAnUnconstrainedOriginal() async throws {
        let fixture = ExternalPlaybackFixture()
        defer { fixture.cleanup() }
        let invalid = try await fixture.runtime.launch(
            item: fixture.item, startPosition: nil, settings: fixture.settings, selection: fixture.selection,
            streamingOptions: .init(quality: .invalid(.bitrateTooLow)),
            context: { fixture.context }, isPresented: { true }
        )
        XCTAssertFalse(invalid)
        XCTAssertNil(fixture.selectedVersion)
        fixture.requestError = StreamingQualityError.permissionDenied
        let refused = try await fixture.runtime.launch(
            item: fixture.item, startPosition: nil, settings: fixture.settings, selection: fixture.selection,
            streamingOptions: .init(quality: .hd720, forceTranscoding: true),
            context: { fixture.context }, isPresented: { true }
        )
        XCTAssertFalse(refused)
        XCTAssertEqual(fixture.streamingOptions?.quality, .hd720)
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    func testDownloadedVideoFallsBackBeforeResolvingRemotePlayback() async throws {
        for kind in [ProviderKind.jellyfin, .emby, .plex, .silo, .iptv] {
            let fixture = ExternalPlaybackFixture()
            defer { fixture.cleanup() }
            fixture.kind = kind
            fixture.offlineResolver = ExternalOfflineResolver()
            let opened = try await fixture.launch()
            XCTAssertFalse(opened)
            XCTAssertTrue(fixture.opened.isEmpty)
            XCTAssertNil(fixture.selectedVersion)
            XCTAssertEqual(fixture.externalRequests, 0)
        }
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
    var media = URL(string: "https://server.test/movie.mkv?token=synthetic-token")!
    let callbackScheme = "com.test.external-player"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var runtime = ExternalPlaybackRuntime(
        defaults: defaults, callbackScheme: callbackScheme,
        canOpen: { [unowned self] _ in installationChecks += 1; return installed },
        open: { [unowned self] url in opened.append(url); beforeOpen?(); return openSucceeds }
    )
    var profileID = "profile"
    var userID = "user"
    var authorized = true
    var installed = true
    var installationChecks = 0
    var kind: ProviderKind = .jellyfin
    var baseURL = URL(string: "https://server.test")!
    var requestError: (any Error)?
    var openSucceeds = true
    var opened: [URL] = []
    var selectedVersion: String?
    var releasedSessions = 0
    var cancelledReleaseAttempts = 0
    var releasedSessionIDs: [String] = []
    var streamingOptions: StreamingPlaybackOptions?
    var externalRequests = 0
    var playedWrites: [Bool] = []
    var resumeWrites: [TimeInterval] = []
    var itemReads: [String] = []
    var series: MediaItem?
    var beforeRequest: (@MainActor () -> Void)?
    var beforeOpen: (@MainActor () -> Void)?
    var beforeItem: (@MainActor () -> Void)?
    var offlineResolver: (any OfflinePlaybackResolving)?
    var networkFileResolver: (any MediaTransportNetworkFileResolving)?
    let execution = TestExternalExecution()

    func enableLocalRelay() throws -> ExternalRelayTestResolver {
        kind = .mediaShare
        let resolver = ExternalRelayTestResolver()
        networkFileResolver = resolver
        request.sourceProvider = .mediaShare
        request.streamURL = nil
        request.playbackSource = .networkFile(try NetworkFileLocator(
            accountID: account.id, sourceID: "source", credentialRevision: account.credentialRevision,
            relativePath: "movie.mkv",
            representation: .init(
                size: 1000, identity: .init(kind: .strongETag, value: "\"file\""), consistency: .stronglyBound
            )
        ))
        runtime.relayAvailable = true
        runtime.acquireRelayExecution = { [unowned self] _, _, _ in execution }
        return resolver
    }
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
            server: MediaServer(id: "server", name: "Fixture", baseURL: baseURL, provider: kind),
            userID: userID, userName: "Fixture", deviceID: "fixture", accessToken: "synthetic-token"
        )
    }
    var context: ExternalPlaybackContext {
        ExternalPlaybackContext(
            profileID: profileID, authorizationID: "authorization", accounts: [
                ResolvedAccount(account: account, provider: ExternalPlaybackProvider(session: session, fixture: self))
            ], isAuthorized: authorized, resolver: ExternalPlaybackResolver(url: media),
            offlineResolver: offlineResolver, networkFileResolver: networkFileResolver
        )
    }
    func launch() async throws -> Bool {
        runtime.beginPlaybackIntent(context: context)
        return try await runtime.launch(
            item: item, startPosition: 120, settings: settings, selection: selection,
            context: { self.context }, isPresented: { true }
        )
    }
    func callback(position: String, progress: String? = nil, playedURL: URL? = nil) throws -> URL {
        let openedURL = try XCTUnwrap(opened.last)
        let query = try XCTUnwrap(URLComponents(url: openedURL, resolvingAgainstBaseURL: false)?.queryItems)
        let success = try XCTUnwrap(query.first { $0.name == "x-success" }?.value)
        var components = try XCTUnwrap(URLComponents(string: success))
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "position", value: position),
            .init(name: "lastPlayedUrl", value: (playedURL ?? media).absoluteString)
        ]
        if let progress { components.queryItems?.append(.init(name: "progress", value: progress)) }
        return try XCTUnwrap(components.url)
    }
    func cleanup() {
        runtime.beginPlaybackIntent(context: context)
        defaults.removePersistentDomain(forName: suite)
    }
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

private struct ExternalPlaybackProvider: StreamingSessionReleasing, ExternalPlaybackProviding, WatchStateProviding, ResumeStateWriting {
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
    ) async throws -> PlaybackRequest {
        await MainActor.run { fixture.streamingOptions = streaming }
        return try await playbackInfo(for: itemID, mediaSourceID: mediaSourceID, forceTranscode: forceTranscode)
    }
    func externalPlaybackInfo(
        for itemID: String, mediaSourceID: String?, player: ExternalPlayer,
        streaming: StreamingPlaybackOptions?
    ) async throws -> PlaybackRequest {
        try await MainActor.run {
            guard kind != .iptv || streaming?.requiresConversionPolicy != true else {
                throw ExternalPlayerError.unsupportedSource
            }
            fixture.externalRequests += 1
            fixture.streamingOptions = streaming
            if kind == .silo || kind == .mediaShare { fixture.selectedVersion = mediaSourceID }
            fixture.beforeRequest?()
            if let error = fixture.requestError { throw error }
            return fixture.request
        }
    }
    func releaseStreamingSession(_ request: PlaybackRequest) async {
        if let id = request.streamingSessionID { await releaseStreamingSession(id: id) }
    }
    func releaseStreamingSession(id: String) async {
        let cancelled = Task.isCancelled
        await MainActor.run {
            if cancelled { fixture.cancelledReleaseAttempts += 1 }
            fixture.releasedSessions += 1
            fixture.releasedSessionIDs.append(id)
        }
    }
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
