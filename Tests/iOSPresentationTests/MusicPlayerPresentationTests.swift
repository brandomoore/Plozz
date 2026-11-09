#if os(iOS)
import AVFoundation
@testable import AppShelliOS
import CoreModels
import CoreNetworking
@testable import FeatureMusic
import ProviderPlex
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class MusicPlayerPresentationTests: XCTestCase {
    func testPlayerAccentMatchesMozzInLightAndDarkAppearance() {
        let cases: [(UIUserInterfaceStyle, [CGFloat])] = [
            (.light, [28 / 255, 28 / 255, 30 / 255]),
            (.dark, [242 / 255, 242 / 255, 242 / 255])
        ]
        for (style, expected) in cases {
            let color = UIColor(Color.musicPlayerAccent).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, expected[0], accuracy: 0.001)
            XCTAssertEqual(green, expected[1], accuracy: 0.001)
            XCTAssertEqual(blue, expected[2], accuracy: 0.001)
        }
    }

    func testMobileNavigationOnlyIncludesMusicWhenEnabled() {
        let music = NavigationLibraryLayout.musicKey
        XCTAssertFalse(NavigationDestinationDefaults.iOS(visibleLibraries: []).contains(music))
        let enabled = NavigationDestinationDefaults.iOS(visibleLibraries: [], hasMusic: true)
        XCTAssertTrue(enabled.contains(music))
        XCTAssertFalse(NavigationDestinationDefaults.iOSAutomaticallyHiddenKeys(available: enabled).contains(music))
        XCTAssertFalse(AppReleaseChannel.production.isBeta)
        XCTAssertTrue(AppReleaseChannel.testflight.isBeta)
        XCTAssertTrue(AppReleaseChannel.debug.isBeta)
    }

    func testFeedbackRollbackSerializationAndScopeInvalidation() async throws {
        let http = MusicFeedbackHTTP()
        let session = MusicPlayerSession()
        defer { session.stop() }
        let user = UserSession(
            server: MediaServer(id: "server", name: "Music", baseURL: URL(string: "https://music.invalid")!, provider: .plex),
            userID: "user", userName: "Listener", deviceID: "device", accessToken: "fixture-token"
        )
        let provider = PlexProvider(session: user, http: http)
        let account = ResolvedAccount(account: Account(id: "account", from: user), provider: provider)
        session.configure(accounts: [account], authorizationID: "first", isAuthorized: { true })
        let track = FeatureMusic.Track(source: CoreModels.MusicTrack(id: "song", title: "Song", sourceAccountID: "account"))
        session.playback.feedback[track.id] = .rating(2)
        await http.setFailure(true)
        let failed = await session.environment.setRating(4, track: track)
        XCTAssertFalse(failed)
        XCTAssertEqual(session.playback.feedback[track.id], .rating(2))
        XCTAssertNotNil(session.toasts.message)
        await http.setFailure(false)
        let first = Task { await session.environment.setRating(3, track: track) }
        let second = Task { await session.environment.setRating(4.5, track: track) }
        let firstSaved = await first.value
        let secondSaved = await second.value
        XCTAssertTrue(firstSaved)
        XCTAssertTrue(secondSaved)
        XCTAssertEqual(session.playback.feedback[track.id], .rating(4.5))
        let writes = await http.ratings
        XCTAssertEqual(writes, ["8.0", "6.0", "9.0"])
        session.configure(accounts: [], authorizationID: "second", isAuthorized: { false })
        XCTAssertTrue(session.playback.feedback.isEmpty)
        let rejected = await session.environment.setRating(5, track: track)
        XCTAssertFalse(rejected)
        let after = await http.ratings
        XCTAssertEqual(after, writes)
    }

    func testAlbumAndArtistNavigationPreservesAccountIdentity() {
        let source = CoreModels.MusicTrack(
            id: "song", title: "Song", albumTitle: "Album", albumID: "album",
            artistName: "Artist", artistID: "artist", sourceAccountID: "account"
        )
        XCTAssertTrue(TrackNavigationButtons.canNavigate(.init(source: source), surface: .player))
        var noAccount = source
        noAccount.sourceAccountID = nil
        XCTAssertFalse(TrackNavigationButtons.canNavigate(.init(source: noAccount), surface: .player))
        let navigation = MusicNavigation()
        navigation.open(.album(MusicAlbum(id: "album", title: "Album", sourceAccountID: "account")))
        XCTAssertEqual(navigation.path, [.album(MusicAlbum(id: "album", title: "Album", sourceAccountID: "account"))])
        navigation.reset()
        XCTAssertTrue(navigation.path.isEmpty)
    }

    func testFeedbackCompletionCannotRepopulateAnInvalidatedProfile() async {
        let http = MusicFeedbackHTTP()
        await http.holdNextWrite()
        let session = MusicPlayerSession()
        defer { session.stop() }
        let user = UserSession(
            server: MediaServer(id: "server", name: "Music", baseURL: URL(string: "https://music.invalid")!, provider: .plex),
            userID: "user", userName: "Listener", deviceID: "device", accessToken: "fixture-token"
        )
        let provider = PlexProvider(session: user, http: http)
        session.configure(
            accounts: [ResolvedAccount(account: Account(id: "account", from: user), provider: provider)],
            authorizationID: "first", isAuthorized: { true }
        )
        let track = FeatureMusic.Track(source: CoreModels.MusicTrack(id: "song", title: "Song", sourceAccountID: "account"))
        let write = Task { await session.environment.setRating(4, track: track) }
        await http.waitUntilHeld()
        session.configure(accounts: [], authorizationID: "second", isAuthorized: { false })
        await http.releaseWrite()
        let saved = await write.value
        XCTAssertFalse(saved)
        XCTAssertTrue(session.playback.feedback.isEmpty)
        XCTAssertNil(session.toasts.message)
    }

    func testMountedPlayerExpandsCollapsesAndChangesTracks() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let player = MusicPlayerSession()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: file)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000))
        buffer.frameLength = 441_000
        let samples = try XCTUnwrap(buffer.floatChannelData)
        samples[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            try audio.write(from: buffer)
        }
        player.controller.play(
            tracks: [
                CoreModels.MusicTrack(id: "one", title: "The First Song", albumTitle: "Evening Light", albumID: "album", artistName: "Test Artist", artistID: "artist", duration: 10, sourceAccountID: "fixture"),
                CoreModels.MusicTrack(id: "two", title: "Another Song", albumTitle: "Evening Light", albumID: "album", artistName: "Test Artist", artistID: "artist", duration: 10, sourceAccountID: "fixture"),
                CoreModels.MusicTrack(id: "unavailable", title: "Unavailable", duration: 10)
            ],
            startIndex: 0,
            resolveStreamURL: { track in
                if track.id == "unavailable" {
                    return nil
                }
                return .init(url: file)
            }
        )
        let host = UIHostingController(rootView:
            ZStack {
                Color(uiColor: .systemBackground).ignoresSafeArea()
                MusicPlayerOverlay(session: player, hasBottomBar: false)
            }
            .tint(.blue)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500))
        attach(window, name: "Music mini player")
        player.isPresented = true
        try await Task.sleep(for: .milliseconds(900))
        let expanded = attach(window, name: "Music expanded player")
        XCTAssertLessThan(try brightBluePixelCount(in: expanded), 10, "Player menus must not inherit the host's blue tint")
        XCTAssertTrue(player.isPresented)
        player.controller.pause()
        await player.controller.seek(to: 2)
        XCTAssertEqual(player.controller.currentTime, 2, accuracy: 0.1)
        XCTAssertFalse(player.controller.isPlaying)
        player.controller.resume()
        let generation = player.controller.transportGeneration
        player.playback.next()
        XCTAssertEqual(player.controller.currentTrack?.id, "two")
        XCTAssertGreaterThan(player.controller.transportGeneration, generation)
        player.isPresented = false
        try await Task.sleep(for: .milliseconds(900))
        attach(window, name: "Music collapsed after skip")
        player.isPresented = true
        player.isPresented = false
        player.isPresented = true
        try await Task.sleep(for: .milliseconds(900))
        attach(window, name: "Music reopened player")
        XCTAssertTrue(player.isPresented)
        XCTAssertGreaterThan(host.view.bounds.width, 0)
        player.controller.next()
        let deadline = Date().addingTimeInterval(2)
        while !player.controller.playbackFailed && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(player.controller.playbackFailed)
        XCTAssertFalse(player.controller.isPlaying)
        XCTAssertFalse(player.controller.isBuffering)
    }

    func testDockClearsOnlyAnActualBottomTabBarAcrossWindowSizes() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let player = MusicPlayerSession()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer {
            player.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            try? FileManager.default.removeItem(at: file)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_646_000))
        buffer.frameLength = buffer.frameCapacity
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            try audio.write(from: buffer)
        }
        player.controller.play(
            tracks: (0..<3).map {
                CoreModels.MusicTrack(id: "dock-\($0)", title: "Dock probe", artistName: "Artist", duration: 60)
            },
            startIndex: 1, resolveStreamURL: { _ in .init(url: file) }
        )
        player.controller.pause()
        var reportedBottomBar: Bool?
        let host = UIHostingController(rootView: MusicDockNavigationFixture(
            player: player, onBottomBarChange: { reportedBottomBar = $0 }
        ))
        host.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        for width in [834.0, 430.0, 834.0] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1_194)
            host.traitOverrides.horizontalSizeClass = width > 600 ? .regular : .compact
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(700))
            window.layoutIfNeeded()
            let tabs = try XCTUnwrap(tabController(in: host))
            let nativeBarFrame = tabs.tabBar.convert(tabs.tabBar.bounds, to: tabs.view)
            let expectedBottom = !tabs.isTabBarHidden && !tabs.tabBar.isHidden
                && tabs.tabBar.alpha > 0 && tabs.tabBar.window != nil
                && nativeBarFrame.height > 0 && nativeBarFrame.minY >= tabs.view.bounds.midY
                && nativeBarFrame.intersects(tabs.view.bounds)
            let deadline = Date().addingTimeInterval(3)
            while reportedBottomBar != expectedBottom && Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(reportedBottomBar, expectedBottom,
                           "Native bar \(tabs.tabBar.frame), hidden \(tabs.tabBar.isHidden), alpha \(tabs.tabBar.alpha), attached \(tabs.tabBar.window != nil), traits \(tabs.traitCollection.horizontalSizeClass.rawValue), width \(width)")
            XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
            let image = attach(window, name: "Music dock \(Int(width)) bottom bar \(expectedBottom)")
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let title = try XCTUnwrap(request.results?.first {
                $0.topCandidates(1).first?.string == "Dock probe"
            })
            let distanceFromBottom = title.boundingBox.minY * image.size.height
            if expectedBottom {
                XCTAssertGreaterThan(distanceFromBottom, 100, "The dock must still clear phone/compact navigation")
                XCTAssertLessThan(distanceFromBottom, 170)
            } else {
                XCTAssertGreaterThan(distanceFromBottom, 30)
                XCTAssertLessThan(distanceFromBottom, 90, "No extra tab-bar height below the iPad dock")
            }
            XCTAssertFalse(tabs.isTabBarHidden, "Measure top-vs-bottom placement, not a deliberately hidden bar")
            for playing in [false, true] {
                if playing { player.controller.resume() } else { player.controller.pause() }
                let readyDeadline = Date().addingTimeInterval(5)
                while player.playback.snapshot.status != (playing ? .playing : .paused), Date() < readyDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(player.playback.snapshot.status, playing ? .playing : .paused)
                let controls = attach(window, name: "Dock controls \(Int(width)) playing \(playing)")
                let wide = width > 600
                let dockWidth = min(width - 44, 640)
                let lastControlX = (width + dockWidth) / 2 - 12 - 15
                let centerY = controls.size.height - 22 - (expectedBottom ? 71 : 0) - 28
                let playX = lastControlX - (wide ? 80 : 40)
                let playHeight = try dockGlyphHeight(in: controls, center: CGPoint(x: playX, y: centerY))
                if wide {
                    for offset in [0.0, 40.0, 120.0, 160.0] {
                        let secondaryHeight = try dockGlyphHeight(
                            in: controls, center: CGPoint(x: lastControlX - offset, y: centerY)
                        )
                        XCTAssertGreaterThan(playHeight, secondaryHeight * 1.15,
                                             "Both play and pause must be visibly larger than the other wide-dock controls")
                    }
                    XCTAssertGreaterThan(playHeight, 19)
                    XCTAssertLessThan(playHeight, 25)
                } else {
                    XCTAssertEqual(playHeight, playing ? 30 * 16 / 24 : 30 * 18 / 24, accuracy: 1.5,
                                   "Compact dock play/pause must use the same prominent size as the wide dock")
                    let nextHeight = try dockGlyphHeight(
                        in: controls, center: CGPoint(x: lastControlX, y: centerY)
                    )
                    XCTAssertGreaterThan(playHeight, nextHeight * 1.15,
                                         "Both play and pause must be visibly larger than the compact dock's next control")
                }
            }
        }
    }

    private func dockGlyphHeight(in image: UIImage, center: CGPoint) throws -> CGFloat {
        let source = try XCTUnwrap(image.cgImage)
        let scale = image.scale
        let rect = CGRect(x: (center.x - 15) * scale, y: (center.y - 15) * scale,
                          width: 30 * scale, height: 30 * scale).integral
        let glyph = try XCTUnwrap(source.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: glyph.width * glyph.height * 4)
        return try bytes.withUnsafeMutableBytes { pixels in
            let context = try XCTUnwrap(CGContext(
                data: pixels.baseAddress, width: glyph.width, height: glyph.height,
                bitsPerComponent: 8, bytesPerRow: glyph.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(glyph, in: CGRect(x: 0, y: 0, width: glyph.width, height: glyph.height))
            let inkRows = (0..<glyph.height).filter { row in
                (0..<glyph.width).contains { column in
                    let offset = (row * glyph.width + column) * 4
                    return max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 190
                }
            }
            let first = try XCTUnwrap(inkRows.first, "Expected visible dock glyph at \(center)")
            let last = try XCTUnwrap(inkRows.last)
            return CGFloat(last - first + 1) / scale
        }
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }

    private func brightBluePixelCount(in image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: source.width * source.height * 4)
        return try bytes.withUnsafeMutableBytes { pixels in
            let context = try XCTUnwrap(CGContext(
                data: pixels.baseAddress, width: source.width, height: source.height,
                bitsPerComponent: 8, bytesPerRow: source.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
            var count = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[offset] < 80, pixels[offset + 1] > 90, pixels[offset + 2] > 210 {
                    count += 1
                }
            }
            return count
        }
    }

    @discardableResult
    private func attach(_ window: UIWindow, name: String) -> UIImage {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

private struct MusicDockNavigationFixture: View {
    let player: MusicPlayerSession
    let onBottomBarChange: (Bool) -> Void
    @State private var hasBottomBar = false

    var body: some View {
        TabView {
            Tab("Music", systemImage: "music.note") {
                NavigationStack { Text("Library content").navigationTitle("Music") }
            }
            Tab("Library", systemImage: "square.stack") { Text("Library") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            PlozziOSSettingsTabAction(
                tabIndex: nil, action: {},
                onBottomBarVisibilityChange: {
                    hasBottomBar = $0
                    onBottomBarChange($0)
                }
            )
            .frame(width: 0, height: 0)
        }
        .overlay {
            MusicPlayerOverlay(session: player, hasBottomBar: hasBottomBar)
        }
    }
}

private actor MusicFeedbackHTTP: HTTPClient {
    var ratings: [String] = []
    private var fail = false
    private var shouldHold = false
    private var heldWrite: CheckedContinuation<Void, Never>?
    private var holdObserver: CheckedContinuation<Void, Never>?
    func setFailure(_ value: Bool) { fail = value }
    func holdNextWrite() { shouldHold = true }
    func waitUntilHeld() async {
        if heldWrite != nil { return }
        await withCheckedContinuation { holdObserver = $0 }
    }
    func releaseWrite() {
        heldWrite?.resume()
        heldWrite = nil
    }

    func send(_ endpoint: Endpoint, baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard endpoint.path == "/:/rate" else { throw AppError.notFound }
        ratings.append(endpoint.queryItems.first { $0.name == "rating" }?.value ?? "")
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation {
                heldWrite = $0
                holdObserver?.resume()
                holdObserver = nil
            }
        }
        if fail { throw AppError.serverUnreachable }
        return (Data(), HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
#endif
