import CoreModels
import FeatureLiveTVCore
import Foundation
import ProviderIPTV
import XCTest

@MainActor
final class IPTVLiveTVImportTests: XCTestCase {
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
