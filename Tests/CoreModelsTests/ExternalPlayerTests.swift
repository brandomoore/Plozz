import XCTest
@testable import CoreModels

final class ExternalPlayerTests: XCTestCase {
    private let media = URL(string: "https://server.test/media/a%20b.mkv?token=synthetic%2Bvalue&x=1#part")!
    private let nonce = UUID()

    func testOnePlaySelectionIsTransientAndPreservesVersionIdentity() throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, selectedVersionID: "edition")
        let selected = item.requestingExternalPlayer(.vlc)
        XCTAssertEqual(selected.selectedVersionID, "edition")
        XCTAssertEqual(selected.externalPlayerOverride, .vlc)
        XCTAssertEqual(selected.discPlaybackOverride, .playVideo)
        XCTAssertTrue(selected.explicitSourceSelection)
        XCTAssertNil(item.externalPlayerOverride)
        let restored = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(selected))
        XCTAssertNil(restored.externalPlayerOverride)
        XCTAssertEqual(selected.effectiveExternalPlayer(default: .init(player: .infuse)).player, .vlc)
    }

    func testCallbackPlayersCarryNestedURLsResumeSubtitlesAndUniqueReturnScheme() throws {
        for player in [ExternalPlayer.nativePlayer, .infuse] {
            let subtitles = (0..<10).map { URL(string: "https://server.test/\($0).srt?token=test&lang=en")! }
            let url = try ExternalPlayerURL.make(
                settings: .init(player: player), mediaURL: media, title: "A & B + C.mkv",
                position: 123.9, subtitles: subtitles, callbackScheme: "com.test.external-player", nonce: nonce
            )
            let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(url.scheme, player.scheme)
            XCTAssertEqual(url.path, "/play")
            XCTAssertFalse(url.absoluteString.contains("+"))
            XCTAssertEqual(query.first { $0.name == "url" }?.value, media.absoluteString)
            XCTAssertEqual(query.first { $0.name == "filename" }?.value, "A & B + C.mkv")
            XCTAssertEqual(query.first { $0.name == "position" }?.value, "123")
            XCTAssertEqual(query.filter { $0.name == "sub" }.compactMap(\.value), subtitles.prefix(8).map(\.absoluteString))
            for outcome in ["success", "error"] {
                let callback = try XCTUnwrap(query.first { $0.name == "x-" + outcome }?.value)
                let parsed = try XCTUnwrap(URLComponents(string: callback))
                XCTAssertEqual(parsed.scheme, "com.test.external-player")
                XCTAssertEqual(parsed.path, "/" + outcome)
                XCTAssertEqual(parsed.queryItems, [.init(name: "session", value: nonce.uuidString)])
            }
        }
    }

    func testVLCUsesDocumentedStreamActionWithoutPretendingToSupportResumeOrProgress() throws {
        let url = try ExternalPlayerURL.make(
            settings: .init(player: .vlc), mediaURL: media, title: "Movie",
            position: 123, subtitles: [media, media], callbackScheme: "test", nonce: nonce
        )
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.scheme, "vlc-x-callback")
        XCTAssertEqual(url.path, "/stream")
        XCTAssertEqual(query.filter { $0.name == "sub" }.count, 1)
        XCTAssertFalse(query.contains { ["position", "x-success", "x-error"].contains($0.name) })
    }

    func testCustomTemplateEncodesTheEntireMediaURLAsOneValue() throws {
        let url = try ExternalPlayerURL.make(
            settings: .init(player: .custom, customURLTemplate: "testplayer://play?video={url}&mode=1"),
            mediaURL: media, title: "Ignored", position: 0, callbackScheme: "test", nonce: nonce
        )
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [.init(name: "video", value: media.absoluteString), .init(name: "mode", value: "1")])
    }

    func testFTPRequiresVLCAndExplicitShareOptInAndPreservesNestedPaths() throws {
        let media = try XCTUnwrap(URL(string: "ftp://nas.test:2121//media/clip%2520%20%23.mp4"))
        for player in ExternalPlayer.allCases {
            XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(media, player: player))
            XCTAssertEqual(
                ExternalPlayerURL.isSupportedMediaURL(media, player: player, allowPassword: true), player == .vlc
            )
        }
        let link = try ExternalPlayerURL.make(
            settings: .init(player: .vlc), mediaURL: media, title: "Movie", position: 0,
            subtitles: [media], callbackScheme: "test", nonce: nonce, allowPassword: true
        )
        let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "url" }?.value, media.absoluteString)
        XCTAssertEqual(query.first { $0.name == "sub" }?.value, media.absoluteString)
        for scheme in ["ftps", "smb", "nfs", "sftp"] {
            XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(
                URL(string: "\(scheme)://nas.test/media/movie.mp4")!, player: .vlc, allowPassword: true
            ))
        }
        XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(
            URL(string: "ftp://127.0.0.1//movie.mp4")!, player: .vlc, allowPassword: true
        ))
    }

    func testInvalidCustomTemplatesFailClosed() {
        for template in [
            "", "testplayer://play", "testplayer://{url}/{url}", "testplayer://{url}/{title}",
            "https://example.test?url={url}", "file:///{url}", "javascript:{url}",
            "plozz://play?url={url}", "plozz-dev://play?url={url}",
            "com.test.external-player://external-player?url={url}",
            "testplayer://user:password@play/{url}", "testplayer://play?url={url} "
        ] {
            XCTAssertThrowsError(try ExternalPlayerURL.validateCustomTemplate(template), template)
        }
    }

    func testAppLocalCredentialAuthorityAndUnsupportedMediaURLsAreRejected() {
        for value in [
            "http://localhost/video", "http://127.0.0.2/video", "http://[::1]/video",
            "http://[::ffff:127.0.0.1]/video", "http://proxy.localhost/video",
            "file:///video.mkv", "smb://server/video", "https://user:pass@server.test/video",
            "https://server.test/video.mpd"
        ] {
            XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(URL(string: value)!), value)
        }
        XCTAssertTrue(ExternalPlayerURL.isSupportedMediaURL(URL(string: "http://192.168.1.2/video")!))
    }

    func testPasswordLinksRequireExplicitOptInAndAKnownPlayer() throws {
        var source = try XCTUnwrap(URLComponents(url: media, resolvingAgainstBaseURL: false))
        source.user = "fixture"
        source.password = "synthetic"
        let authenticated = try XCTUnwrap(source.url)
        for player in ExternalPlayer.allCases {
            XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(authenticated, player: player))
            let supported = [ExternalPlayer.nativePlayer, .infuse, .vlc].contains(player)
            XCTAssertEqual(
                ExternalPlayerURL.isSupportedMediaURL(authenticated, player: player, allowPassword: true), supported
            )
            if supported {
                let link = try ExternalPlayerURL.make(
                    settings: .init(player: player), mediaURL: authenticated, title: "Movie", position: 0,
                    subtitles: [authenticated], callbackScheme: "test", nonce: nonce, allowPassword: true
                )
                let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
                XCTAssertEqual(query.first { $0.name == "url" }?.value, authenticated.absoluteString)
                XCTAssertEqual(query.first { $0.name == "sub" }?.value, authenticated.absoluteString)
                for callback in query.filter({ $0.name.hasPrefix("x-") }) {
                    XCTAssertFalse(callback.value?.contains("synthetic") ?? true)
                }
            } else {
                XCTAssertThrowsError(try ExternalPlayerURL.make(
                    settings: .init(player: player, customURLTemplate: "player://play?url={url}"),
                    mediaURL: authenticated, title: "Movie", position: 0,
                    callbackScheme: "test", nonce: nonce, allowPassword: true
                ))
            }
        }
        source.password = nil
        XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(try XCTUnwrap(source.url), allowPassword: true))
        source.password = "synthetic"
        source.host = "127.0.0.1"
        XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(try XCTUnwrap(source.url), allowPassword: true))
    }

    func testPasswordPunctuationIsNotOverencodedInsideTheNestedURL() throws {
        let password = "fixture+&=!$'()*,;"
        var source = try XCTUnwrap(URLComponents(url: media, resolvingAgainstBaseURL: false))
        source.user = "fixture"
        source.password = password
        XCTAssertEqual(source.percentEncodedPassword, password)
        let authenticated = try XCTUnwrap(source.url)
        for player in [ExternalPlayer.nativePlayer, .infuse, .vlc] {
            let link = try ExternalPlayerURL.make(
                settings: .init(player: player), mediaURL: authenticated, title: "Movie", position: 0,
                subtitles: [authenticated], callbackScheme: "test", nonce: nonce, allowPassword: true
            )
            let query = try XCTUnwrap(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
            for name in ["url", "sub"] {
                let nested = try XCTUnwrap(query.first { $0.name == name }?.value)
                XCTAssertEqual(nested, authenticated.absoluteString)
                XCTAssertEqual(URLComponents(string: nested)?.percentEncodedPassword, password)
            }
        }
        source.password = "fixture:secret"
        let rawColon = try XCTUnwrap(source.url)
        for player in [ExternalPlayer.nativePlayer, .infuse] {
            XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(rawColon, player: player, allowPassword: true))
        }
    }

    func testIncompatiblePasswordsAreNotSentToPlayersThatRejectThem() throws {
        for password in [
            "fixture:secret", "fixture@secret", "fixture/secret", "fixture?secret",
            "fixture#secret", "fixture%secret", "fixtur\u{e9}"
        ] {
            var source = try XCTUnwrap(URLComponents(url: media, resolvingAgainstBaseURL: false))
            source.user = "fixture"
            source.password = password
            let url = try XCTUnwrap(source.url)
            if !password.contains(":") {
                XCTAssertNotEqual(source.password, source.percentEncodedPassword)
            }
            for player in [ExternalPlayer.nativePlayer, .infuse, .vlc] {
                XCTAssertEqual(
                    ExternalPlayerURL.isSupportedMediaURL(url, player: player, allowPassword: true), player == .vlc
                )
                if player != .vlc {
                    XCTAssertThrowsError(try ExternalPlayerURL.make(
                        settings: .init(player: player), mediaURL: url, title: "Movie", position: 0,
                        callbackScheme: "test", nonce: nonce, allowPassword: true
                    ))
                }
            }
        }
    }

    func testInvalidResumePositionsAreRejected() {
        for position in [Double.nan, .infinity, -1, Double(Int.max)] {
            XCTAssertThrowsError(try ExternalPlayerURL.make(
                settings: .init(player: .infuse), mediaURL: media, title: "Movie",
                position: position, callbackScheme: "test", nonce: nonce
            ))
        }
    }

    func testDASHIsHandedToVLCWithoutRelaxingURLSecurityChecks() throws {
        let manifest = URL(string: "https://server.test/movie.MPD?token=synthetic")!
        for player in ExternalPlayer.allCases {
            XCTAssertEqual(ExternalPlayerURL.isSupportedMediaURL(manifest, player: player), player == .vlc)
            for value in ["file:///movie.mpd", "http://127.0.0.1/movie.mpd", "https://user:password@server.test/movie.mpd"] {
                XCTAssertFalse(ExternalPlayerURL.isSupportedMediaURL(URL(string: value)!, player: player))
            }
        }
        let link = try ExternalPlayerURL.make(
            settings: .init(player: .vlc), mediaURL: manifest, title: "Movie",
            position: 0, callbackScheme: "test", nonce: nonce
        )
        XCTAssertEqual(
            URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "url" }?.value,
            manifest.absoluteString
        )
        XCTAssertThrowsError(try ExternalPlayerURL.make(
            settings: .init(player: .infuse), mediaURL: manifest, title: "Movie",
            position: 0, callbackScheme: "test", nonce: nonce
        ))
    }

    func testOldAndFutureSettingsPreserveOtherPreferencesAndDefaultToPlozz() throws {
        for external in ["", #","externalPlayer":{"player":"futurePlayer","customURLTemplate":""}"#] {
            let data = Data(#"{"autoPlayNextEpisode":false\#(external)}"#.utf8)
            let settings = try JSONDecoder().decode(PlaybackSettings.self, from: data)
            XCTAssertEqual(settings.externalPlayer.player, .builtIn)
            XCTAssertFalse(settings.autoPlayNextEpisode)
        }
    }

    @MainActor
    func testDeviceSelectionMigratesOnceAndNeverTransfersWithProfiles() throws {
        let suite = "ExternalPlayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = try JSONDecoder().decode(PlaybackSettings.self, from: Data(
            #"{"externalPlayer":{"player":"nativePlayer","customURLTemplate":""},"autoPlayNextEpisode":false}"#.utf8
        ))
        let model = ExternalPlayerSettingsModel(defaults: defaults)
        XCTAssertEqual(model.settings.player, .builtIn)
        model.migrateIfNeeded(from: legacy.externalPlayer)
        XCTAssertEqual(model.settings.player, .nativePlayer)
        model.migrateIfNeeded(from: .init(player: .vlc))
        XCTAssertEqual(model.settings.player, .nativePlayer)
        model.settings = .init(player: .custom, customURLTemplate: "testplayer://play?url={url}")
        let restoredModel = ExternalPlayerSettingsModel(defaults: defaults)
        restoredModel.migrateIfNeeded(from: legacy.externalPlayer)
        XCTAssertEqual(restoredModel.settings, model.settings)
        let data = try JSONEncoder().encode(legacy)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(encoded["externalPlayer"], "Retired profile selections must not be republished.")
        defaults.set(data, forKey: SettingsKey.scoped("com.plozz.playbackSettings", namespace: "one"))
        let captured = ProfileSettingsTransfer.capture(namespace: "one", defaults: defaults)
        XCTAssertNil(captured[ExternalPlayerSettingsModel.storageKey])
        XCTAssertNil(ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)[ExternalPlayerSettingsModel.storageKey])
        ProfileSettingsTransfer.apply(captured, namespace: "two", defaults: defaults)
        let restored = try XCTUnwrap(defaults.data(forKey: SettingsKey.scoped("com.plozz.playbackSettings", namespace: "two")))
        XCTAssertEqual(try JSONDecoder().decode(PlaybackSettings.self, from: restored).externalPlayer.player, .builtIn)
        XCTAssertFalse(try JSONDecoder().decode(PlaybackSettings.self, from: restored).autoPlayNextEpisode)
        XCTAssertNil(defaults.data(forKey: "com.plozz.playbackSettings"))
        XCTAssertEqual(ExternalPlayerSettingsModel(defaults: defaults).settings, model.settings)
    }

    @MainActor
    func testChoosingPlozzPreventsLaterLegacyProfilesFromEnablingExternalPlayback() throws {
        let suite = "ExternalPlayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ExternalPlayerSettingsModel(defaults: defaults)
        model.migrateIfNeeded(from: .init())
        model.migrateIfNeeded(from: .init(player: .infuse))
        XCTAssertEqual(model.settings.player, .builtIn)
        XCTAssertEqual(ExternalPlayerSettingsModel(defaults: defaults).settings.player, .builtIn)
    }

    func testLegacyProfileTransfersStripExternalPlayerWithoutLosingOtherFields() throws {
        let suite = "ExternalPlayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let base = "com.plozz.playbackSettings"
        let legacy = Data(#"{"externalPlayer":{"player":"infuse","customURLTemplate":""},"autoPlayNextEpisode":false,"futureSetting":42}"#.utf8)
        defaults.set(legacy, forKey: SettingsKey.scoped(base, namespace: "one"))
        let captured = ProfileSettingsTransfer.capture(namespace: "one", defaults: defaults)
        ProfileSettingsTransfer.apply(captured, namespace: "two", defaults: defaults)
        let oldSnapshot = try PropertyListSerialization.data(fromPropertyList: [legacy], format: .binary, options: 0)
        ProfileSettingsTransfer.apply([base: oldSnapshot], namespace: "three", defaults: defaults)
        ProfileSettingsTransfer.applyOne(baseKey: base, blob: oldSnapshot, namespace: "four", defaults: defaults)
        for namespace in ["two", "three", "four"] {
            let data = try XCTUnwrap(defaults.data(forKey: SettingsKey.scoped(base, namespace: namespace)))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(json["externalPlayer"])
            XCTAssertEqual(json["autoPlayNextEpisode"] as? Bool, false)
            XCTAssertEqual(json["futureSetting"] as? Int, 42)
        }
        XCTAssertEqual(defaults.data(forKey: SettingsKey.scoped(base, namespace: "one")), legacy)
    }
}
