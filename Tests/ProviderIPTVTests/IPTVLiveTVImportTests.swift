import CoreModels
import FeatureLiveTVCore
import Foundation
@testable import ProviderIPTV
import XCTest

@MainActor
final class IPTVLiveTVImportTests: XCTestCase {
    func testExpiredPlaylistPublishesSavedChannelsWithoutWaitingForRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            IPTVFixture.state.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let body = Data("#EXTM3U\n#EXTINF:-1,News\nhttps://provider.test/live/1.ts\n".utf8)
        IPTVFixture.state.handler = { _ in (200, [:], body) }
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list"))
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Fixture", deviceID: "fixture",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        do {
            let saved = try IPTVCatalog(
                url: root.appendingPathComponent(credential.identity.uuidString + ".sqlite"), key: credential.catalogKey
            )
            try saved.setState("playlist-v4", String(Date().addingTimeInterval(-3_600).timeIntervalSince1970))
        }
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "account", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "account", profileID: "fixture", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let started = expectation(description: "Automatic playlist refresh started")
        let published = expectation(description: "Saved guide exits loading while the provider is delayed")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        IPTVFixture.state.handler = { _ in
            started.fulfill()
            guard gate.wait(timeout: .now() + 10) == .success else { throw URLError(.timedOut) }
            return (200, [:], body)
        }
        var configuration = LiveTVSourcesConfiguration()
        configuration.servers = [.init(id: "server", name: "Fixture", accountID: "account")]
        let imports = LiveTVPrototypeImportModel(
            configuration: configuration,
            serverProviderResolver: { _ in
                .init(accountID: "account", authorizationID: "fixture", kind: .iptv, provider: provider)
            }
        )
        let model = LiveTVPrototypeModel(channels: [])
        let load = Task { @MainActor in
            await imports.reload(into: model, forceServerRefresh: false)
            XCTAssertEqual(model.channels.map(\.name), ["News"])
            XCTAssertEqual(imports.catalogPhase, .loaded)
            XCTAssertFalse(imports.isLoading)
            XCTAssertEqual(imports.serverSources.first?.availability?.supportsGuide, false)
            published.fulfill()
        }
        await fulfillment(of: [started, published], timeout: 1)
        await provider.teardown()
        gate.signal()
        await load.value
        XCTAssertEqual(IPTVFixture.state.requests.count, 2, "Opening Live TV must coalesce its stale reads")
    }

    func testAutomaticGuideEnrollmentReusesImportButExplicitRefreshFetchesAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            IPTVFixture.state.reset()
            try? FileManager.default.removeItem(at: root)
        }
        IPTVFixture.state.handler = { _ in
            (200, [:], Data("#EXTM3U\n#EXTINF:-1,News\nhttps://provider.test/live/1.ts\n".utf8))
        }
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list"))
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Fixture", deviceID: "fixture",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "account", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "account", profileID: "fixture", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let source = LiveTVServerSource(id: "server", name: "Fixture", accountID: "account")
        var configuration = LiveTVSourcesConfiguration()
        configuration.servers = [source]
        let imports = LiveTVPrototypeImportModel(
            configuration: configuration,
            serverProviderResolver: { _ in
                .init(accountID: "account", authorizationID: "fixture", kind: .iptv, provider: provider)
            }
        )
        let model = LiveTVPrototypeModel(channels: [])
        await imports.reload(into: model, forceServerRefresh: false)
        XCTAssertEqual(model.channels.count, 1)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1, "Automatic guide loading must not reimport the account.")
        XCTAssertEqual(imports.serverSources.first?.availability?.supportsGuide, false)
        XCTAssertEqual(imports.serverSources.first?.guidePhase, .idle)
        XCTAssertTrue(imports.serverGuideWindows.isEmpty)
        XCTAssertFalse(imports.isLoading)
        let channel = try XCTUnwrap(model.channels.first)
        let end = model.now.addingTimeInterval(21_600)
        XCTAssertEqual(imports.gapState(for: channel), .disabled)
        XCTAssertEqual(imports.gapState(for: channel, from: model.now, to: end), .disabled)
        XCTAssertEqual(imports.gapState(for: channel).title, "No program guide available")
        for force in [false, true] {
            await imports.reloadServerGuides(
                channelIDs: [channel.id], from: model.now, to: end, into: model, force: force
            )
            XCTAssertTrue(imports.serverGuideWindows.isEmpty, "Browsing must not start a nonexistent guide request.")
            XCTAssertEqual(imports.gapState(for: channel), .disabled)
        }
        await imports.reloadServers(into: model, forceRefresh: false)
        XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        await imports.reload(into: model)
        XCTAssertEqual(IPTVFixture.state.requests.count, 2, "An explicit refresh must still bypass the cache.")
        await provider.teardown()
    }

    func testPlaylistAccountLoadsLargeLiveLineupWithoutAMovieLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("channels.m3u")
        var playlist = """
        #EXTM3U
        #EXTINF:-1 tvg-name="News24 City" group-title="Italy",News24 City
        https://dc3.telesveva.com:4433/news24.mp4
        #EXTINF:-1 tvg-name="Tv Uno" group-title="Italy",Tv Uno
        http://ftp.tiscali.it/francescovernata/TVUNO/monoscopioTvUNOint-1.wmv

        """
        for index in 0..<2_078 {
            playlist += "#EXTINF:-1,Channel \(index)\nhttps://provider.example/live/\(index).m3u8\n"
        }
        try Data(playlist.utf8).write(to: file)
        let credential = try IPTVCredential(
            mode: .file, address: XCTUnwrap(URL(string: "https://imported-playlist.invalid"))
        )
        let session = try await IPTVProvider.importFile(
            file, credential: credential, name: "Playlist", deviceID: "fixture", cacheDirectory: root
        )
        let provider = try IPTVProvider(
            context: .init(
                session: session, accountID: "iptv-account", credentialRevision: .init(),
                localMediaContext: .init(accountID: "iptv-account", profileID: "viewer", profileNamespace: nil)
            ),
            cacheDirectory: root
        )
        do {
            let libraries = try await provider.libraries()
            XCTAssertTrue(libraries.isEmpty, "A live playlist must not trigger movie-library setup")
            let context = LiveTVAuthorizedServerProvider(
                accountID: "iptv-account", authorizationID: "viewer-authorization", kind: .iptv, provider: provider
            )
            var configuration = LiveTVSourcesConfiguration()
            let enrollment = LiveTVServerEnrollmentCoordinator()
            let added = await enrollment.refresh(
                choices: [.init(id: context.accountID, name: "Playlist", userName: "IPTV", kind: .iptv)],
                resolver: { $0 == context.accountID ? context : nil },
                configuration: { configuration }, suppressedAccountIDs: { [] },
                apply: { configuration = $0 }
            )
            XCTAssertEqual(added.count, 1)
            let imports = LiveTVPrototypeImportModel(
                configuration: configuration,
                serverProviderResolver: { $0 == context.accountID ? context : nil }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertEqual(imports.catalogPhase, .loaded)
            XCTAssertNil(imports.serverSources.first?.failure)
            XCTAssertEqual(model.channels.count, 2_080)
            XCTAssertEqual(model.visibleChannels.count, 2_080)
            XCTAssertEqual(imports.serverChannelReferences.count, 2_080)
            XCTAssertTrue(model.channels.allSatisfy { $0.source == .iptv && $0.streamURL == nil })
            XCTAssertEqual(imports.serverSources.first?.availability?.supportsGuide, false)
            XCTAssertTrue(imports.serverGuideWindows.isEmpty)
            XCTAssertTrue(model.channels.allSatisfy { imports.gapState(for: $0) == .disabled })
            let channel = try XCTUnwrap(model.channels.first { $0.name == "Channel 0" })
            let reference = try XCTUnwrap(imports.serverChannelReferences[channel.id])
            let lease = try await provider.openLiveTVChannel(id: reference.channelID)
            if case .authenticatedHTTP(let locator) = lease.playbackSource {
                XCTAssertEqual(locator.accountID, context.accountID)
                XCTAssertEqual(locator.itemID, reference.channelID)
                XCTAssertEqual(locator.deliveryMode, .hls)
            } else {
                XCTFail("IPTV account channels must use their authenticated provider")
            }
            await lease.close()
            try imports.setServerProviderResolver({ _ in nil }, into: model)
            XCTAssertTrue(model.channels.isEmpty, "Revoking the active profile must still remove its channels")
            XCTAssertEqual(imports.serverSources.first?.failure, .accountUnavailable)
        } catch {
            await provider.teardown()
            throw error
        }
        await provider.teardown()
    }
}
