#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureHomeCore

@MainActor
final class ThemeMusicPlaybackHostedTests: XCTestCase {
    func testRepeatedTitleAncestorCannotDiscardForegroundPausePosition() async throws {
        try await withFixture { model in
            try await self.waitUntil { model.controller.player.currentTime().seconds > 0.1 }
            let ancestor = try XCTUnwrap(model.controller.detailOwner)
            model.foreground = 1
            try await self.waitUntil {
                model.controller.detailOwner != nil && model.controller.detailOwner != ancestor
                    && model.controller.player.currentTime().seconds > 0.1
            }
            let owner = model.controller.detailOwner
            let item = try XCTUnwrap(model.controller.player.currentItem)
            model.controller.setAppActive(false)
            try await self.waitUntil { !model.controller.isPlaying }
            let paused = model.controller.player.currentTime().seconds
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.controller.detailOwner, owner)
            XCTAssertTrue(model.controller.player.currentItem === item)
            XCTAssertEqual(model.controller.player.currentTime().seconds, paused, accuracy: 0.05)
            model.controller.setAppActive(true)
            try await self.waitUntil { model.controller.player.currentTime().seconds > paused + 0.05 }
            XCTAssertTrue(model.controller.player.currentItem === item)
        }
    }

    func testLeavingDetailThroughVisibilityOrRemovalFadesThenReleasesPlayer() async throws {
        for remove in [false, true] {
            try await withFixture { model in
                try await self.waitUntil {
                    model.controller.player.currentTime().seconds > 0.1
                        && model.controller.player.volume > 0.01
                }
                let item = try XCTUnwrap(model.controller.player.currentItem)
                let startingVolume = model.controller.player.volume
                if remove {
                    model.showsDetails = false
                } else {
                    model.foreground = -1
                }
                try await self.waitUntil { model.controller.detailOwner == nil }
                XCTAssertTrue(model.controller.player.currentItem === item)
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertGreaterThan(model.controller.player.volume, 0)
                XCTAssertLessThan(model.controller.player.volume, startingVolume)
                XCTAssertTrue(model.controller.player.currentItem === item)
                try await self.waitUntil { model.controller.player.currentItem == nil }
                XCTAssertFalse(model.controller.isPlaying)
            }
        }
    }

    func testExcludedAccountCannotResolveOrResumeAfterSettingsCloses() async throws {
        try await withFixture { model in
            try await self.waitUntil { model.controller.currentPlaybackID != nil }
            model.detailAllowed = false
            try await self.waitUntil { model.controller.currentPlaybackID == nil }
            let count = model.provider.calls
            model.accountAllowed = false
            model.scope = "profile:other-account"
            model.detailAllowed = true
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.provider.calls, count)
            XCTAssertNil(model.controller.currentPlaybackID)
            XCTAssertNil(model.controller.player.currentItem)
        }
    }

    func testRevocationDuringPublicThemeResolutionCannotReachPlayer() async throws {
        let data = ThemeMusicPreviewSample.data()
        let server = try IPTVTestHTTPServer { request in
            let headers = ["Content-Type": "audio/wav", "Accept-Ranges": "bytes"]
            guard let header = request.components(separatedBy: "\r\n").first(where: {
                $0.lowercased().hasPrefix("range: bytes=")
            }) else { return .init(data: data, headers: headers) }
            let bounds = header.dropFirst("range: bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let first = Int(bounds[0]), first >= 0, first < data.count else {
                return .init(status: 416)
            }
            let last = min(Int(bounds[1]) ?? data.count - 1, data.count - 1)
            guard last >= first else { return .init(status: 416) }
            return .init(
                data: data, status: 206,
                headers: headers.merging(["Content-Range": "bytes \(first)-\(last)/\(data.count)"]) { _, new in new },
                range: first..<(last + 1)
            )
        }
        let url = try await server.start().appendingPathComponent("theme.wav")
        do {
            try await withFixture(delayTheme: true, publicThemeURL: url) { model in
                try await self.waitUntil { model.provider.pending != nil }
                // No render notification: the post-await live check must reject
                // this before even briefly queuing an AVPlayer item.
                model.liveAllowed = false
                model.provider.finish()
                try await self.waitUntil { model.controller.detailOwner == nil }
                XCTAssertEqual(model.queuedItems.count, 0)
                XCTAssertNil(model.controller.currentPlaybackID)
                XCTAssertNil(model.controller.player.currentItem)
                XCTAssertEqual(model.resolver.calls, 0)

                // The same public source must genuinely play when authorized.
                model.liveAllowed = true
                model.scope = "profile:account:revision-2"
                try await self.waitUntil { model.controller.player.currentTime().seconds > 0.1 }
                XCTAssertGreaterThan(model.queuedItems.count, 0)
                XCTAssertEqual(model.resolver.calls, 0)
            }
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func testCredentialChangeDuringURLResolutionCannotPublishOldSource() async throws {
        try await withFixture(delayURL: true) { model in
            try await self.waitUntil { model.resolver.pending != nil }
            model.liveAllowed = false
            model.resolver.finish()
            try await self.waitUntil { model.controller.detailOwner == nil }
            XCTAssertEqual(model.queuedItems.count, 0)
            XCTAssertNil(model.controller.currentPlaybackID)
            XCTAssertNil(model.controller.player.currentItem)
        }
    }

    func testNewCredentialScopeReResolvesThroughCurrentProvider() async throws {
        try await withFixture { model in
            try await self.waitUntil { model.controller.currentPlaybackID != nil }
            let old = model.provider
            let replacement = ThemeProvider()
            model.provider = replacement
            model.scope = "profile:account:revision-2"
            try await self.waitUntil { replacement.calls == 1 && model.controller.currentPlaybackID != nil }
            XCTAssertEqual(old.calls, 1)
            XCTAssertEqual(replacement.calls, 1)
        }
    }

    func testInterruptionCancelsLookupAndRetriesOnEndWithoutNavigation() async throws {
        try await withFixture(delayTheme: true) { model in
            try await self.waitUntil { model.provider.pending != nil }
            model.controller.setInterrupted(true)
            model.provider.finish()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(model.controller.currentPlaybackID)
            XCTAssertNil(model.controller.player.currentItem)
            model.controller.setInterrupted(false)
            try await self.waitUntil { model.provider.calls == 2 && model.controller.isPlaying }
            XCTAssertNotNil(model.controller.player.currentItem)
        }
    }

    private func withFixture(
        delayTheme: Bool = false, publicThemeURL: URL? = nil, delayURL: Bool = false,
        body: (Model) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let suite = "ThemePlaybackHosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-hosted-\(UUID().uuidString).wav")
        try ThemeMusicPreviewSample.data().write(to: url)
        let model = Model(defaults: defaults, url: url)
        model.provider.delaysFirst = delayTheme
        model.provider.publicThemeURL = publicThemeURL
        model.resolver.delaysFirst = delayURL
        let recorder = model.queuedItems
        let observation = model.controller.player.observe(\.currentItem, options: [.new]) { player, _ in
            if player.currentItem != nil { recorder.record() }
        }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Fixture(model: model)
            .environment(\.scenePhase, .active))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            model.liveAllowed = false
            model.provider.finish()
            model.resolver.finish()
            model.controller.stop()
            observation.invalidate()
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: url)
        }
        try await body(model)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    @MainActor @Observable
    final class Model {
        let controller = ThemeMusicController()
        let settings: ThemeMusicSettingsModel
        var provider = ThemeProvider()
        let resolver: URLResolver
        let queuedItems = QueuedItemRecorder()
        var scope = "profile:account:revision-1"
        var foreground = 0
        var showsDetails = true
        var accountAllowed = true
        var detailAllowed = true
        @ObservationIgnored var liveAllowed = true

        init(defaults: UserDefaults, url: URL) {
            settings = ThemeMusicSettingsModel(store: ThemeMusicSettingsStore(defaults: defaults))
            resolver = URLResolver(url: url)
            controller.player.isMuted = true
        }

        var authorization: ThemeMusicPlaybackAuthorization {
            let expected = scope
            return ThemeMusicPlaybackAuthorization(id: scope, provider: { accountID in
                guard self.scope == expected, self.accountAllowed, self.liveAllowed,
                      accountID == "account" else { return nil }
                return self.provider
            })
        }
    }

    private struct Fixture: View {
        @Bindable var model: Model

        var body: some View {
            VStack {
                if model.showsDetails {
                    page(0)
                    page(1)
                }
            }
            .themeMusicScope(
                controller: model.controller, model: model.settings,
                background: HeroBackgroundSettings(detailMode: .themeMusic),
                isBlocked: false, detailAllowed: model.detailAllowed,
                authorization: model.authorization, authenticatedHTTPResolver: model.resolver
            )
        }

        private func page(_ index: Int) -> some View {
            Color.clear.frame(width: 10, height: 10)
                .themeMusicPlayback(
                    playbackID: "account:series",
                    source: MediaSourceRef(
                        accountID: "account", itemID: "series", providerKind: .jellyfin,
                        serverName: "Server", accountName: "User"
                    ),
                    isActive: model.foreground == index
                )
        }
    }

    @MainActor final class URLResolver: AuthenticatedHTTPResourceResolving {
        let url: URL
        var calls = 0
        var delaysFirst = false
        var pending: CheckedContinuation<URL, Never>?

        init(url: URL) { self.url = url }
        func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
            calls += 1
            if delaysFirst && calls == 1 {
                return await withCheckedContinuation { pending = $0 }
            }
            return url
        }
        func finish() {
            pending?.resume(returning: url)
            pending = nil
        }
    }

    @MainActor final class ThemeProvider: MediaProvider {
        nonisolated let kind = ProviderKind.jellyfin
        nonisolated let session = UserSession(
            server: MediaServer(id: "server", name: "Server", baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
            userID: "user", userName: "User", deviceID: "device", accessToken: ""
        )
        var calls = 0
        var delaysFirst = false
        var publicThemeURL: URL?
        var pending: CheckedContinuation<ThemeMusic?, Never>?

        func themeMusic(for itemID: String) async throws -> ThemeMusic? {
            calls += 1
            if delaysFirst && calls == 1 {
                return await withCheckedContinuation { pending = $0 }
            }
            return try theme()
        }
        func finish() {
            guard let pending else { return }
            self.pending = nil
            do { pending.resume(returning: try theme()) }
            catch { XCTFail("Invalid test theme: \(error)"); pending.resume(returning: nil) }
        }
        private func theme() throws -> ThemeMusic {
            if let publicThemeURL {
                return ThemeMusic(
                    itemID: "series",
                    playbackSource: .publicURL(try SecretFreeURLSource(url: publicThemeURL))
                )
            }
            return ThemeMusic(
                itemID: "series",
                playbackSource: .authenticatedHTTP(try AuthenticatedHTTPPlaybackLocator(
                    provider: .jellyfin, accountID: "account", credentialRevision: .init(rawValue: UUID()),
                    itemID: "theme", deliveryMode: .directFile, purpose: .themeMusic,
                    resource: AuthenticatedHTTPResource(pathBase: .serverRoot, path: "/theme")
                ))
            )
        }
        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            MediaPage(items: [], startIndex: 0, totalCount: 0)
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    final class QueuedItemRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var queued = 0

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return queued
        }

        func record() {
            lock.lock()
            defer { lock.unlock() }
            queued += 1
        }
    }
}
#endif
