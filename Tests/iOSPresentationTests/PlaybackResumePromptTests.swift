import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI
import UIKit
import XCTest
@testable import AppShelliOS

@MainActor
final class PlaybackResumePromptTests: XCTestCase {
    func testEpisodeHeroRequestKeepsResumeWhenDetailSourcesDescribeItsShow() {
        let suite = "PlaybackResumePromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = VersionPreferenceStore(defaults: defaults)
        let episode = MediaItem(
            id: "episode", title: "Episode", kind: .episode, seriesID: "show",
            runtime: 3_000, resumePosition: 867, playedPercentage: 0.289,
            sourceAccountID: "jellyfin",
            versions: [MediaVersion(id: "episode-file", height: 1080)]
        )
        let sources = [
            MediaSourceRef(accountID: "jellyfin", itemID: "show", kind: .series),
            MediaSourceRef(accountID: "plex", itemID: "other-show", kind: .series)
        ]
        let capabilities = MediaCapabilities.detected()
        let source = DetailPlaybackSelection.preferredSource(
            sourceOverride: nil, libraryOrigin: nil,
            itemSourceAccountID: episode.sourceAccountID,
            sources: sources, capabilities: capabilities
        )
        let versions = DetailPlaybackSelection.versions(
            for: episode, sources: sources, activeAccountID: source?.accountID
        )
        let versionID = DetailPlaybackSelection.preferredVersionID(
            for: episode, versions: versions, versionOverride: nil,
            preferences: preferences, capabilities: capabilities
        )
        let selected = DetailPlaybackSelection.playItem(
            for: episode, sources: sources, activeAccountID: source?.accountID,
            versionID: versionID, explicit: false
        )
        let playable = PlaybackSourceSelection.bestPlayItem(
            selected, accounts: [], identitySources: { _ in sources }
        )
        let request = PlozziOSPlaybackRequest(
            item: playable, startPosition: playable.resumePosition ?? 0,
            versionPreferences: preferences
        )
        XCTAssertEqual(request.item.id, episode.id)
        XCTAssertEqual(request.item.sourceAccountID, episode.sourceAccountID)
        XCTAssertEqual(request.startPosition, 867)
        XCTAssertTrue(PlaybackSettings(askBeforeResuming: true)
            .shouldAskBeforeResuming(at: request.startPosition))
    }

    func testRestartChangesOnlyThePendingRequestsPosition() {
        let suite = "PlaybackResumePromptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = MediaItem(
            id: "episode", title: "Episode", kind: .episode,
            resumePosition: 120, sourceAccountID: "source"
        )
        let request = PlozziOSPlaybackRequest(
            item: item, startPosition: 120,
            versionPreferences: VersionPreferenceStore(defaults: defaults)
        )
        var restart = request
        restart.startPosition = 0
        XCTAssertEqual(restart.id, request.id)
        XCTAssertEqual(restart.item, request.item)
        XCTAssertEqual(restart.item.sourceAccountID, "source")
        XCTAssertEqual(restart.startPosition, 0)
        XCTAssertEqual(request.startPosition, 120)
        XCTAssertFalse(PlaybackSettings(askBeforeResuming: true)
            .shouldAskBeforeResuming(at: restart.startPosition))
    }

    func testNativePromptPresentsResumeRestartAndCancelWithoutStartingPlayback() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = ResumePromptState()
        let host = UIHostingController(rootView: ResumePromptFixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(150))
        state.item = MediaItem(id: "movie", title: "Movie", kind: .movie, resumePosition: 120)
        let deadline = ContinuousClock.now + .seconds(3)
        while host.presentedViewController == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let dialog = try XCTUnwrap(host.presentedViewController as? UIAlertController)
        XCTAssertEqual(dialog.title, "Movie")
        XCTAssertEqual(dialog.actions.map(\.title), ["Resume", "Start Over", "Cancel"])
        XCTAssertNil(state.chosenPosition)
        state.item = nil
        let dismissDeadline = ContinuousClock.now + .seconds(3)
        while host.presentedViewController != nil, ContinuousClock.now < dismissDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host.presentedViewController)
        XCTAssertNil(state.chosenPosition, "Dismissing the prompt must not start playback.")
    }
}

@MainActor
@Observable
private final class ResumePromptState {
    var item: MediaItem?
    var chosenPosition: TimeInterval?
}

private struct ResumePromptFixture: View {
    @Bindable var state: ResumePromptState

    var body: some View {
        Text("Fixture")
            .resumePrompt(item: $state.item) { _, position in
                state.chosenPosition = position
            }
            .environment(\.locale, Locale(identifier: "en"))
    }
}
