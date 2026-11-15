#if os(iOS)
import AppRuntime
import AVFoundation
import AVKit
import CoreModels
import CoreNetworking
import EnginePlozzigen
import UIKit
import XCTest
@testable import AppShelliOS
@testable import FeaturePlayback
@testable import ProviderJellyfin
@testable import ProviderPlex

/// Opt-in real-media checks using explicitly authorized internal test identities.
/// Credentials and resolved playback URLs remain in memory, never attachments.
@MainActor
final class ServerLiveTranscodingTests: XCTestCase {
    func testEmbyH264RealMediaPlaybackAndPictureInPicture() async throws {
        try await verify(codec: .preferH264)
    }

    func testEmbyHEVCCapableProfileRealMediaPlaybackAndPictureInPicture() async throws {
        try await verify(codec: .preferHEVC)
    }

    func testJellyfinH264RealMediaPlaybackAndPictureInPicture() async throws {
        try await verifyServer(.jellyfin)
    }

    func testPlexH264RealMediaPlaybackAndPictureInPicture() async throws {
        try await verifyServer(.plex)
    }

    func testJellyfinHEVCRealMediaPlaybackAndPictureInPicture() async throws {
        try await verifyServer(.jellyfin, codec: .preferHEVC)
    }

    func testPlexHEVCRealMediaPlaybackAndPictureInPicture() async throws {
        try await verifyServer(.plex, codec: .preferHEVC)
    }

