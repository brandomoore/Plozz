import CoreModels
import CryptoKit
import Foundation
import XCTest
@testable import FeatureLiveTVCore

@MainActor
final class LiveTVServerImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testServerRetryPreservesAnUnrelatedInFlightGuide() async throws {
        let first = source(id: "first", accountID: "one")
        let second = source(id: "second", accountID: "two")
        let started = expectation(description: "Other server guide requested")
        let firstProvider = ServerImportProvider(
            availability: .init(status: .available, supportsGuide: false), channels: [channel()]
        )
        let secondProvider = ServerImportProvider(
            channels: [channel()], programs: [program()], suspended: .guide, started: started
        )
        let contexts = [first.accountID: authorized(first, firstProvider), second.accountID: authorized(second, secondProvider)]
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [first, second]), serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let refresh = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 3)

        try await imports.reloadSource(first.id, into: model)
        XCTAssertEqual(imports.serverSources.last?.guidePhase, .loading)
        await secondProvider.resume()
        await refresh.value

        XCTAssertEqual(imports.serverSources.last?.guidePhase, .loaded)
        XCTAssertEqual(imports.serverSources.last?.programCount, 1)
        let calls = await secondProvider.calls
        XCTAssertEqual(calls.guides, 1)
    }

    func testServerRetryDoesNotRequestOtherServersOrPlaylists() async throws {
        let first = source(id: "first", accountID: "one")
        let second = source(id: "second", accountID: "two")
        let firstProvider = ServerImportProvider(
            availability: .init(status: .serviceUnavailable), channels: [channel()]
        )
        let secondProvider = ServerImportProvider(channels: [channel()])
        let contexts = [
            first.accountID: authorized(first, firstProvider),
            second.accountID: authorized(second, secondProvider)
        ]
        let playlist = LiveTVPlaylistSource(
            id: "playlist", name: "Playlist", playlistURL: URL(string: "https://example.test/list.m3u")!
        )
        let loader = ServerMixPlaylistLoader()
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(playlists: [playlist], servers: [first, second]), loader: loader,
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(imports.serverSources.first?.failure, .serviceUnavailable)
        let healthy = imports.serverSources.last
        let before = await secondProvider.calls
        let playlistLoads = await loader.playlistLoads
        await firstProvider.setAvailability(.init(status: .available, channelCount: 1, supportsGuide: false))

        try await imports.reloadSource(first.id, into: model)

        XCTAssertNil(imports.serverSources.first?.failure)
        XCTAssertEqual(imports.serverSources.first?.channelCount, 1)
        XCTAssertEqual(imports.serverSources.last, healthy)
        let after = await secondProvider.calls
        XCTAssertEqual(after.availability, before.availability)
        XCTAssertEqual(after.catalogs, before.catalogs)
        XCTAssertEqual(after.guides, before.guides)
        let afterPlaylistLoads = await loader.playlistLoads
        XCTAssertEqual(afterPlaylistLoads, playlistLoads)
        XCTAssertEqual(model.channels.count, 3)
    }

    func testRuntimeChannelReferenceEqualityIncludesCatalogAuthorization() {
        let original = LiveTVServerChannelReference(
            sourceID: "server", accountID: "account", authorizationID: "profile-one", channelID: "native"
        )
        let changed = LiveTVServerChannelReference(
            sourceID: "server", accountID: "account", authorizationID: "profile-two", channelID: "native"
        )
        XCTAssertNotEqual(original, changed)
        XCTAssertEqual(original.authorizationID, "profile-one")
    }

    func testEmptyOrDisabledSetupNeverResolvesProvidersOrFetchesAnySource() async {
        for servers in [[], [source(isEnabled: false)]] {
            let authorization = ServerAuthorizationFixture()
            let loader = ServerMixPlaylistLoader()
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: servers), loader: loader,
                serverProviderResolver: { authorization.resolve($0) }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertTrue(authorization.resolvedAccountIDs.isEmpty)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertEqual(imports.catalogPhase, .idle)
            XCTAssertFalse(imports.isLoading)
            let calls = await loader.playlistLoads
            XCTAssertEqual(calls, 0)
        }
    }

    func testMixedCatalogUsesNativeServerChannelIDsAndNeverXMLTVNameMatching() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "iptv", name: "Playlist", playlistURL: URL(string: "https://example.test/list.m3u")!,
            guideURLs: [URL(string: "https://example.test/guide.xml")!]
        )
        let server = source()
        let native = [
            ServerLiveTVChannel(id: "one", name: "Identical name"),
            ServerLiveTVChannel(id: "two", name: "Identical name")
        ]
        let provider = ServerImportProvider(
            channels: native, programs: [program(id: "airing", channelID: "two", title: "Native second channel")]
        )
        let loader = ServerMixPlaylistLoader()
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist], servers: [server]), loader: loader,
            serverProviderResolver: { $0 == server.accountID ? context : nil }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 3)
        XCTAssertEqual(imports.catalogPhase, .loaded)
        let first = try XCTUnwrap(imports.serverChannelReferences.first { $0.value.channelID == "one" }?.key)
        let second = try XCTUnwrap(imports.serverChannelReferences.first { $0.value.channelID == "two" }?.key)
        XCTAssertNil(model.currentProgram(for: first))
        XCTAssertEqual(model.currentProgram(for: second)?.title, "Native second channel")
        XCTAssertNil(imports.selectedSourceByChannel[second])
        XCTAssertEqual(imports.configuredSourceIDByChannel[second], server.id)
        XCTAssertEqual(imports.serverChannelReferences[second]?.authorizationID, context.authorizationID)
        XCTAssertEqual(model.channel(id: second)?.configuredSourceID, server.id)
        XCTAssertNil(model.channel(id: second)?.streamURL)
        model.configuredSourceID = server.id
        XCTAssertEqual(model.visibleChannels.count, 2)
        model.source = .iptv
        XCTAssertTrue(model.visibleChannels.isEmpty)
        let submitted = await loader.submittedGuideSources
        XCTAssertEqual(submitted, [.iptv])
        let calls = await provider.calls
        XCTAssertEqual(calls.guideChannelIDs, ["one", "two"])
        XCTAssertEqual(calls.opens, 0)
        XCTAssertTrue(model.recentChannelIDs.isEmpty)
    }

    func testSameProviderIDsAreNamespacedBySourceAndAccountAndNamesNeverChangeIdentity() async throws {
        let first = source(id: "first", accountID: "one")
        let second = source(id: "second", accountID: "two")
        let firstProvider = ServerImportProvider(channels: [channel()], programs: [program()])
        let secondProvider = ServerImportProvider(channels: [channel()], programs: [program()])
        let contexts = [
            first.accountID: authorized(first, firstProvider),
            second.accountID: authorized(second, secondProvider, kind: .plex)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)).count, 2)
        let programs = try model.channels.map { try XCTUnwrap(model.currentProgram(for: $0.id)) }
        XCTAssertEqual(Set(programs.map(\.id)).count, 2)
        let ids = Set(model.channels.map(\.id))
        let favorite = try XCTUnwrap(model.channels.first?.id)
        model.toggleFavorite(favorite)
        var renamed = first
        renamed.name = "Renamed server"
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [second, renamed]), into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), ids)
        XCTAssertTrue(model.favoriteIDs.contains(favorite))
        XCTAssertEqual(imports.serverSources.last?.source.name, renamed.name)
        let calls = await firstProvider.calls
        XCTAssertEqual(calls.catalogs, 1)
    }

    func testNoTunerNoChannelsAndTransportFailureAreDistinctWithoutSyntheticChannels() async {
        for status in [
            ServerLiveTVAvailability.Status.notConfigured, .noChannels, .serviceUnavailable, .permissionDenied
        ] {
            let server = source()
            let provider = ServerImportProvider(
                availability: ServerLiveTVAvailability(status: status), channels: [channel()]
            )
            let context = authorized(server, provider)
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [server]),
                serverProviderResolver: { _ in context }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertEqual(imports.serverSources[0].availability?.status, status)
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertEqual(imports.serverSources[0].failure, status == .serviceUnavailable ? .serviceUnavailable
                : (status == .permissionDenied ? .permissionDenied : nil))
            XCTAssertFalse(imports.isLoading)
            let calls = await provider.calls
            XCTAssertEqual(calls.catalogs, 0)
            XCTAssertEqual(calls.opens, 0)
        }
    }

    func testNoGuideRetainsAuthoritativeCurrentProgrammeWithoutCallingGuideEndpoint() async throws {
        let server = source()
        let current = program()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .available, channelCount: 1, supportsGuide: false),
            channels: [ServerLiveTVChannel(id: "native", name: "Native", currentProgramme: current)]
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let imported = try XCTUnwrap(model.channels.first)
        XCTAssertEqual(model.currentProgram(for: imported.id)?.title, current.title)
        XCTAssertEqual(imports.serverSources[0].guidePhase, .idle)
        XCTAssertEqual(imports.gapState(for: imported), .disabled)
        let calls = await provider.calls
        XCTAssertEqual(calls.guides, 0)
    }

    func testEmptyNativeCatalogReportsNoChannelsRatherThanATunerOrTransportFailure() async {
        let server = source()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .available, channelCount: 1), channels: []
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .noChannels)
        XCTAssertNil(imports.serverSources[0].failure)
        XCTAssertFalse(imports.serverSources[0].supportsPlayback)
    }

    func testDisablingAndReenablingServerPreservesOtherSourcesAndStableReferences() async throws {
        let first = source(id: "one", accountID: "one")
        let second = source(id: "two", accountID: "two")
        let providerOne = ServerImportProvider(channels: [channel()])
        let providerTwo = ServerImportProvider(channels: [channel()])
        let contexts = [
            first.accountID: authorized(first, providerOne), second.accountID: authorized(second, providerTwo)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let original = Set(model.channels.map(\.id))
        model.configuredSourceID = first.id
        try imports.setServerEnabled(first.id, enabled: false, into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertNil(model.configuredSourceID)
        XCTAssertEqual(Set(imports.serverChannelReferences.values.map(\.sourceID)), [second.id])
        try imports.setServerEnabled(first.id, enabled: true, into: model)
        await imports.reloadServers(into: model)
        XCTAssertEqual(Set(model.channels.map(\.id)), original)
    }

    func testUnsupportedPlaybackStillExposesNativeMetadataWithoutOpeningATuner() async {
        let server = source()
        let provider = ServerImportProvider(
            availability: ServerLiveTVAvailability(status: .unsupportedPlaybackMode, channelCount: 1),
            channels: [channel()], programs: [program()]
        )
        let context = authorized(server, provider, kind: .plex)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .unsupportedPlaybackMode)
        XCTAssertEqual(imports.serverSources[0].availability?.supportsPlayback, false)
        let calls = await provider.calls
        XCTAssertEqual(calls.opens, 0)
    }

    func testGuideFailurePreservesLastGoodNativeScheduleAndRejectsUnknownChannelAssociations() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program(title: "Last good")])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let id = try XCTUnwrap(model.channels.first?.id)
        await provider.replaceGuide([program(channelID: "not-in-catalog", title: "Wrong channel")])
        await imports.reloadServers(into: model)
        XCTAssertEqual(model.currentProgram(for: id)?.title, "Last good")
        XCTAssertEqual(imports.serverSources[0].guideFailure, .invalidGuide)
        XCTAssertEqual(imports.serverSources[0].phase, .loaded)
        XCTAssertEqual(imports.serverSources[0].guidePhase, .failed)
        XCTAssertNotNil(imports.serverSources[0].lastGuideRefresh)
    }

    func testTransientServerOutageKeepsLastGoodButExplicitNoChannelsClearsOnlyThatSource() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program()])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        let original = model.channels
        await provider.setAvailability(ServerLiveTVAvailability(status: .serviceUnavailable))
        await imports.reloadServers(into: model)
        XCTAssertEqual(model.channels, original)
        XCTAssertEqual(imports.serverSources[0].failure, .serviceUnavailable)
        await provider.setAvailability(ServerLiveTVAvailability(status: .noChannels))
        await imports.reloadServers(into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(imports.serverSources[0].failure)
        XCTAssertEqual(imports.serverSources[0].availability?.status, .noChannels)
    }

    func testRemovingAnotherSourceDoesNotDiscardAnUnrelatedServerRequestInFlight() async throws {
        let first = source(id: "one", accountID: "one")
        let second = source(id: "two", accountID: "two")
        let started = expectation(description: "Second catalog suspended")
        let providerOne = ServerImportProvider(channels: [channel()])
        let providerTwo = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let contexts = [
            first.accountID: authorized(first, providerOne),
            second.accountID: authorized(second, providerTwo)
        ]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [first, second]),
            serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [second]), into: model)
        await providerTwo.resume()
        await task.value
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(Set(imports.configuredSourceIDByChannel.values), [second.id])
        XCTAssertEqual(imports.serverSources[0].phase, .loaded)
    }

    func testRemovingTheLoadingServerFencesLateCatalogWithoutRemovingPlaylistChannels() async throws {
        let playlist = LiveTVPlaylistSource(
            id: "iptv", name: "Playlist", playlistURL: URL(string: "https://example.test/list.m3u")!
        )
        let server = source()
        let started = expectation(description: "Catalog suspended")
        let provider = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(playlists: [playlist], servers: [server]),
            loader: ServerMixPlaylistLoader(), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(playlists: [playlist]), into: model)
        await provider.resume()
        await task.value
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(model.channels[0].source, .iptv)
        XCTAssertTrue(imports.serverChannelReferences.isEmpty)
        XCTAssertFalse(imports.isLoading)
    }

    func testChangingAccountNamespacesChannelsAndFencesOldGuideResults() async throws {
        let server = source(accountID: "old-account")
        var replacement = server
        replacement.accountID = "new-account"
        let started = expectation(description: "Old guide suspended")
        let old = ServerImportProvider(
            channels: [channel()], programs: [program(title: "Old account")], suspended: .guide, started: started
        )
        let fresh = ServerImportProvider(channels: [channel()], programs: [program(title: "New account")])
        let contexts = [server.accountID: authorized(server, old), replacement.accountID: authorized(replacement, fresh)]
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { contexts[$0] }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        let oldID = try XCTUnwrap(model.channels.first?.id)
        try imports.applyConfiguration(LiveTVSourcesConfiguration(servers: [replacement]), into: model)
        await imports.reloadServers(into: model)
        await old.resume()
        await task.value
        let freshID = try XCTUnwrap(model.channels.first?.id)
        XCTAssertNotEqual(oldID, freshID)
        XCTAssertEqual(model.currentProgram(for: freshID)?.title, "New account")
        XCTAssertEqual(imports.serverChannelReferences[freshID]?.accountID, replacement.accountID)
    }

    func testProfileAuthorizationRevocationClearsCachedCatalogSynchronouslyAndHasNoHouseholdFallback() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()], programs: [program()])
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model)
        model.tune(try XCTUnwrap(model.channels.first?.id))
        try imports.setServerProviderResolver({ _ in nil }, into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.playingChannelID)
        XCTAssertTrue(imports.serverChannelReferences.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        await imports.reloadServers(into: model)
        let calls = await provider.calls
        XCTAssertEqual(calls.catalogs, 1)
    }

    func testUpstreamRefusalsAreNotReportedAsMissingProfileMembership() {
        for error: AppError in [.unauthorized, .invalidCredentials, .accessRestricted] {
            XCTAssertEqual(LiveTVServerImportError.sanitized(error, fallback: .invalidCatalog), .permissionDenied)
        }
        XCTAssertEqual(
            LiveTVServerImportError.sanitized(LiveTVServerImportError.accountUnavailable, fallback: .invalidCatalog),
            .accountUnavailable
        )
    }

    func testServerChannelIdentifiersKeepTheirPublishedForm() throws {
        let server = source(id: "srv", accountID: "acct")
        let catalog = try LiveTVServerCatalog(
            source: server, context: authorized(server, ServerImportProvider(channels: [])),
            channels: [channel(), ServerLiveTVChannel(id: "ünï:2", name: "Second")]
        )
        // Favourites, hidden channels and guide state are keyed by these identifiers.
        let expected = ["native", "ünï:2"].map { nativeID in
            "server-channel-" + SHA256.hash(data: Data("srv\u{1F}acct\u{1F}\(nativeID)".utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        XCTAssertEqual(catalog.channels.map(\.id), expected)
        XCTAssertEqual(expected.compactMap { catalog.references[$0]?.channelID }, ["native", "ünï:2"])
    }

    func testUnchangedLineupUnderNewAuthorizationRepublishesChannelReferences() async throws {
        let server = source()
        let provider = ServerImportProvider(channels: [channel()])
        let fixture = ServerAuthorizationFixture()
        fixture.contexts[server.accountID] = authorized(server, provider, authorizationID: "first")
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: fixture.resolve
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reloadServers(into: model, forceRefresh: false)
        let id = try XCTUnwrap(model.channels.first?.id)
        XCTAssertEqual(imports.serverChannelReferences[id]?.authorizationID, "first")

        fixture.contexts[server.accountID] = authorized(server, provider, authorizationID: "second")
        await imports.reloadServers(into: model, forceRefresh: false)

        XCTAssertEqual(model.channels.map(\.id), [id])
        XCTAssertEqual(imports.serverChannelReferences[id]?.authorizationID, "second")
    }

    func testLastSeenRowsShowBeforeTheLineupIsReadAndAreReplacedByIt() async throws {
        let server = source()
        let lineup = (1...400).map { ServerLiveTVChannel(id: "n\($0)", name: "Channel \($0)", number: "\($0)", groups: ["Group \($0 % 4)"]) }
        let store = LastSeenMemoryStore()
        let first = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { [self] _ in authorized(server, ServerImportProvider(channels: lineup)) },
            lastSeen: store
        )
        let firstModel = LiveTVPrototypeModel(now: now, channels: [])
        await first.reload(into: firstModel, forceServerRefresh: false)
        await first.saveLastSeen(from: firstModel)?.value
        let saved = try XCTUnwrap(store.load())
        XCTAssertEqual(saved.sources.first?.entries.count, LiveTVLastSeenSnapshot.maximumChannels)
        XCTAssertEqual(saved.browse.totalCount, 400)

        // A new session: the lineup read is held, so only the saved rows can be on screen.
        let started = expectation(description: "Lineup read suspended")
        let provider = ServerImportProvider(channels: lineup, suspended: .channels, started: started)
        let context = authorized(server, provider, authorizationID: "next-session")
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context }, lastSeen: store
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model, forceServerRefresh: false) }
        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(model.channels.map(\.id), Array(firstModel.channels.prefix(150)).map(\.id))
        XCTAssertEqual(model.guideChannels.map(\.id), Array(firstModel.guideChannels.prefix(150)).map(\.id))
        XCTAssertEqual(model.categoryChannelCount(nil), 400)
        XCTAssertEqual(model.browsingCategories, firstModel.browsingCategories)
        // A saved row is playable: it is referenced under this session's authorization.
        let reference = try XCTUnwrap(imports.serverChannelReferences[model.channels[0].id])
        XCTAssertEqual(reference.authorizationID, "next-session")
        XCTAssertEqual(reference.channelID, "n1")
        // Rows alone are never remembered as the lineup.
        XCTAssertNil(imports.saveLastSeen(from: model))

        await provider.resume()
        await task.value
        XCTAssertEqual(model.channels, firstModel.channels)
        XCTAssertEqual(model.guideChannels, firstModel.guideChannels)
        XCTAssertNil(model.provisionalBrowse)
        XCTAssertEqual(model.browsingCategories, firstModel.browsingCategories)
    }

    func testAuthorizationLossDuringHiddenPreloadClearsProvisionalBrowseAndRejectsLateLineup() async throws {
        let server = source()
        let lineup = [ServerLiveTVChannel(id: "n1", name: "Old profile", groups: ["Old category"])]
        let store = LastSeenMemoryStore()
        let first = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { [self] _ in authorized(server, ServerImportProvider(channels: lineup)) },
            lastSeen: store
        )
        let firstModel = LiveTVPrototypeModel(now: now, channels: [])
        await first.reload(into: firstModel, forceServerRefresh: false)
        await first.saveLastSeen(from: firstModel)?.value

        let started = expectation(description: "Hidden preload suspended")
        let provider = ServerImportProvider(channels: lineup, suspended: .channels, started: started)
        var profileIsCurrent = true
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context },
            lastSeen: store, catalogIsAuthorized: { profileIsCurrent }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let preload = Task { await imports.reload(into: model, forceServerRefresh: false) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNotNil(model.provisionalBrowse)
        XCTAssertEqual(model.categoryChannelCount("Old category"), 1)

        profileIsCurrent = false
        XCTAssertFalse(imports.ensureCatalogAuthorization(into: model))
        XCTAssertNil(model.provisionalBrowse)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertFalse(model.browsingCategories.contains { $0.name == "Old category" })
        XCTAssertEqual(model.categoryChannelCount(nil), 0)
        await provider.resume()
        await preload.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.provisionalBrowse)
        XCTAssertEqual(model.categoryChannelCount(nil), 0)
    }

    func testLastSeenRowsFromAnotherAccountOrChangedIdentifiersAreNotShown() async throws {
        let server = source()
        let lineup = [channel()]
        let store = LastSeenMemoryStore()
        let first = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { [self] _ in authorized(server, ServerImportProvider(channels: lineup)) },
            lastSeen: store
        )
        let firstModel = LiveTVPrototypeModel(now: now, channels: [])
        await first.reload(into: firstModel, forceServerRefresh: false)
        await first.saveLastSeen(from: firstModel)?.value
        let saved = try XCTUnwrap(store.load())

        func seeded(_ snapshot: LiveTVLastSeenSnapshot, _ source: LiveTVServerSource,
                    kind: LiveTVPrototypeSource = .jellyfin) async -> Int {
            let started = expectation(description: "Lineup read suspended")
            let provider = ServerImportProvider(channels: lineup, suspended: .channels, started: started)
            let context = authorized(source, provider, kind: kind)
            let imports = LiveTVPrototypeImportModel(
                configuration: .init(servers: [source]), serverProviderResolver: { _ in context },
                lastSeen: LastSeenMemoryStore(snapshot)
            )
            let model = LiveTVPrototypeModel(now: now, channels: [])
            let task = Task { await imports.reload(into: model, forceServerRefresh: false) }
            await fulfillment(of: [started], timeout: 2)
            let count = model.channels.count
            await provider.resume()
            await task.value
            return count
        }
        let seededForSameAccount = await seeded(saved, server)
        XCTAssertEqual(seededForSameAccount, 1)
        let seededForOtherAccount = await seeded(saved, source(accountID: "other"))
        XCTAssertEqual(seededForOtherAccount, 0)
        let seededForOtherKind = await seeded(saved, server, kind: .plex)
        XCTAssertEqual(seededForOtherKind, 0)
        let entry = saved.sources[0].entries[0]
        let renamed = LiveTVLastSeenSnapshot(sources: [.init(
            sourceID: server.id, accountID: server.accountID, kind: .jellyfin,
            entries: [.init(nativeID: "another", channel: entry.channel)]
        )], browse: saved.browse)
        let seededWithChangedIdentifier = await seeded(renamed, server)
        XCTAssertEqual(seededWithChangedIdentifier, 0)
    }

    func testLastSeenRowsAreDroppedWhenTheLineupCannotBeRead() async throws {
        let server = source()
        let store = LastSeenMemoryStore()
        let first = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]),
            serverProviderResolver: { [self] _ in authorized(server, ServerImportProvider(channels: [channel()])) },
            lastSeen: store
        )
        let firstModel = LiveTVPrototypeModel(now: now, channels: [])
        await first.reload(into: firstModel, forceServerRefresh: false)
        await first.saveLastSeen(from: firstModel)?.value
        XCTAssertNotNil(store.load())

        let provider = ServerImportProvider(
            availability: .init(status: .serviceUnavailable, channelCount: 0), channels: []
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context }, lastSeen: store
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.reload(into: model, forceServerRefresh: false)

        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertNil(model.provisionalBrowse)
        XCTAssertTrue(imports.serverChannelReferences.isEmpty)
    }

    func testGuideBatchesAfterAnUnchangedReimportKeepLineupAndPublishListings() async throws {
        let server = source()
        let provider = ServerImportProvider(
            availability: .init(status: .available, channelCount: 1, supportsGuide: true),
            channels: [channel()], programs: [program()]
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        await imports.restoreCachedServerCatalogs(into: model)
        let restored = model.channels

        await imports.reloadServers(into: model, forceRefresh: false)

        XCTAssertEqual(model.channels, restored)
        XCTAssertEqual(imports.programCount, 1)
        await provider.replaceGuide([program(id: "later", title: "Later programme")])
        await imports.reloadServerGuides(
            channelIDs: model.channels.map(\.id), from: now, to: now.addingTimeInterval(3_600), into: model,
            force: true
        )
        XCTAssertEqual(model.channels, restored)
        XCTAssertEqual(model.currentProgram(for: restored[0].id)?.title, "Later programme")
    }

    func testCacheRestoreDoesNotInvalidateAnAlreadyLoadingGuide() async throws {
        let server = source()
        let started = expectation(description: "Guide pending")
        let provider = ServerImportProvider(
            channels: [channel()], programs: [program()], suspended: .guide, started: started
        )
        let context = authorized(server, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: .init(servers: [server]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let reload = Task { await imports.reloadServers(into: model) }
        await fulfillment(of: [started], timeout: 2)
        await imports.restoreCachedServerCatalogs(into: model)
        await provider.resume()
        await reload.value
        XCTAssertEqual(imports.programCount, 1)
        XCTAssertEqual(imports.serverSources.first?.guidePhase, .loaded)
    }

    func testLateCachedChannelsCannotRestoreAfterProfileChangeRemovalOrCancellation() async throws {
        for boundary in ["profile", "removal", "cancellation"] {
            let server = source()
            let started = expectation(description: "Saved catalogue pending")
            let provider = ServerImportProvider(channels: [channel()], suspended: .cache, started: started)
            let authorization = ServerAuthorizationFixture()
            authorization.contexts[server.accountID] = authorized(server, provider, authorizationID: "profile-one")
            let imports = LiveTVPrototypeImportModel(
                configuration: .init(servers: [server]),
                serverProviderResolver: { authorization.resolve($0) }
            )
            let model = LiveTVPrototypeModel(now: now, channels: [])
            let restore = Task { await imports.restoreCachedServerCatalogs(into: model) }
            await fulfillment(of: [started], timeout: 2)
            switch boundary {
            case "profile":
                authorization.contexts[server.accountID] = authorized(
                    server, provider, authorizationID: "profile-two"
                )
            case "removal":
                try imports.applyConfiguration(.empty, into: model)
            default:
                restore.cancel()
            }
            await provider.resume()
            await restore.value
            XCTAssertTrue(model.channels.isEmpty)
            XCTAssertTrue(imports.serverChannelReferences.isEmpty)
            let calls = await provider.calls
            XCTAssertEqual(calls.availability + calls.catalogs + calls.guides + calls.opens, 0)
        }
    }

    func testProfileIdentityChangeDuringAwaitRejectsOldResultsEvenWithoutReplacingResolver() async throws {
        let server = source()
        let started = expectation(description: "Old profile catalog suspended")
        let provider = ServerImportProvider(channels: [channel()], suspended: .channels, started: started)
        let authorization = ServerAuthorizationFixture()
        authorization.contexts[server.accountID] = authorized(server, provider, authorizationID: "profile-one")
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [server]),
            serverProviderResolver: { authorization.resolve($0) }
        )
        let model = LiveTVPrototypeModel(now: now, channels: [])
        let task = Task { await imports.reload(into: model) }
        await fulfillment(of: [started], timeout: 2)
        authorization.contexts[server.accountID] = authorized(server, provider, authorizationID: "profile-two")
        await provider.resume()
        await task.value
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        XCTAssertFalse(imports.isLoading)
    }

    func testResolverCannotReturnAnotherAccountsProvider() async {
        let configured = source(accountID: "configured")
        let unauthorized = source(accountID: "household")
        let provider = ServerImportProvider(channels: [channel()])
        let context = authorized(unauthorized, provider)
        let imports = LiveTVPrototypeImportModel(
            configuration: LiveTVSourcesConfiguration(servers: [configured]), serverProviderResolver: { _ in context }
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model)
        XCTAssertTrue(model.channels.isEmpty)
        XCTAssertEqual(imports.serverSources[0].failure, .accountUnavailable)
        let calls = await provider.calls
        XCTAssertEqual(calls.availability, 0)
    }

    func testProviderCancellationAtEveryServerBoundaryIsRequestScopedForDiagnostics() async throws {
        for boundary in [ServerImportProvider.Boundary.availability, .channels, .guide] {
            let server = source()
            let provider = ServerImportProvider(channels: [channel()], programs: [program()])
            await provider.cancelNext(boundary)
            let context = authorized(server, provider)
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
            )
            let model = LiveTVPrototypeModel(now: now, channels: [])
            PerformanceDiagnostics.shared.start()
            defer { PerformanceDiagnostics.shared.stop() }

            await imports.reload(into: model)
            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(model.channels.count, boundary == .guide ? 1 : 0)
            XCTAssertEqual(imports.programCount, 0)
            XCTAssertNil(imports.serverSources[0].failure)
            XCTAssertNil(imports.serverSources[0].guideFailure)
            XCTAssertFalse(imports.isLoading)
            let cancelled = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
            let firstRecords = (cancelled.recent + cancelled.slow).filter { $0.operation == .liveTVRefresh }
            XCTAssertEqual(firstRecords.count, 1)
            XCTAssertEqual(firstRecords.first?.outcome, .cancelled)
            XCTAssertTrue(cancelled.active.isEmpty)

            await imports.reload(into: model)
            XCTAssertFalse(Task.isCancelled)
            XCTAssertEqual(model.channels.count, 1)
            XCTAssertEqual(imports.programCount, 1)
            let recovered = try XCTUnwrap(PerformanceDiagnostics.shared.snapshot())
            let records = (recovered.recent + recovered.slow).filter { $0.operation == .liveTVRefresh }
            XCTAssertEqual(records.count, 2)
            XCTAssertEqual(records.filter { $0.outcome == .cancelled }.count, 1)
            XCTAssertEqual(records.filter { $0.outcome == .succeeded }.count, 1)
            XCTAssertTrue(recovered.active.isEmpty)
        }
    }

    func testCancellationAtEveryServerBoundaryCannotPublishLateDataOrFakeAFailure() async {
        for boundary in [ServerImportProvider.Boundary.availability, .channels, .guide] {
            let server = source()
            let started = expectation(description: "Server request suspended")
            let provider = ServerImportProvider(
                channels: [channel()], programs: [program()], suspended: boundary, started: started
            )
            let context = authorized(server, provider)
            let imports = LiveTVPrototypeImportModel(
                configuration: LiveTVSourcesConfiguration(servers: [server]), serverProviderResolver: { _ in context }
            )
            let model = LiveTVPrototypeModel(now: now, channels: [])
            let task = Task { await imports.reload(into: model) }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            await provider.resume()
            await task.value
            XCTAssertEqual(model.channels.count, boundary == .guide ? 1 : 0)
            XCTAssertEqual(imports.programCount, 0)
            XCTAssertNil(imports.serverSources[0].failure)
            XCTAssertNil(imports.serverSources[0].guideFailure)
            XCTAssertFalse(imports.isLoading)
        }
    }

    private func source(
        id: String = "server", accountID: String = "account", isEnabled: Bool = true
    ) -> LiveTVServerSource {
        LiveTVServerSource(id: id, name: id, accountID: accountID, isEnabled: isEnabled)
    }

    private func channel() -> ServerLiveTVChannel {
        ServerLiveTVChannel(id: "native", name: "Native channel", number: "7")
    }

    private func program(
        id: String = "airing", channelID: String = "native", title: String = "Native programme"
    ) -> ServerLiveTVProgramme {
        ServerLiveTVProgramme(
            id: id, channelID: channelID, title: title,
            startDate: now.addingTimeInterval(-60), endDate: now.addingTimeInterval(3_600)
        )
    }

    private func authorized(
        _ source: LiveTVServerSource, _ provider: ServerImportProvider,
        kind: LiveTVPrototypeSource = .jellyfin, authorizationID: String = "active-profile"
    ) -> LiveTVAuthorizedServerProvider {
        LiveTVAuthorizedServerProvider(
            accountID: source.accountID, authorizationID: authorizationID, kind: kind, provider: provider
        )
    }
}

