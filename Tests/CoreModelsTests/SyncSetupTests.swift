import XCTest
@testable import CoreModels

final class SyncSetupTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Feature flag

    func testFeatureFlagDefaultsOnAndPreservesExplicitOptOut() {
        // Default ON: an unset flag (fresh install) participates in the household so
        // "open a new device and your stuff is already there" works without hunting
        // for a toggle.
        let d = UserDefaults(suiteName: "syncsetup.test.\(UUID().uuidString)")!
        let flag = SyncSetupFeatureFlag(defaults: d)
        XCTAssertTrue(flag.isEnabled, "unset flag should default ON")
        // An explicit opt-out the user chose must be preserved (not re-defaulted ON).
        flag.isEnabled = false
        XCTAssertFalse(SyncSetupFeatureFlag(defaults: d).isEnabled, "explicit OFF must stick")
        // And it can be turned back on.
        flag.isEnabled = true
        XCTAssertTrue(SyncSetupFeatureFlag(defaults: d).isEnabled)
    }

    // MARK: Descriptor is token-free and derived correctly

    func testDescriptorFromAccountCarriesNoSecretAndKeepsIdentity() {
        let server = MediaServer(
            id: "srv1", name: "Home", baseURL: url("https://jelly.example.com"),
            provider: .jellyfin, connectionURLs: [url("https://jelly.example.com"), url("http://192.168.1.9:8096")]
        )
        let account = Account(id: "acc1", server: server, userID: "u1", userName: "Brandon", deviceID: "dev-A")
        let desc = SyncedAccountDescriptor(account: account)

        XCTAssertEqual(desc.id, "acc1")
        XCTAssertEqual(desc.provider, .jellyfin)
        XCTAssertEqual(desc.serverID, "srv1")
        XCTAssertEqual(desc.userName, "Brandon")
        XCTAssertEqual(desc.candidateBaseURLs.count, 2)
        // Round-trips as Codable without any token field existing.
        let data = try! JSONEncoder().encode(desc)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertFalse(json.lowercased().contains("token"))
        XCTAssertFalse(json.lowercased().contains("password"))
        XCTAssertFalse(json.lowercased().contains("deviceid"))
    }

    func testMediaShareConfigurationRoundTripsThroughDescriptor() throws {
        let configuration = MediaShareLibraryConfiguration(
            name: "Anime Films",
            contentType: .movies,
            isAnime: true
        )
        let server = MediaServer(
            id: "share:smb://nas/media#guest",
            name: configuration.name,
            baseURL: url("smb://nas/media"),
            provider: .mediaShare,
            mediaShareLibraryConfiguration: configuration
        )
        let descriptor = SyncedAccountDescriptor(
            account: Account(
                id: server.id,
                server: server,
                userID: "guest",
                userName: "",
                deviceID: "device"
            )
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(
            SyncedAccountDescriptor.self,
            from: data
        )

        XCTAssertEqual(decoded.mediaShareLibraryConfiguration, configuration)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
    }

    func testLegacyMediaServerWithoutConfigurationDecodesAsAutomatic() throws {
        let json = """
        {
          "id":"share:smb://nas/media#guest",
          "name":"Media",
          "baseURL":"smb://nas/media",
          "provider":"mediaShare"
        }
        """

        let server = try JSONDecoder().decode(
            MediaServer.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(server.mediaShareLibraryConfiguration)
    }

    func testLibraryConfigurationChangeIsMeaningfulForSync() {
        let base = SyncedAccountDescriptor(
            id: "share:smb://nas/media#guest",
            provider: .mediaShare,
            serverID: "share:smb://nas/media#guest",
            serverName: "Media",
            userID: "guest",
            userName: "",
            candidateBaseURLs: [url("smb://nas/media")],
            mediaShareLibraryConfiguration: MediaShareLibraryConfiguration(
                name: "Media",
                contentType: .automatic
            )
        )
        var changed = base
        changed.mediaShareLibraryConfiguration = MediaShareLibraryConfiguration(
            name: "Family Movies",
            contentType: .movies,
            isAnime: true
        )

        XCTAssertFalse(base.semanticallyEqualForSync(to: changed))
    }

    func testAnimeContentChoiceRoundTripsWithoutLegacyToggle() throws {
        XCTAssertEqual(
            MediaShareLibraryConfiguration.ContentType.allCases,
            [.automatic, .movies, .tvShows, .anime, .personalVideos]
        )
        let configuration = MediaShareLibraryConfiguration(name: "Anime", contentType: .anime)
        let server = MediaServer(
            id: "share:anime", name: "Anime", baseURL: url("webdav+https://nas/media"),
            provider: .mediaShare, mediaShareLibraryConfiguration: configuration
        )
        let descriptor = SyncedAccountDescriptor(account: Account(
            id: server.id, server: server, userID: "guest", userName: "", deviceID: "device"
        ))
        let decoded = try JSONDecoder().decode(
            SyncedAccountDescriptor.self, from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(decoded.mediaShareLibraryConfiguration, configuration)
        XCTAssertTrue(configuration.usesAnimeMetadata)
        XCTAssertFalse(configuration.isAnime, "New choices do not depend on the legacy toggle.")
    }

    func testLegacyAnimeToggleConfigurationsKeepTheirOriginalClassification() throws {
        for type in ["automatic", "movies", "tvShows"] {
            let json = """
            {"name":"Existing anime library","contentType":"\(type)","isAnime":true}
            """
            let configuration = try JSONDecoder().decode(
                MediaShareLibraryConfiguration.self, from: Data(json.utf8)
            )
            XCTAssertEqual(configuration.contentType.rawValue, type)
            XCTAssertTrue(configuration.usesAnimeMetadata)
            XCTAssertEqual(
                try JSONDecoder().decode(MediaShareLibraryConfiguration.self, from: JSONEncoder().encode(configuration)),
                configuration
            )
        }
    }

    // MARK: Deterministic account ids (holistic cross-device duplicate prevention)

    func testStableIDIsDeterministicForTokenProviders() {
        let server = MediaServer(id: "plex-machine-1", name: "Brandoland", baseURL: url("https://plex.example"), provider: .plex)
        let s1 = UserSession(server: server, userID: "u-brandon", userName: "brandon", deviceID: "dev-A", accessToken: "tok1")
        let s2 = UserSession(server: server, userID: "u-brandon", userName: "brandon", deviceID: "dev-B", accessToken: "tok2")
        // Same server+user on two devices / two sign-ins → SAME id (so re-adding
        // updates in place and sync/pairing can't fork a duplicate).
        XCTAssertEqual(Account.stableID(for: s1), Account.stableID(for: s2))
    }

    func testStableIDDistinguishesUsersServersAndProviders() {
        let plex = MediaServer(id: "srv", name: "S", baseURL: url("https://x"), provider: .plex)
        let jelly = MediaServer(id: "srv", name: "S", baseURL: url("https://x"), provider: .jellyfin)
        func sid(_ server: MediaServer, _ user: String) -> String {
            Account.stableID(for: UserSession(server: server, userID: user, userName: user, deviceID: "d", accessToken: "t"))
        }
        XCTAssertNotEqual(sid(plex, "a"), sid(plex, "b"))     // different user
        XCTAssertNotEqual(sid(plex, "a"), sid(jelly, "a"))    // different provider
        let plex2 = MediaServer(id: "srv2", name: "S", baseURL: url("https://x"), provider: .plex)
        XCTAssertNotEqual(sid(plex, "a"), sid(plex2, "a"))    // different server
    }

    func testStableIDPreservesMediaShareIdentity() {
        // Media shares keep their existing deterministic id (server.id) so persisted
        // credentials aren't orphaned.
        let share = MediaServer(id: "share:nfs://host:2049/media#guest", name: "Media", baseURL: url("nfs://host/media"), provider: .mediaShare)
        let session = UserSession(server: share, userID: "guest", userName: "guest", deviceID: "d", accessToken: "")
        XCTAssertEqual(Account.stableID(for: session), "share:nfs://host:2049/media#guest")
    }

    // MARK: Endpoint-retarget protection

    func testAuthorizedDeviceWithholdsUntrustedOrigin() {
        var auth = LocalAuthorization(id: "acc1", state: .authorized, deviceID: "dev-A")
        auth.trustedOrigins = [LocalAuthorization.origin(of: url("https://jelly.example.com"))]

        // A synced descriptor tries to introduce an attacker origin.
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .jellyfin, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://jelly.example.com"), url("https://evil.example.net")]
        )

        // Only the already-trusted origin is usable; the new one is withheld.
        let allowed = auth.allowedURLs(from: desc)
        XCTAssertEqual(allowed, [url("https://jelly.example.com")])
        XCTAssertTrue(auth.requiresReverification(for: desc))
    }

    func testPendingDeviceMayUseAllCandidatesForFreshSignIn() {
        let auth = LocalAuthorization(id: "acc1", state: .pending, deviceID: "dev-B")
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .plex, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://plex.example.com"), url("http://10.0.0.5:32400")]
        )
        XCTAssertEqual(auth.allowedURLs(from: desc).count, 2)
        XCTAssertFalse(auth.requiresReverification(for: desc))
    }

    func testAuthorizedDeviceWithMatchingOriginsNeedsNoReverification() {
        var auth = LocalAuthorization(id: "acc1", state: .authorized, deviceID: "dev-A")
        auth.trustedOrigins = [
            LocalAuthorization.origin(of: url("https://jelly.example.com")),
            LocalAuthorization.origin(of: url("http://192.168.1.9:8096"))
        ]
        let desc = SyncedAccountDescriptor(
            id: "acc1", provider: .jellyfin, serverID: "srv1", serverName: "Home",
            userID: "u1", userName: "Brandon",
            candidateBaseURLs: [url("https://jelly.example.com"), url("http://192.168.1.9:8096")]
        )
        XCTAssertFalse(auth.requiresReverification(for: desc))
        XCTAssertEqual(auth.allowedURLs(from: desc).count, 2)
    }

    func testOriginNormalizationIgnoresPathAndCase() {
        XCTAssertEqual(
            LocalAuthorization.origin(of: url("HTTPS://Jelly.Example.com/web/index.html")),
            "https://jelly.example.com"
        )
        XCTAssertEqual(
            LocalAuthorization.origin(of: url("http://10.0.0.5:32400/library")),
            "http://10.0.0.5:32400"
        )
    }
}