    func testPlexLiveTVChannelSwitchAndReopenRealPlayback() async throws {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_TV_BROKER"] else {
            throw XCTSkip("Set PLOZZ_LIVE_TV_BROKER for authorized synthetic Live TV testing.")
        }
        let broker = try XCTUnwrap(URL(string: input))
        guard broker.scheme == "http", broker.host == "127.0.0.1",
              broker.user == nil, broker.password == nil, broker.query == nil else {
            throw LivePlaybackConfigurationError("broker address")
        }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: broker.appendingPathComponent("plex"), timeoutInterval: 10)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LivePlaybackConfigurationError()
        }
        let configuration = try JSONDecoder().decode(AuthenticatedConfiguration.self, from: data)
        guard configuration.itemIDs.count == 2, Set(configuration.itemIDs).count == 2,
              let scheme = configuration.baseURL.scheme, ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil, configuration.baseURL.user == nil,
              configuration.baseURL.password == nil, configuration.baseURL.query == nil,
              !configuration.token.isEmpty else {
            throw LivePlaybackConfigurationError()
        }
        try await PlexProvider.verifyAddress(configuration.baseURL, serverID: configuration.serverID)
        let provider = PlexProvider(session: UserSession(
            server: .init(
                id: configuration.serverID, name: "Internal Live TV verification",
                baseURL: configuration.baseURL, provider: .plex
            ),
            userID: configuration.userID, userName: configuration.username,
            deviceID: configuration.deviceID, accessToken: configuration.token
        ))
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(
                provider: .plex, accountID: provider.accountID, credentialRevision: provider.credentialRevision,
                baseURL: configuration.baseURL, token: configuration.token, originProvider: provider
            )
        }
        do {
            let availability = try await provider.liveTVAvailability()
            XCTAssertTrue(availability.supportsPlayback)
            let channels = try await provider.liveTVChannels()
            for id in configuration.itemIDs {
                XCTAssertTrue(channels.contains { $0.id == id })
            }
            let guide = try await provider.liveTVGuide(
                channelIDs: configuration.itemIDs, from: Date(), to: Date().addingTimeInterval(3_600)
            )
            for id in configuration.itemIDs {
                XCTAssertTrue(guide.contains { $0.channelID == id })
            }
            let sequence = configuration.itemIDs + [configuration.itemIDs[0]]
            for (index, id) in sequence.enumerated() {
                let lease = try await provider.openLiveTVChannel(id: id)
                do {
                    guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
                        throw LivePlaybackConfigurationError()
                    }
                    if index == 1 {
                        XCTAssertEqual(locator.resource.path, "video/:/transcode/universal/start.m3u8")
                    } else {
                        XCTAssertTrue(locator.resource.path.hasPrefix("livetv/sessions/"))
                    }
                    let request = PlaybackRequest(
                        item: .init(id: id, title: "Synthetic channel", kind: .movie),
                        playbackSource: lease.playbackSource, sourceProvider: .plex
                    )
                    try await play(
                        request, resolver: resolver, expectedCodec: nil,
                        caseIndex: index, measurementSeconds: 12
                    )
                    await lease.close()
                } catch {
                    await lease.close()
                    throw error
                }
            }
            await provider.teardown()
        } catch {
            await provider.teardown()
            throw error
        }
    }

    private struct AuthenticatedConfiguration: Decodable {
        let baseURL: URL
        let username: String
        let userID: String
        let serverID: String
        let deviceID: String
        let token: String
        let itemIDs: [String]
        let audioLanguage: String?
    }

    private func authenticatedServer(_ kind: ProviderKind, brokerVariable: String) async throws -> (
        configuration: AuthenticatedConfiguration,
        provider: any StreamingQualityProviding & AuthenticatedHTTPOriginProviding,
        resolver: ManagedAuthenticatedHTTPResolver,
        accountID: String
    ) {
        guard let input = ProcessInfo.processInfo.environment[brokerVariable] else {
            throw XCTSkip("Set \(brokerVariable) for authorized real-media testing.")
        }
        let broker = try XCTUnwrap(URL(string: input))
        guard broker.scheme == "http", broker.host == "127.0.0.1",
              broker.user == nil, broker.password == nil, broker.query == nil else {
            throw LivePlaybackConfigurationError(
                "authenticated broker address scheme=\(broker.scheme ?? "nil") host=\(broker.host ?? "nil") "
                + "user=\(broker.user != nil) password=\(broker.password != nil) query=\(broker.query != nil)"
            )
        }
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: broker.appendingPathComponent(kind.rawValue), timeoutInterval: 10)
        )
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LivePlaybackConfigurationError("broker response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let configuration = try JSONDecoder().decode(AuthenticatedConfiguration.self, from: data)
        guard !configuration.itemIDs.isEmpty, configuration.itemIDs.count <= 3,
              let scheme = configuration.baseURL.scheme, ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil, configuration.baseURL.user == nil,
              configuration.baseURL.password == nil, configuration.baseURL.query == nil,
              !configuration.token.isEmpty else {
            throw LivePlaybackConfigurationError("broker configuration fields")
        }
        let session = UserSession(
            server: .init(
                id: configuration.serverID, name: "Internal verification",
                baseURL: configuration.baseURL, provider: kind
            ),
            userID: configuration.userID, userName: configuration.username,
            deviceID: configuration.deviceID, accessToken: configuration.token
        )
        let provider: any StreamingQualityProviding & AuthenticatedHTTPOriginProviding
        let accountID: String
        let revision: CredentialRevision
        if kind == .plex {
            try await PlexProvider.verifyAddress(configuration.baseURL, serverID: configuration.serverID)
            let plex = PlexProvider(session: session, hybridEngineEnabled: true)
            provider = plex
            accountID = plex.accountID
            revision = plex.credentialRevision
        } else {
            var userRequest = URLRequest(
                url: configuration.baseURL.appendingPathComponent("Users").appendingPathComponent(configuration.userID),
                timeoutInterval: 30
            )
            userRequest.setValue(
                JellyfinDeviceProfile(deviceID: configuration.deviceID).authorizationHeaderValue(token: configuration.token),
                forHTTPHeaderField: "Authorization"
            )
            let (userData, userResponse) = try await URLSession.shared.data(for: userRequest)
            guard (userResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw LivePlaybackConfigurationError("test user response \((userResponse as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let user = try JSONDecoder().decode(TestUser.self, from: userData)
            guard !user.Policy.IsAdministrator, user.Name == configuration.username else {
                throw LivePlaybackConfigurationError("test user identity")
            }
            let jellyfin = JellyfinProvider(session: session, hybridEngineEnabled: true, playbackRequests: .init())
            provider = jellyfin
            accountID = jellyfin.accountID
            revision = jellyfin.credentialRevision
        }
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(
                provider: kind, accountID: accountID, credentialRevision: revision,
                baseURL: configuration.baseURL, token: configuration.token, originProvider: provider
            )
        }
        return (configuration, provider, resolver, accountID)
    }

    private func verifyServer(_ kind: ProviderKind, codec: StreamingCodecPreference = .preferH264) async throws {
        let (configuration, provider, resolver, _) = try await authenticatedServer(
            kind, brokerVariable: "PLOZZ_LIVE_TRANSCODE_BROKER"
        )
        for (index, itemID) in configuration.itemIDs.enumerated() {
            let options = StreamingPlaybackOptions(quality: .hd720, codec: codec, forceTranscoding: true)
            let request: PlaybackRequest
            if codec == .preferHEVC {
                let item = try await provider.playbackItem(id: itemID)
                request = try await capableHEVCRequest(
                    item: item, configuration: configuration, provider: provider, options: options
                )
            } else {
                request = try await provider.playbackInfo(
                    for: itemID, mediaSourceID: nil, forceTranscode: true, streaming: options
                )
            }
            let expected: DirectPlayVideoCodec = codec == .preferHEVC ? .hevc : .h264
            let maintenance = StreamingSessionMaintenance()
            maintenance.start(request: request, provider: provider)
            do {
                XCTAssertTrue(request.isTranscoding, "This test must not silently use direct playback.")
                XCTAssertEqual(request.negotiatedStreamingVideoCodec, expected)
                try await play(
                    request, resolver: resolver, expectedCodec: expected, caseIndex: index,
                    measurementSeconds: 30, expectsSDR: codec == .preferH264
                )
                await maintenance.cancel()?.value
                await provider.releaseStreamingSession(request)
            } catch {
                await maintenance.cancel()?.value
                await provider.releaseStreamingSession(request)
                throw error
            }
        }
    }

    func testRealTitlePreferencesAcrossProfilesAndProviders() async throws {
        let suite = "RealTitlePreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = [Profile(name: "Internal crop A"), Profile(name: "Internal crop B")]
        let profileStore = ProfileStore(defaults: defaults)
        profileStore.saveProfiles(profiles)
        profileStore.setRootNamespaceOwnerID(profiles[0].id)
        for (providerIndex, kind) in [ProviderKind.jellyfin, .plex].enumerated() {
            let (configuration, provider, resolver, accountID) = try await authenticatedServer(
                kind, brokerVariable: "PLOZZ_TITLE_PROFILE_BROKER"
            )
            guard configuration.itemIDs.count == 3 else { throw LivePlaybackConfigurationError() }
            let language = try XCTUnwrap(configuration.audioLanguage)
            let visits: [TitlePreferenceVisit] = [
                .init(item: 0, profile: 0, expected: providerIndex == 0 ? .onDemandDefault : .init(),
                      rememberedAudio: providerIndex != 0, saveZoom: .init(), saveAudio: true),
                .init(item: 0, profile: 1, expected: providerIndex == 0 ? .onDemandDefault : .init(mode: .custom, customPercent: 125),
                      saveZoom: .init(mode: .custom, customPercent: 125)),
                .init(item: 0, profile: 0, expected: .init(), rememberedAudio: true),
                .init(item: 1, profile: 0, expected: providerIndex == 0 ? .onDemandDefault : .init(mode: .custom, customPercent: 117),
                      saveZoom: .init(mode: .custom, customPercent: 117)),
                .init(item: 2, profile: 0, expected: .init(mode: .custom, customPercent: 117)),
                .init(item: 0, profile: 1, expected: .init(mode: .custom, customPercent: 125))
            ]
            for (index, visit) in visits.enumerated() {
                let item = try await provider.playbackItem(id: configuration.itemIDs[visit.item])
                XCTAssertEqual(item.kind, visit.item == 0 ? .movie : .episode)
                let seriesIDs: [String: String]
                if let seriesID = item.seriesID {
                    seriesIDs = try await provider.item(id: seriesID).providerIDs
                } else {
                    seriesIDs = [:]
                }
                let profile = profiles[visit.profile]
                profileStore.setActiveProfileID(profile.id)
                profileStore.setActiveAccountIDs([accountID], forProfile: profile.id)
                let restoredProfiles = ProfileStore(defaults: defaults)
                XCTAssertEqual(restoredProfiles.activeProfileID(), profile.id)
                let namespace = profile.settingsNamespace(isDefault: profile.id == restoredProfiles.rootNamespaceOwnerID())
                let store = SeriesTrackPreferenceStore(defaults: defaults, namespace: namespace)
                try await playTitlePreferenceVisit(
                    visit, item: item, seriesIDs: seriesIDs, language: language, provider: provider,
                    resolver: resolver, accountID: accountID, store: store,
                    label: "\(kind.rawValue) visit=\(index) profile=\(visit.profile)"
                )
            }
        }
    }

    private struct TitlePreferenceVisit {
        let item: Int
        let profile: Int
        let expected: VideoZoomPreference
        var rememberedAudio = false
        var saveZoom: VideoZoomPreference?
        var saveAudio = false
    }

    private func playTitlePreferenceVisit(
        _ visit: TitlePreferenceVisit, item: MediaItem, seriesIDs: [String: String], language: String,
        provider: any StreamingQualityProviding & AuthenticatedHTTPOriginProviding,
        resolver: ManagedAuthenticatedHTTPResolver, accountID: String, store: SeriesTrackPreferenceStore,
        label: String
    ) async throws {
        try await waitUntil(seconds: 10, stage: "foreground scene") {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let engine = NativeVideoEngine(
            authenticatedHTTPResolver: resolver, startsMuted: true,
            activePictureAnalyzer: PlozzigenNativePictureAnalyzer()
        )
        let model = PlayerViewModel(
            provider: provider, itemID: item.id, episodeItem: item,
            playbackSettings: .init(rememberAudioTrackPerSeries: false),
            streamingOptions: .init(quality: .hd720, codec: .preferH264, forceTranscoding: true),
            seriesTrackStore: store, seriesAccountFallbackID: accountID, startPosition: 120,
            engineFactory: .init(makeNative: { _ in engine }), authenticatedHTTPResolver: resolver,
            seriesIDResolver: { seriesIDs }
        )
        let controller = PlayerInputViewController(engine: engine, model: model.controls, actions: PlayerActions())
        controller.loadViewIfNeeded()
        controller.attachVideoSurface()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            engine.stopActivePictureAnalysis()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        do {
            await model.load()
            try await waitUntil(seconds: 90, stage: "\(label) decoded playback") {
                model.phase == .ready && engine.hasPresentedVideoFrame
                    && engine.underlyingPlayer?.timeControlStatus == .playing
            }
            try await waitUntil(seconds: 15, stage: "\(label) title preference restoration") {
                model.controls.videoZoom.settings == visit.expected
            }
            XCTAssertEqual(engine.streamingOutputVideoCodec, .h264)
            let request = try XCTUnwrap(model.trackRequest)
            XCTAssertTrue(request.isTranscoding)
            let selected = request.streamingOptions?.selectedAudio(in: request.audioTracks)
            if visit.item == 0 {
                XCTAssertEqual(LanguageMatch.matches(selected?.language, language), visit.rememberedAudio,
                               "The actual server request must use this profile's remembered language.")
            }
            let start = engine.underlyingPlayer?.currentTime().seconds ?? 0
            try await Task.sleep(for: .seconds(6))
            let progress = (engine.underlyingPlayer?.currentTime().seconds ?? 0) - start
            XCTAssertGreaterThan(progress, 4, "Real playback must advance beyond the first frame.")
            if visit.saveAudio {
                let track = try XCTUnwrap(request.audioTracks.first { LanguageMatch.matches($0.language, language) })
                model.selectAudioOption(id: track.id)
                try await waitUntil(seconds: 90, stage: "\(label) selected audio rendition") {
                    guard model.phase == .ready,
                          let current = model.trackRequest,
                          let selected = current.streamingOptions?.selectedAudio(in: current.audioTracks) else { return false }
                    return LanguageMatch.matches(selected.language, language)
                }
                // The SwiftUI player rehosts on engineToken; this UIKit fixture must
                // likewise attach the output created after a rendition retires it.
                controller.attachVideoSurface()
                try await waitUntil(seconds: 60, stage: "\(label) selected audio displayed") {
                    engine.hasPresentedVideoFrame && engine.underlyingPlayer?.timeControlStatus == .playing
                }
            }
            if let zoom = visit.saveZoom { model.controls.videoZoom.settings = zoom }
            let loadedItem = try XCTUnwrap(model.trackRequest?.item)
            let memory = SeriesTrackMemory(store: store, accountFallbackID: accountID,
                                           rememberAudio: false, rememberSubtitle: true)
            XCTAssertEqual(memory.rememberedVideoZoom(for: loadedItem), visit.saveZoom ?? visit.expected)
            if visit.saveAudio || visit.rememberedAudio {
                XCTAssertTrue(LanguageMatch.matches(memory.rememberedAudioLanguage(for: loadedItem), language))
            }
            XCTContext.runActivity(named: "Real title preference playback") { activity in
                let attachment = XCTAttachment(string:
                    "\(label) kind=\(item.kind.rawValue) progress=\(progress) "
                    + "mode=\(model.controls.videoZoom.settings.mode.rawValue) "
                    + "percent=\(model.controls.videoZoom.settings.customPercent) "
                    + "requestedAudio=\(selected?.language ?? "unclassified")"
                )
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            await model.stop()
        } catch {
            await model.stop()
            throw error
        }
    }

    private func capableHEVCRequest(
        item: MediaItem, configuration: AuthenticatedConfiguration,
        provider: any StreamingQualityProviding, options: StreamingPlaybackOptions
    ) async throws -> PlaybackRequest {
        let locator: AuthenticatedHTTPPlaybackLocator
        let sessionID: String?
        if let jellyfin = provider as? JellyfinProvider {
            let client = JellyfinClient(
                baseURL: configuration.baseURL, deviceProfile: .init(deviceID: configuration.deviceID),
                providerKind: .jellyfin, token: configuration.token,
                capabilityProfile: .appleTV(capabilities: .init(supportsHEVC: true), hybridEngineEnabled: true)
            )
            let info = try await client.playbackInfo(
                userID: configuration.userID, itemID: item.id, mediaSourceID: item.versions.first?.id,
                mode: .transcode, streaming: options
            )
            sessionID = info.PlaySessionId
            do {
                XCTAssertNil(info.ErrorCode)
                var source = try XCTUnwrap(info.MediaSources.first)
                source.TranscodingUrl = try source.boundedTranscodingURL(
                    options, supportsHEVC: true, forceVideoTranscode: true
                )
                locator = try jellyfin.authenticatedPlaybackLocator(
                    itemID: item.id, source: source, playSessionID: sessionID, didRemux: false
                )
            } catch {
                if let sessionID { await jellyfin.releaseStreamingEncoding(sessionID) }
                throw error
            }
        } else {
            let plex = try XCTUnwrap(provider as? PlexProvider)
            let client = PlexClient(
                baseURL: configuration.baseURL, deviceProfile: .init(clientIdentifier: configuration.deviceID),
                token: configuration.token, capabilities: .init(supportsHEVC: true), hybridEngineEnabled: true
            )
            let metadata = try await client.metadata(ratingKey: item.id)
            guard metadata.Media?.count == 1 else { throw LivePlaybackConfigurationError() }
            let id = UUID().uuidString
            sessionID = id
            do {
                let url = try XCTUnwrap(client.transcodeURL(ratingKey: item.id, sessionID: id, streaming: options))
                let decision = try await client.validateStreamingTranscode(url: url, options: options)
                XCTAssertEqual(decision.codec, .hevc)
                locator = try plex.authenticatedPlaybackLocator(
                    itemID: item.id, mediaSourceID: item.versions.first?.id, url: url,
                    deliveryMode: .serverTranscode, purpose: .mediaStream, playSessionID: id, formatHint: "m3u8"
                )
            } catch {
                try await client.stopStreamingTranscode(sessionID: id)
                throw error
            }
        }
        var request = PlaybackRequest(
            item: item, playbackSource: .authenticatedHTTP(locator),
            playSessionID: sessionID, deliveryMode: .transcode, sourceProvider: provider.kind
        )
        request.streamingOptions = options
        request.streamingSessionID = sessionID
        request.negotiatedStreamingVideoCodec = .hevc
        return request
    }

    private struct Configuration: Decodable {
        let baseURL: URL
        let username: String
        let itemIDs: [String]
    }

    private struct TestUser: Decodable {
        struct UserPolicy: Decodable { let IsAdministrator: Bool }
        let Name: String
        let Policy: UserPolicy
    }

    private func verify(codec: StreamingCodecPreference) async throws {
        guard let input = ProcessInfo.processInfo.environment["PLOZZ_LIVE_EMBY_CONFIGURATION"] else {
            throw XCTSkip("Set PLOZZ_LIVE_EMBY_CONFIGURATION for authorized real-media testing.")
        }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(input.utf8))
        guard !configuration.itemIDs.isEmpty, configuration.itemIDs.count <= 3,
              let scheme = configuration.baseURL.scheme, ["http", "https"].contains(scheme),
              configuration.baseURL.host != nil,
              configuration.baseURL.user == nil, configuration.baseURL.password == nil,
              configuration.baseURL.query == nil else {
            XCTFail("Provide one to three explicit media IDs and a credential-free server address.")
            return
        }
        let deviceID = "plozz-live-transcoding-\(UUID().uuidString)"
        let client = JellyfinClient(
            baseURL: configuration.baseURL, deviceProfile: .init(deviceID: deviceID), providerKind: .emby
        )
        let auth = try await client.authenticate(username: configuration.username, password: "")
        addTeardownBlock {
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("Sessions/Logout"))
            request.httpMethod = "POST"
            request.setValue(auth.token, forHTTPHeaderField: "X-Emby-Token")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204, "Release the test login.")
        }
        var userRequest = URLRequest(
            url: configuration.baseURL.appendingPathComponent("Users").appendingPathComponent(auth.userID),
            timeoutInterval: 30
        )
        userRequest.setValue(auth.token, forHTTPHeaderField: "X-Emby-Token")
        let (userData, userResponse) = try await URLSession.shared.data(for: userRequest)
        guard (userResponse as? HTTPURLResponse)?.statusCode == 200 else {
            XCTFail("Could not verify the authenticated test identity.")
            return
        }
        let user = try JSONDecoder().decode(TestUser.self, from: userData)
        guard !user.Policy.IsAdministrator, user.Name == configuration.username else {
            XCTFail("Live playback requires the configured non-administrator test identity.")
            return
        }
        let serverID = try XCTUnwrap(auth.serverID)
        let provider = JellyfinProvider(
            session: .init(
                server: .init(id: serverID, name: "Internal verification", baseURL: configuration.baseURL, provider: .emby),
                userID: auth.userID, userName: auth.userName, deviceID: deviceID, accessToken: auth.token
            ),
            hybridEngineEnabled: true, playbackRequests: .init()
        )
        let resolver = ManagedAuthenticatedHTTPResolver()
        resolver.configure { _ in
            .init(
                provider: .emby, accountID: provider.accountID, credentialRevision: provider.credentialRevision,
                baseURL: configuration.baseURL, token: auth.token, originProvider: provider
            )
        }
        for (index, itemID) in configuration.itemIDs.enumerated() {
            let item = try await provider.playbackItem(id: itemID)
            let options = StreamingPlaybackOptions(quality: .hd720, codec: codec, forceTranscoding: true)
            let request: PlaybackRequest
            if codec == .preferHEVC {
                // Simulators report no hardware HEVC. Exercise the real protocol
                // with a capable-device profile without changing production detection.
                let capableClient = JellyfinClient(
                    baseURL: configuration.baseURL, deviceProfile: .init(deviceID: deviceID),
                    providerKind: .emby, token: auth.token,
                    capabilityProfile: .appleTV(capabilities: .init(supportsHEVC: true), hybridEngineEnabled: true)
                )
                let info = try await capableClient.playbackInfo(
                    userID: auth.userID, itemID: itemID, mediaSourceID: item.versions.first?.id,
                    mode: .transcode, streaming: options
                )
                do {
                    XCTAssertNil(info.ErrorCode)
                    var source = try XCTUnwrap(info.MediaSources.first)
                    source.TranscodingUrl = try source.boundedTranscodingURL(
                        options, supportsHEVC: true, forceVideoTranscode: true
                    )
                    try source.requestSDRForH264Transcode(provider: .emby, forceVideoTranscode: true)
                    let locator = try provider.authenticatedPlaybackLocator(
                        itemID: itemID, source: source, playSessionID: info.PlaySessionId, didRemux: false
                    )
                    var converted = PlaybackRequest(
                        item: item, playbackSource: .authenticatedHTTP(locator),
                        playSessionID: info.PlaySessionId, deliveryMode: .transcode, sourceProvider: .emby
                    )
                    converted.streamingOptions = options
                    converted.streamingSessionID = info.PlaySessionId
                    converted.negotiatedStreamingVideoCodec = .hevc
                    request = converted
                } catch {
                    if let id = info.PlaySessionId { await provider.releaseStreamingEncoding(id) }
                    throw error
                }
            } else {
                request = try await provider.playbackInfo(
                    for: itemID, mediaSourceID: item.versions.first?.id,
                    forceTranscode: true, streaming: options
                )
            }
            do {
                XCTAssertTrue(request.isTranscoding)
                XCTAssertEqual(request.negotiatedStreamingVideoCodec, codec == .preferHEVC ? .hevc : .h264)
                try await play(
                    request, resolver: resolver, expectedCodec: codec == .preferHEVC ? .hevc : .h264, caseIndex: index
                )
                await provider.releaseStreamingSession(request)
            } catch {
                await provider.releaseStreamingSession(request)
                throw error
            }
        }
    }

    private func play(
        _ request: PlaybackRequest, resolver: ManagedAuthenticatedHTTPResolver,
        expectedCodec: DirectPlayVideoCodec?, caseIndex: Int,
        measurementSeconds: Int = 12, expectsSDR: Bool = false
    ) async throws {
        try await waitUntil(seconds: 10, stage: "foreground scene") {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        let engine = NativeVideoEngine(authenticatedHTTPResolver: resolver, startsMuted: true)
        let pip = PlozziOSPictureInPictureController()
        defer {
            pip.detach()
            engine.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let surface = engine.makeVideoOutputView()
        surface.frame = host.view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(surface)
        pip.attach(engine: engine)
        let started = ContinuousClock.now
        await engine.load(request: request, startPosition: 0)
        try await waitUntil(seconds: 60, stage: "first video frame") { engine.hasPresentedVideoFrame }
        let firstFrameTime = started.duration(to: .now)
        let player = try XCTUnwrap(engine.underlyingPlayer)
        let item = try XCTUnwrap(player.currentItem)
        let dimensions = item.presentationSize
        // A decoded first frame can precede AVPlayer's cold-encoder buffering.
        // Measure sustained playback from playing, not from readiness.
        try await waitUntil(seconds: 60, stage: "playing") { player.timeControlStatus == .playing }
        let playingTime = started.duration(to: .now)
        let initialPosition = player.currentTime().seconds
        try await Task.sleep(for: .seconds(measurementSeconds))
        let progress = player.currentTime().seconds - initialPosition
        let access = item.accessLog()?.events.last
        let evidence = "case=\(caseIndex) codec=\(expectedCodec?.rawValue ?? "unclassified") firstFrame=\(firstFrameTime) playing=\(playingTime) "
            + "size=\(dimensions.width)x\(dimensions.height) range=\(String(describing: engine.streamingOutputDynamicRange)) "
            + "progress=\(progress) wallSeconds=\(measurementSeconds) stalls=\(access?.numberOfStalls ?? -1) "
            + "droppedFrames=\(access?.numberOfDroppedVideoFrames ?? -1) "
            + "observedBitrate=\(access?.observedBitrate ?? -1) indicatedBitrate=\(access?.indicatedBitrate ?? -1) "
            + "measuredCodec=\(String(describing: engine.streamingOutputVideoCodec)) "
            + "systemPiPSupported=\(AVPictureInPictureController.isPictureInPictureSupported())"
        XCTContext.runActivity(named: "Real server playback measurement") { activity in
            let attachment = XCTAttachment(string: evidence)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        XCTAssertGreaterThan(progress, Double(measurementSeconds - 2), "The real rendition must sustain playback beyond startup.")
        if let expectedCodec {
            XCTAssertEqual(engine.streamingOutputVideoCodec, expectedCodec, "Verify decoded output, not URL flags.")
        }
        if expectsSDR {
            XCTAssertEqual(engine.streamingOutputDynamicRange, .sdr, "Verify actual HDR-to-SDR output, not request flags.")
        }
        XCTAssertNil(item.error, "Playback must not silently fail after the first frame.")
        let layer = try XCTUnwrap(engine.pictureInPicturePlayerLayer())
        XCTAssertTrue(layer.player === player)
        XCTAssertTrue(layer.isReadyForDisplay)
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return
        }
        try await waitUntil(seconds: 10, stage: "PiP available") { pip.isAvailable }
        pip.toggle()
        try await waitUntil(seconds: 10, stage: "PiP active") { pip.isActive }
        XCTAssertTrue(engine.continuesPlaybackInBackground)
        pip.toggle()
        try await waitUntil(seconds: 10, stage: "PiP stopped") { !pip.continuesPlayback }
    }

    private func waitUntil(seconds: Int, stage: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard condition() else {
            XCTFail("Live playback did not reach \(stage) within \(seconds) seconds.")
            throw LivePlaybackTimeout()
        }
    }

    private struct LivePlaybackTimeout: Error {}
    private struct LivePlaybackConfigurationError: Error {
        let stage: String
        init(_ stage: String = "configuration") { self.stage = stage }
    }
}
#endif
