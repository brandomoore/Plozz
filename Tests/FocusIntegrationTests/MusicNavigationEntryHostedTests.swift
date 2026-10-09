@testable import AppShell
import CoreModels
import CoreUI
@testable import FeatureMusic
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicNavigationEntryHostedTests: XCTestCase {
    func testRecentlyPlayedWinsOverBrowseForEveryCardStyle() async throws {
        for style in CardFocusStyle.allCases {
            let fixture = try await makeFixture(style: style, recents: true)
            defer { fixture.close() }
            fixture.state.request = 1
            try await waitUntil { fixture.state.completed }
            try assertFirstRegionFocused(.content, in: fixture)
        }
    }

    func testNoRecentsEntersPlaylistsForEveryCardStyle() async throws {
        for style in CardFocusStyle.allCases {
            let fixture = try await makeFixture(style: style, recents: false)
            defer { fixture.close() }
            fixture.state.request = 1
            try await waitUntil { fixture.state.completed }
            try assertFirstRegionFocused(.fallback, in: fixture)
        }
    }

    func testPendingEntryWakesWhenContentIsReady() async throws {
        let fixture = try await makeFixture(style: .system, recents: true, pending: true)
        defer { fixture.close() }
        let previous = UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem
        fixture.state.request = 1
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fixture.state.completed)
        XCTAssertTrue(UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem === previous)
        fixture.state.pending = false
        try await waitUntil { fixture.state.completed }
        try assertFirstRegionFocused(.content, in: fixture)
    }

    func testCancelledPendingEntryDoesNotWake() async throws {
        let fixture = try await makeFixture(style: .system, recents: true, pending: true)
        defer { fixture.close() }
        fixture.state.request = 1
        try await Task.sleep(for: .milliseconds(100))
        fixture.state.request = nil
        fixture.state.pending = false
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fixture.state.completed)
    }

    private func makeFixture(
        style: CardFocusStyle, recents: Bool, pending: Bool = false
    ) async throws -> Fixture {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("music-entry-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: cacheDirectory.path) {
                try FileManager.default.removeItem(at: cacheDirectory)
            }
        }
        let cache = MusicLandingCache(directory: cacheDirectory)
        let albums = [
            MusicAlbum(id: "first", title: "First album"),
            MusicAlbum(id: "second", title: "Second album")
        ]
        await cache.store(
            .init(recentlyPlayed: recents ? albums.map { .album($0) } : [], albums: albums),
            for: MusicLandingCache.key(visibleLibraryIDs: [:])
        )
        let model = MusicLandingViewModel(context: MusicContext(accounts: []), cache: cache)
        await model.load()
        let state = EntryState()
        state.pending = pending
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: EntryRoot(
            model: model, controller: AudioPlaybackController(), state: state
        ).environment(\.plozzCardFocusStyle, style))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let fixture = Fixture(window: window, state: state)
        do {
            try await waitUntil {
                self.regions(in: window).contains { $0.preference == (recents ? .content : .fallback) }
            }
            window.layoutIfNeeded()
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func assertFirstRegionFocused(
        _ preference: NavigationEntryFocusPreference, in fixture: Fixture,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(fixture.state.didFocus, file: file, line: line)
        let target = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window)?.focusedItem)
        let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: target, relativeTo: fixture.window))
        let first = try XCTUnwrap(regions(in: fixture.window)
            .filter { $0.preference == preference }
            .min { $0.convert($0.bounds, to: fixture.window).minX < $1.convert($1.bounds, to: fixture.window).minX })
        XCTAssertTrue(
            first.convert(first.bounds, to: fixture.window).contains(CGPoint(x: frame.midX, y: frame.midY)),
            "The first declared \(preference) item must receive native focus, not Artists or another header.",
            file: file, line: line
        )
    }

    private func regions(in view: UIView) -> [NavigationEntryFocusRegionView] {
        (view as? NavigationEntryFocusRegionView).map { [$0] } ?? view.subviews.flatMap { regions(in: $0) }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }

    private struct Fixture {
        let window: UIWindow
        let state: EntryState

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @Observable
    final class EntryState {
        var request: UInt64?
        var pending = false
        var completed = false
        var didFocus = false
    }

    private struct EntryRoot: View {
        let model: MusicLandingViewModel
        let controller: AudioPlaybackController
        let state: EntryState

        var body: some View {
            NavigationRailFocusHost { _ in
                NavigationStack {
                    MusicLandingView(
                        viewModel: model, controller: controller,
                        onSelectRoute: { _ in }, onPlayTrack: { _ in }
                    )
                }
                .overlay(alignment: .leading) {
                    // The expanded rail overlaps the leading controls, but has a different native owner.
                    NavigationRowFocusRequester(request: nil) { _, _ in }
                        .frame(width: 520)
                }
                .navigationEntryFocus(state.pending ? .pending : nil)
                .background {
                    NavigationContentFocusRequester(request: state.request) { _, success in
                        state.didFocus = success
                        state.completed = true
                        state.request = nil
                    }
                }
            }
        }
    }
}