private final class LastSeenMemoryStore: LiveTVLastSeenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: LiveTVLastSeenSnapshot?
    init(_ snapshot: LiveTVLastSeenSnapshot? = nil) { self.snapshot = snapshot }
    func load() -> LiveTVLastSeenSnapshot? { lock.withLock { snapshot } }
    func save(_ snapshot: LiveTVLastSeenSnapshot?) { lock.withLock { self.snapshot = snapshot } }
}

@MainActor
private final class ServerAuthorizationFixture {
    var contexts: [String: LiveTVAuthorizedServerProvider] = [:]
    var resolvedAccountIDs: [String] = []
    func resolve(_ accountID: String) -> LiveTVAuthorizedServerProvider? {
        resolvedAccountIDs.append(accountID)
        return contexts[accountID]
    }
}

private actor ServerMixPlaylistLoader: LiveTVSourceLoading {
    private(set) var playlistLoads = 0
    private(set) var submittedGuideSources: [LiveTVPrototypeSource] = []

    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        playlistLoads += 1
        return try LiveTVPlaylistParser().parse("""
            #EXTM3U
            #EXTINF:-1 tvg-id="two",Identical name
            https://example.test/live.m3u8
            """)
    }

    func loadGuide(from url: URL, channels: [LiveTVPrototypeChannel], now: Date) async throws -> LiveTVGuideImport {
        submittedGuideSources += channels.map(\.source)
        return LiveTVGuideImport(
            programs: [], matchedChannelCount: 0, guideChannelCount: 0, programCount: 0,
            coverageStart: nil, coverageEnd: nil
        )
    }
}

