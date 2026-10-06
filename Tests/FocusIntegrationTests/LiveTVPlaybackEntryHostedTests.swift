import CoreModels
import CoreUI
import FeatureLiveTVCore
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import FeatureLiveTV

@MainActor
final class LiveTVPlaybackEntryHostedTests: XCTestCase {
    func testPreviewStartsAfterDestinationAndSceneBecomeActive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = PlaybackEntryProbe()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PlaybackEntryFixture(probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        probe.active = true
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertNil(probe.input, "Inactive scenes must not auto-preview")
        probe.phase = .active
        let deadline = ContinuousClock.now + .seconds(5)
        while probe.input == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let input = try XCTUnwrap(probe.input, "A visible, focused guide must begin preview after activation")
        XCTAssertFalse(input.isExpanded)
        XCTAssertTrue(input.isPlaybackActive)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
    }

    func testUnlockStartsPreviewAndAllowsExplicitWatch() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = PlaybackEntryProbe()
        probe.active = true
        probe.phase = .active
        probe.authorized = false
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: PlaybackEntryFixture(probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(1_000))
        XCTAssertNil(probe.input, "Locked profiles must not preview")
        probe.authorized = true
        var deadline = ContinuousClock.now + .seconds(5)
        while probe.input == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let input = try XCTUnwrap(probe.input, "Unlocking must restore preview availability")
        XCTAssertTrue(input.isAuthorized)
        XCTAssertTrue(input.isPlaybackActive)
        XCTAssertFalse(input.isExpanded)
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)

        // The player guide and the main guide both use LiveTVPrototypeView.tune.
        input.tuneChannel(input.channel.id)
        deadline = ContinuousClock.now + .seconds(5)
        while probe.input?.isExpanded != true, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let watching = try XCTUnwrap(probe.input)
        XCTAssertTrue(watching.isExpanded)
        XCTAssertTrue(watching.countsAsWatching)
        XCTAssertEqual(watching.channel.id, input.channel.id)
    }
}

@MainActor @Observable
private final class PlaybackEntryProbe {
    var active = false
    var phase = ScenePhase.inactive
    var authorized = true
    var input: LiveTVPrototypePlayback?
    let namespace = "LiveTVPlaybackEntry.\(UUID().uuidString)"
    let sources = PlaybackEntrySources()
    let approval = LiveTVSourceApprovalContext(
        profile: Profile(id: ProfileStore.defaultProfileID, name: "Fixture"),
        parentalPIN: nil, activeAccountIDs: []
    )
}

private struct PlaybackEntryFixture: View {
    let probe: PlaybackEntryProbe

    var body: some View {
        LiveTVPrototypeView(
            isActive: probe.active,
            sourceStore: probe.sources,
            isProfileAuthorized: { probe.authorized },
            sourceLoader: PlaybackEntryLoader(),
            preferencesNamespace: probe.namespace,
            sourceApprovalContext: { probe.approval }
        ) { input in
            Color.black
                .onAppear { probe.input = input }
                .onChange(of: input.isExpanded) { _, _ in probe.input = input }
        }
        .environment(\.scenePhase, probe.phase)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
    }
}

private struct PlaybackEntrySources: LiveTVSourcesStoring {
    func load() throws -> LiveTVSourcesConfiguration {
        LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "fixture", name: "Fixture",
                playlistURL: URL(string: "https://fixture.invalid/list.m3u")!
            )
        ])
    }
    func save(_ configuration: LiveTVSourcesConfiguration) throws {}
}

private struct PlaybackEntryLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        try LiveTVPlaylistParser(baseURL: url).parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="fixture",Fixture channel
        https://fixture.invalid/channel.m3u8
        """)
    }
    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        XCTFail("The fixture has no programme guide")
        throw LiveTVSourceImportError.invalidGuide
    }
}
