#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import XCTest
@testable import FeatureHomeCore

@MainActor
final class ThemeMusicControllerTests: XCTestCase {
    func testDetailMutePreservesPlayerVolumeAndSurvivesInactivity() async throws {
        let controller = ThemeMusicController()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-mute-\(UUID()).wav")
        try ThemeMusicPreviewSample.data().write(to: url)
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let owner = UUID()
        let settings = ThemeMusicSettings(isEnabled: true, volume: .low)
        let theme = ThemeMusic(
            itemID: "movie",
            playbackSource: .publicURL(try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!))
        )
        controller.setAuthorization("scope")
        XCTAssertTrue(controller.claimDetail(owner: owner, playbackID: "account:movie", authorizationID: "scope"))
        controller.play(theme, resolvedURL: url, playbackID: "account:movie", owner: owner,
                        authorizationID: "scope", settings: settings)
        let item = try XCTUnwrap(controller.player.currentItem)
        let initialVolume = controller.player.volume
        controller.toggleMuted()
        XCTAssertTrue(controller.isMuted)
        XCTAssertTrue(controller.player.isMuted)
        XCTAssertEqual(controller.player.volume, initialVolume)
        controller.updateVolume(.high)
        try await waitUntil { controller.player.currentTime().seconds > 0.1 }
        XCTAssertTrue(controller.player.isMuted, "Fade-in and volume updates must not undo mute.")
        controller.setAppActive(false)
        controller.setAppActive(true)
        XCTAssertTrue(controller.isMuted)
        XCTAssertTrue(controller.player.currentItem === item)
        let fadedVolume = controller.player.volume
        controller.toggleMuted()
        XCTAssertFalse(controller.isMuted)
        XCTAssertFalse(controller.player.isMuted)
        XCTAssertEqual(controller.player.volume, fadedVolume)
        XCTAssertTrue(controller.player.currentItem === item, "Mute must not restart or resolve the source.")
        XCTAssertEqual(settings.volume, .low, "The persisted volume is independent of the live mute.")
        controller.toggleMuted()
        controller.setAuthorization("replacement-scope")
        XCTAssertFalse(controller.isMuted, "Mute belongs to the current detail playback, not another profile.")
        XCTAssertNil(controller.player.currentItem)
    }

    func testSettingsPreviewDoesNotInheritDetailMute() async throws {
        let controller = ThemeMusicController()
        defer { controller.stop() }
        controller.setAuthorization("scope")
        XCTAssertTrue(controller.claimDetail(owner: UUID(), playbackID: "account:movie", authorizationID: "scope"))
        controller.toggleMuted()
        await controller.preview(owner: UUID(), volume: .low, resolve: { nil }, authenticatedHTTPResolver: nil)
        XCTAssertTrue(controller.isPreviewing)
        XCTAssertFalse(controller.isMuted)
        XCTAssertFalse(controller.player.isMuted)
    }

    func testGeneratedSampleIsBoundedAudiblePCMWithoutClipping() throws {
        let data = ThemeMusicPreviewSample.data()
        XCTAssertEqual(String(data: data.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(data.count, 44 + 22_050 * 8 * 2)
        var peak = 0
        for offset in stride(from: 44, to: data.count, by: 2) {
            let bits = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            peak = max(peak, abs(Int(Int16(bitPattern: bits))))
        }
        XCTAssertGreaterThan(peak, 10_000)
        XCTAssertLessThan(peak, Int(Int16.max))
    }

    func testPreviewUsesFullSelectedGainAndCleansUpItsSample() async throws {
        let controller = ThemeMusicController()
        controller.player.isMuted = true
        defer { controller.stop() }
        let owner = UUID()
        await controller.preview(
            owner: owner, volume: ThemeMusicVolume(1), resolve: { nil },
            authenticatedHTTPResolver: nil
        )
        XCTAssertEqual(controller.previewOwner, owner)
        XCTAssertEqual(controller.player.volume, 1)
        let asset = try XCTUnwrap(controller.player.currentItem?.asset as? AVURLAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        controller.updateVolume(ThemeMusicVolume(0.01))
        XCTAssertEqual(controller.player.volume, 0.01)
        XCTAssertTrue(controller.player.currentItem?.asset === asset)
        controller.stopPreview(owner: owner)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.url.path))
    }

    func testInactiveAppStopsPreviewAndDoesNotAutoResumeIt() async {
        let controller = ThemeMusicController()
        controller.player.isMuted = true
        await controller.preview(
            owner: UUID(), volume: .low, resolve: { nil }, authenticatedHTTPResolver: nil
        )
        controller.setAppActive(false)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertFalse(controller.isPreviewing)
        XCTAssertNil(controller.player.currentItem)
        controller.setAppActive(true)
        XCTAssertNil(controller.currentPlaybackID)
        XCTAssertNil(controller.player.currentItem)
    }

    func testDetailRetainsItemAndPositionWhenAppBecomesInactive() async throws {
        let controller = ThemeMusicController()
        controller.player.isMuted = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-lifecycle-\(UUID().uuidString).wav")
        try ThemeMusicPreviewSample.data().write(to: url)
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let source = try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!)
        let theme = ThemeMusic(itemID: "movie", playbackSource: .publicURL(source))
        let owner = UUID()
        controller.setAuthorization("profile:account:revision")
        XCTAssertTrue(controller.claimDetail(owner: owner, playbackID: "account:movie",
                                            authorizationID: "profile:account:revision"))
        controller.play(theme, resolvedURL: url, playbackID: "account:movie",
                        owner: owner, authorizationID: "profile:account:revision",
                        settings: ThemeMusicSettings(isEnabled: true))
        try await waitUntil { controller.player.currentTime().seconds > 0.1 }
        let item = try XCTUnwrap(controller.player.currentItem)
        controller.setAppActive(false)
        try await waitUntil { !controller.isPlaying }
        let pausedTime = controller.player.currentTime().seconds
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertEqual(controller.currentPlaybackID, "account:movie")
        XCTAssertTrue(controller.player.currentItem === item)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.player.currentTime().seconds, pausedTime, accuracy: 0.05)
        controller.setAppActive(true)
        try await waitUntil { controller.player.currentTime().seconds > pausedTime + 0.05 }
        XCTAssertTrue(controller.player.currentItem === item)
        controller.updateVolume(ThemeMusicVolume(1))
        XCTAssertTrue(controller.player.currentItem === item)
    }

    func testLeavingDetailFadesBeforeReleasingItemAndRejectsLateResolution() async throws {
        try await withPlayingDetail { controller, theme, url, owner in
            let item = try XCTUnwrap(controller.player.currentItem)
            let startingVolume = controller.player.volume
            let start = ContinuousClock.now
            controller.stopDetail(owner: owner, fadingOut: true)
            XCTAssertNil(controller.detailOwner)
            XCTAssertNil(controller.currentPlaybackID)
            XCTAssertTrue(controller.isPlaying)
            XCTAssertTrue(controller.player.currentItem === item)
            XCTAssertEqual(controller.player.volume, startingVolume)
            controller.play(theme, resolvedURL: url, playbackID: "account:movie", owner: owner,
                            authorizationID: "scope", settings: ThemeMusicSettings(isEnabled: true))
            controller.updateVolume(.high)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(controller.player.currentItem === item)
            XCTAssertGreaterThan(controller.player.volume, 0)
            XCTAssertLessThan(controller.player.volume, startingVolume * 0.9)
            controller.fadeOutAndStop()
            XCTAssertTrue(controller.player.currentItem === item, "Duplicate exit signals must not cut the fade short.")
            try await self.waitUntil { controller.player.currentItem == nil }
            XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(700))
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            XCTAssertEqual(controller.player.volume, 0)
            XCTAssertFalse(controller.isPlaying)
        }
    }

    func testInactivityFadesBeforePausingAndResumesFromSilence() async throws {
        try await withPlayingDetail { controller, _, _, owner in
            let item = try XCTUnwrap(controller.player.currentItem)
            let startingVolume = controller.player.volume
            controller.setAppActive(false)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(controller.isPlaying)
            XCTAssertGreaterThan(controller.player.rate, 0)
            XCTAssertGreaterThan(controller.player.volume, 0)
            XCTAssertLessThan(controller.player.volume, startingVolume * 0.9)
            controller.setAppActive(false)
            try await self.waitUntil { !controller.isPlaying }
            let pausedTime = controller.player.currentTime().seconds
            XCTAssertEqual(controller.player.volume, 0)
            XCTAssertEqual(controller.player.rate, 0)
            XCTAssertEqual(controller.detailOwner, owner)
            XCTAssertEqual(controller.currentPlaybackID, "account:movie")
            XCTAssertTrue(controller.player.currentItem === item)
            controller.setAppActive(true)
            XCTAssertEqual(controller.player.volume, 0)
            try await self.waitUntil { controller.player.currentTime().seconds > pausedTime + 0.1 }
            XCTAssertGreaterThan(controller.player.volume, 0)
            XCTAssertTrue(controller.player.currentItem === item)
        }
    }

    func testQuickForegroundReturnCancelsPauseWithoutVolumeJumpOrDelayedStop() async throws {
        try await withPlayingDetail { controller, _, _, _ in
            let item = try XCTUnwrap(controller.player.currentItem)
            controller.setAppActive(false)
            try await Task.sleep(for: .milliseconds(200))
            let fadedVolume = controller.player.volume
            controller.setAppActive(true)
            XCTAssertEqual(controller.player.volume, fadedVolume)
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(controller.isPlaying)
            XCTAssertGreaterThan(controller.player.rate, 0)
            XCTAssertGreaterThan(controller.player.volume, fadedVolume)
            XCTAssertTrue(controller.player.currentItem === item)
        }
    }

    func testReplacementDetailCannotBeStoppedByOutgoingFade() async throws {
        try await withPlayingDetail { controller, theme, url, owner in
            controller.stopDetail(owner: owner, fadingOut: true)
            try await Task.sleep(for: .milliseconds(100))
            let replacement = UUID()
            XCTAssertTrue(controller.claimDetail(owner: replacement, playbackID: "account:other",
                                                authorizationID: "scope"))
            controller.play(theme, resolvedURL: url, playbackID: "account:other", owner: replacement,
                            authorizationID: "scope", settings: ThemeMusicSettings(isEnabled: true))
            controller.stopDetail(owner: owner, fadingOut: true)
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(controller.detailOwner, replacement)
            XCTAssertEqual(controller.currentPlaybackID, "account:other")
            XCTAssertNotNil(controller.player.currentItem)
            XCTAssertGreaterThan(controller.player.rate, 0)
        }
    }

    func testAuthorizationAndPlaybackSuppressionCancelOutgoingFadeImmediately() async throws {
        try await withPlayingDetail { controller, _, _, owner in
            controller.stopDetail(owner: owner, fadingOut: true)
            XCTAssertNotNil(controller.player.currentItem)
            controller.setAuthorization("new-scope")
            XCTAssertNil(controller.player.currentItem)
            XCTAssertFalse(controller.isPlaying)
        }
        try await withPlayingDetail { controller, _, _, owner in
            controller.stopDetail(owner: owner, fadingOut: true)
            controller.setBlocked(true)
            XCTAssertNil(controller.player.currentItem)
            XCTAssertFalse(controller.isPlaying)
        }
    }

    func testInterruptionPausesImmediatelyDuringInactivityFade() async throws {
        try await withPlayingDetail { controller, _, _, _ in
            let item = try XCTUnwrap(controller.player.currentItem)
            controller.setAppActive(false)
            controller.setInterrupted(true)
            XCTAssertEqual(controller.player.rate, 0)
            XCTAssertFalse(controller.isPlaying)
            controller.setAppActive(true)
            XCTAssertEqual(controller.player.rate, 0)
            controller.setInterrupted(false)
            try await Task.sleep(for: .seconds(1))
            XCTAssertTrue(controller.isPlaying)
            XCTAssertGreaterThan(controller.player.rate, 0)
            XCTAssertTrue(controller.player.currentItem === item)
        }
    }

    func testLeavingDetailDuringInactivityFadeReleasesRatherThanRetainsItem() async throws {
        try await withPlayingDetail { controller, _, _, owner in
            controller.setAppActive(false)
            try await Task.sleep(for: .milliseconds(100))
            controller.stopDetail(owner: owner, fadingOut: true)
            XCTAssertNotNil(controller.player.currentItem)
            try await self.waitUntil { controller.player.currentItem == nil }
            controller.setAppActive(true)
            XCTAssertNil(controller.currentPlaybackID)
            XCTAssertFalse(controller.isPlaying)
        }
    }

    private func withPlayingDetail(
        _ body: (ThemeMusicController, ThemeMusic, URL, UUID) async throws -> Void
    ) async throws {
        let controller = ThemeMusicController()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("theme-fade-\(UUID()).wav")
        try ThemeMusicPreviewSample.data().write(to: url)
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: url)
        }
        let owner = UUID()
        let theme = ThemeMusic(
            itemID: "movie",
            playbackSource: .publicURL(try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!))
        )
        controller.setAuthorization("scope")
        XCTAssertTrue(controller.claimDetail(owner: owner, playbackID: "account:movie", authorizationID: "scope"))
        controller.play(theme, resolvedURL: url, playbackID: "account:movie", owner: owner,
                        authorizationID: "scope", settings: ThemeMusicSettings(isEnabled: true))
        controller.player.isMuted = true
        try await waitUntil { controller.player.volume > 0.01 && controller.player.currentTime().seconds > 0.1 }
        try await body(controller, theme, url, owner)
    }

    func testCoveredPageWithSameMediaIDCannotReleaseForegroundOwner() throws {
        let controller = ThemeMusicController()
        defer { controller.stop() }
        let ancestor = UUID()
        let foreground = UUID()
        let url = URL(fileURLWithPath: "/unused-same-title-theme.wav")
        let source = try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!)
        let theme = ThemeMusic(itemID: "series", playbackSource: .publicURL(source))
        controller.setAuthorization("scope")
        XCTAssertTrue(controller.claimDetail(owner: ancestor, playbackID: "account:series", authorizationID: "scope"))
        XCTAssertTrue(controller.claimDetail(owner: foreground, playbackID: "account:series", authorizationID: "scope"))
        controller.play(theme, resolvedURL: url, playbackID: "account:series", owner: foreground,
                        authorizationID: "scope", settings: ThemeMusicSettings(isEnabled: true))
        let item = try XCTUnwrap(controller.player.currentItem)
        controller.setAppActive(false)
        controller.stopDetail(owner: ancestor)
        XCTAssertEqual(controller.detailOwner, foreground)
        XCTAssertEqual(controller.currentPlaybackID, "account:series")
        XCTAssertTrue(controller.player.currentItem === item)
    }

    func testOldOwnerAndOldAuthorizationCannotPublishDelayedTheme() throws {
        let controller = ThemeMusicController()
        defer { controller.stop() }
        let owner = UUID()
        let url = URL(fileURLWithPath: "/unused-stale-theme.wav")
        let source = try SecretFreeURLSource(url: URL(string: "https://example.test/theme.mp3")!)
        let theme = ThemeMusic(itemID: "movie", playbackSource: .publicURL(source))
        controller.setAuthorization("old-scope")
        XCTAssertTrue(controller.claimDetail(owner: owner, playbackID: "account:movie", authorizationID: "old-scope"))
        controller.setAuthorization("new-scope")
        controller.play(theme, resolvedURL: url, playbackID: "account:movie", owner: owner,
                        authorizationID: "old-scope", settings: ThemeMusicSettings(isEnabled: true))
        XCTAssertNil(controller.currentPlaybackID)
        XCTAssertNil(controller.player.currentItem)
        XCTAssertNil(controller.detailOwner)
        XCTAssertFalse(controller.claimDetail(owner: owner, playbackID: "account:movie", authorizationID: "old-scope"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }

    func testBlockedOrInactivePreviewDoesNotResolveAnything() async {
        let controller = ThemeMusicController()
        controller.setBlocked(true)
        await controller.preview(
            owner: UUID(), volume: .high,
            resolve: { XCTFail("Blocked preview cannot access a provider"); return nil },
            authenticatedHTTPResolver: nil
        )
        controller.setBlocked(false)
        controller.setAppActive(false)
        await controller.preview(
            owner: UUID(), volume: .high,
            resolve: { XCTFail("Background preview cannot access a provider"); return nil },
            authenticatedHTTPResolver: nil
        )
        XCTAssertNil(controller.player.currentItem)
    }

    func testPendingResolutionCannotRevivePreviewAfterLeavingApp() async {
        let controller = ThemeMusicController()
        let gate = ThemePreviewGate()
        let task = Task {
            await controller.preview(
                owner: UUID(), volume: .low, resolve: { await gate.resolve() },
                authenticatedHTTPResolver: nil
            )
        }
        await gate.waitUntilStarted()
        controller.setAppActive(false)
        controller.setAppActive(true)
        await gate.finish()
        await task.value
        XCTAssertNil(controller.previewOwner)
        XCTAssertNil(controller.player.currentItem)
    }

    func testVolumeChangedDuringLookupIsUsedWhenPreviewStarts() async {
        let controller = ThemeMusicController()
        controller.player.isMuted = true
        defer { controller.stop() }
        let gate = ThemePreviewGate()
        let task = Task {
            await controller.preview(
                owner: UUID(), volume: .low, resolve: { await gate.resolve() },
                authenticatedHTTPResolver: nil
            )
        }
        await gate.waitUntilStarted()
        controller.updateVolume(ThemeMusicVolume(0.82))
        await gate.finish()
        await task.value
        XCTAssertEqual(controller.player.volume, 0.82)
    }

    func testOldOwnerAndCancelledLookupCannotStopReplacementPreview() async {
        let controller = ThemeMusicController()
        controller.player.isMuted = true
        defer { controller.stop() }
        let oldOwner = UUID()
        let newOwner = UUID()
        let gate = ThemePreviewGate()
        let oldTask = Task {
            await controller.preview(
                owner: oldOwner, volume: .low, resolve: { await gate.resolve() },
                authenticatedHTTPResolver: nil
            )
        }
        await gate.waitUntilStarted()
        oldTask.cancel()
        await controller.preview(
            owner: newOwner, volume: .high, resolve: { nil }, authenticatedHTTPResolver: nil
        )
        let item = controller.player.currentItem
        controller.stopPreview(owner: oldOwner)
        await gate.finish()
        await oldTask.value
        XCTAssertEqual(controller.previewOwner, newOwner)
        XCTAssertTrue(controller.player.currentItem === item)
    }

    func testPreviewLookupErrorIsVisibleAndDoesNotGenerateSuccessFallback() async {
        let controller = ThemeMusicController()
        await controller.preview(
            owner: UUID(), volume: .low, resolve: { throw AppError.serverUnreachable },
            authenticatedHTTPResolver: nil
        )
        XCTAssertNotNil(controller.failure)
        XCTAssertNil(controller.previewOwner)
        XCTAssertNil(controller.player.currentItem)
    }
}

private actor ThemePreviewGate {
    private var continuation: CheckedContinuation<ThemeMusic?, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func resolve() async -> ThemeMusic? {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
#endif
