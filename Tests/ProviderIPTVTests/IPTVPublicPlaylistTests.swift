import CoreModels
import CoreNetworking
import CryptoKit
import FeatureLiveTVCore
import Foundation
import ProviderIPTV
import XCTest

@MainActor
final class IPTVPublicPlaylistTests: XCTestCase {
    func testCapturedPublicPlaylistsReachTheGuideWithoutCreatingVideoLibraries() async throws {
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/iptv-playlist-corpus")
        let manifestURL = corpus.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Opt in with python3 tools/iptv-playlist-corpus.py; no network is used by this test")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        XCTAssertFalse(manifest.sources.isEmpty)
        for source in manifest.sources {
            if let error = source.error {
                XCTFail("Public corpus download failed for \(source.name): \(error)")
                continue
            }
            let data = try Data(contentsOf: corpus.appendingPathComponent(source.file))
            XCTAssertEqual(data.count, source.bytes, source.name)
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), source.sha256)
            try await check(source, data: data)
        }
    }

    private func check(_ source: Source, data: Data) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            IPTVFixture.state.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let origin = try XCTUnwrap(URL(string: source.url))
        var parser = M3UPlaylistParser(baseURL: origin, permitsAuthenticationHeaders: true).makeCatalogStream()
        try parser.append(data)
        _ = try parser.finish()
        let entries = parser.takeCatalogEntries()
        XCTAssertEqual(entries.count, source.httpEntries, "\(source.name): unsupported lines must not become channels")
        let expectedNames = Set(entries.map(\.channel.name))
        XCTAssertFalse(expectedNames.isEmpty, source.name)
        IPTVFixture.state.handler = { _ in (200, [:], data) }
        let credential = try IPTVCredential(
            mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/" + source.file))
        )
        let session = try await IPTVProvider.signIn(
            credential: credential, name: source.name, deviceID: "corpus",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: source.name, credentialRevision: .init(),
                           localMediaContext: .init(accountID: source.name, profileID: "corpus", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        do {
            let libraries = try await provider.libraries()
            XCTAssertTrue(libraries.isEmpty, "\(source.name) invented VOD libraries: \(libraries.map(\.id))")
            let channels = try await provider.liveTVChannels()
            XCTAssertEqual(Set(channels.map(\.name)), expectedNames, source.name)
            let context = LiveTVAuthorizedServerProvider(
                accountID: source.name, authorizationID: "corpus", kind: .iptv, provider: provider
            )
            var configuration = LiveTVSourcesConfiguration()
            let enrollment = LiveTVServerEnrollmentCoordinator()
            let added = await enrollment.refresh(
                choices: [.init(id: source.name, name: source.name, userName: "IPTV", kind: .iptv)],
                resolver: { $0 == source.name ? context : nil },
                configuration: { configuration }, suppressedAccountIDs: { [] },
                apply: { configuration = $0 }
            )
            XCTAssertEqual(added.count, 1, source.name)
            let imports = LiveTVPrototypeImportModel(
                configuration: configuration, serverProviderResolver: { $0 == source.name ? context : nil }
            )
            let model = LiveTVPrototypeModel(channels: [])
            await imports.reload(into: model)
            XCTAssertEqual(imports.catalogPhase, .loaded, source.name)
            XCTAssertNil(imports.serverSources.first?.failure, source.name)
            XCTAssertEqual(model.visibleChannels.count, channels.count, source.name)
            XCTAssertEqual(imports.serverChannelReferences.count, channels.count, source.name)
            print("IPTV_CORPUS name=\(source.name) input=\(try XCTUnwrap(source.entries)) parsed=\(entries.count) channels=\(channels.count) libraries=\(libraries.count)")
        } catch {
            await provider.teardown()
            throw error
        }
        await provider.teardown()
    }

    private struct Manifest: Decodable { let sources: [Source] }
    private struct Source: Decodable {
        let name: String
        let url: String
        let file: String
        let entries: Int?
        let httpEntries: Int?
        let bytes: Int?
        let sha256: String?
        let error: String?
    }
}
