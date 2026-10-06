import CoreModels
import CoreNetworking
import Foundation
@testable import ProviderIPTV
import XCTest

final class IPTVAuthenticationTests: XCTestCase {
    override func tearDown() {
        IPTVFixture.state.reset()
        super.tearDown()
    }

    func testPlaylistAuthenticationReachesImportAndActualProxiedMediaRequests() async throws {
        let basic = "Basic " + Data("viewer:fixture-password".utf8).base64EncodedString()
        let cases: [(String, [String: String], Bool)] = [
            ("https://viewer:fixture-password@provider.test/list", ["Authorization": basic], false),
            ("https://provider.test/list", ["Authorization": "Bearer fixture-bearer"], false),
            ("https://provider.test/list", ["Cookie": "session=fixture-cookie"], false),
            ("https://provider.test/list", ["X-Provider-Key": "fixture-key"], false),
            ("https://provider.test/list?token=playlist-fixture", [:], true)
        ]
        for (address, requiredHeaders, signedQuery) in cases {
            IPTVFixture.state.reset()
            let credential = try IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: address)),
                headers: address.contains("@") ? [:] : requiredHeaders
            )
            IPTVFixture.state.handler = { request in
                let isPlaylist = request.url?.path == "/list"
                let token = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                    .queryItems?.first { $0.name == "token" }?.value
                guard requiredHeaders.allSatisfy({ request.value(forHTTPHeaderField: $0.key) == $0.value }),
                      !signedQuery || token == (isPlaylist ? "playlist-fixture" : "media-fixture") else {
                    return (401, [:], Data())
                }
                if isPlaylist {
                    let media = "https://provider.test/channel.ts" + (signedQuery ? "?token=media-fixture" : "")
                    return (200, [:], Data("#EXTM3U\n#EXTINF:-1,Private channel\n\(media)\n".utf8))
                }
                return (200, ["Content-Type": "video/mp2t"], Data("authorized-media".utf8))
            }
            try await checkPlayback(credential)
            XCTAssertTrue(IPTVFixture.state.requests.contains { $0.url?.path == "/channel.ts" })
        }
    }

    func testInvalidHTTPAuthenticationAndLoginPagesCannotCreateAnAccount() async throws {
        for status in [401, 403, 200] {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in (status, [:], Data("<html>Sign in</html>".utf8)) }
            let root = temporaryDirectory()
            let credential = try IPTVCredential(
                mode: .playlist, address: XCTUnwrap(URL(string: "https://provider.test/list")),
                headers: ["Authorization": "Bearer incorrect-fixture"]
            )
            do {
                _ = try await IPTVProvider.signIn(
                    credential: credential, name: "Rejected", deviceID: "fixture",
                    cacheDirectory: root, configuration: IPTVFixture.configuration()
                )
                XCTFail("HTTP \(status) must not create a saved session")
            } catch {
                if status == 200 {
                    XCTAssertEqual(error as? LiveTVSourceImportError, .invalidPlaylist)
                } else {
                    XCTAssertEqual(error as? IPTVError, .authentication)
                }
            }
            XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        }
    }

    func testXtreamRejectsWrongDisabledAndExpiredAccountsBeforeCatalogRequests() async throws {
        let cases: [(String, IPTVError)] = [
            (#"{"auth":0,"status":"Active"}"#, .authentication),
            (#"{"auth":1,"status":"Expired"}"#, .expired),
            (#"{"auth":1,"status":"Disabled"}"#, .expired),
            (#"{"auth":1,"status":"Banned"}"#, .expired),
            (#"{"auth":1,"status":"Active","exp_date":"1"}"#, .expired)
        ]
        for (user, expected) in cases {
            IPTVFixture.state.reset()
            IPTVFixture.state.handler = { _ in
                (200, ["Content-Type": "application/json"], Data("{\"user_info\":\(user)}".utf8))
            }
            let credential = try IPTVCredential(
                mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix/player_api.php")),
                username: "viewer", password: "fixture-password"
            )
            do {
                _ = try await IPTVProvider.signIn(
                    credential: credential, name: "Rejected", deviceID: "fixture",
                    cacheDirectory: temporaryDirectory(), configuration: IPTVFixture.configuration()
                )
                XCTFail("Invalid Xtream account must not import a catalogue")
            } catch { XCTAssertEqual(error as? IPTVError, expected) }
            XCTAssertEqual(IPTVFixture.state.requests.count, 1)
        }
    }

    func testXtreamEscapesCredentialsAndReauthenticatesBeforeRestoredPlayback() async throws {
        let username = "viewer@example.test"
        let password = "fixture/p a&?+#"
        IPTVFixture.state.handler = { request in
            let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            guard query["username"] == username, query["password"] == password else { return (401, [:], Data()) }
            let payload: String
            switch query["action"] {
            case nil: payload = #"{"user_info":{"auth":"1","status":"Active","allowed_output_formats":["m3u8"]}}"#
            case "get_live_categories": payload = "[]"
            case "get_live_streams": payload = #"[{"stream_id":10,"name":"Private channel"}]"#
            default: throw URLError(.unsupportedURL)
            }
            return (200, [:], Data(payload.utf8))
        }
        let root = temporaryDirectory()
        let credential = try IPTVCredential(
            mode: .xtream, address: XCTUnwrap(URL(string: "https://provider.test/prefix/get.php?ignored=yes")),
            username: username, password: password
        )
        let first = try IPTVClient(credential: credential, directory: root, configuration: IPTVFixture.configuration())
        let channels = try await first.liveChannels()
        XCTAssertEqual(channels.map(\.id), ["live:10"])
        let restored = try IPTVClient(credential: credential, directory: root, configuration: IPTVFixture.configuration())
        let (url, _) = try await restored.delivery("live:10")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/prefix/live/viewer%40example.test/fixture%2Fp%20a%26%3F%2B%23/10.m3u8")
        XCTAssertNil(components.query)
        XCTAssertEqual(IPTVFixture.state.requests.filter { $0.url?.query?.contains("action=") == false }.count, 2)
    }

    private func checkPlayback(_ credential: IPTVCredential) async throws {
        let root = temporaryDirectory()
        let session = try await IPTVProvider.signIn(
            credential: credential, name: "Private", deviceID: "fixture",
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        let metadata = String(decoding: try JSONEncoder().encode(Account(id: "account", from: session)), as: UTF8.self)
        for secret in ["fixture-password", "fixture-bearer", "fixture-cookie", "fixture-key", "playlist-fixture"] {
            XCTAssertFalse(metadata.contains(secret))
        }
        let provider = try IPTVProvider(
            context: .init(session: session, accountID: "account", credentialRevision: .init(),
                           localMediaContext: .init(accountID: "account", profileID: "auth", profileNamespace: nil)),
            cacheDirectory: root, configuration: IPTVFixture.configuration()
        )
        do {
            let channels = try await provider.liveTVChannels()
            let channel = try XCTUnwrap(channels.first)
            let lease = try await provider.openLiveTVChannel(id: channel.id)
            do {
                guard case .authenticatedHTTP(let locator) = lease.playbackSource else {
                    throw XCTUnwrapError.missingLocator
                }
                let url = try await provider.resolveHTTPResource(locator)
                XCTAssertEqual(url.host, "127.0.0.1")
                let network = URLSession(configuration: .ephemeral)
                defer { network.invalidateAndCancel() }
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                let (data, response) = try await network.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(String(decoding: data, as: UTF8.self), "authorized-media")
            } catch {
                await lease.close()
                throw error
            }
            await lease.close()
        } catch {
            await provider.teardown()
            throw error
        }
        await provider.teardown()
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        }
        return root
    }

    private enum XCTUnwrapError: Error { case missingLocator }
}