private actor ServerImportProvider: ServerLiveTVProviding {
    enum Boundary: Equatable { case availability, channels, guide, cache }
    var availability: ServerLiveTVAvailability
    let channels: [ServerLiveTVChannel]
    var programs: [ServerLiveTVProgramme]
    var suspended: Boundary?
    private var cancellation: Boundary?
    let started: XCTestExpectation?
    var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls = (
        availability: 0, catalogs: 0, guides: 0, opens: 0, guideChannelIDs: [String]()
    )

    init(
        availability: ServerLiveTVAvailability? = nil, channels: [ServerLiveTVChannel],
        programs: [ServerLiveTVProgramme] = [], suspended: Boundary? = nil, started: XCTestExpectation? = nil
    ) {
        self.availability = availability ?? ServerLiveTVAvailability(status: .available, channelCount: channels.count)
        self.channels = channels
        self.programs = programs
        self.suspended = suspended
        self.started = started
    }

    func setAvailability(_ value: ServerLiveTVAvailability) { availability = value }
    func replaceGuide(_ value: [ServerLiveTVProgramme]) { programs = value }
    func cancelNext(_ boundary: Boundary) { cancellation = boundary }

    private func throwRequestedCancellation(_ boundary: Boundary) throws {
        guard cancellation == boundary else { return }
        cancellation = nil
        throw CancellationError()
    }

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        calls.availability += 1
        await waitIfSuspended(.availability)
        try throwRequestedCancellation(.availability)
        return availability
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] {
        calls.catalogs += 1
        await waitIfSuspended(.channels)
        try throwRequestedCancellation(.channels)
        return channels
    }

    func cachedLiveTVCatalog() async throws -> ServerLiveTVCatalogSnapshot? {
        await waitIfSuspended(.cache)
        return .init(channels: channels, supportsGuide: availability.supportsGuide)
    }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] {
        calls.guides += 1
        calls.guideChannelIDs = channelIDs
        await waitIfSuspended(.guide)
        try throwRequestedCancellation(.guide)
        return programs
    }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        calls.opens += 1
        throw ServerLiveTVError.unsupportedPlaybackMode
    }

    private func waitIfSuspended(_ boundary: Boundary) async {
        guard suspended == boundary else { return }
        suspended = nil
        await withCheckedContinuation {
            continuation = $0
            started?.fulfill()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
