#if os(iOS)
@testable import AppShelliOS
import CoreModels
@testable import FeatureMusic
import SwiftUI
import UIKit
import XCTest

@MainActor
final class MusicPlayerContentInsetTests: XCTestCase {
    func testRootAndPushedPagesClearDockAndReleaseSpaceWhenStopped() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1_194)] {
            for kind in ["scroll", "list", "playlist"] {
                for pushed in [false, true] {
                    let state = DockInsetState()
                    window.frame = CGRect(origin: .zero, size: size)
                    let host = UIHostingController(rootView: DockInsetFixture(state: state, kind: kind, pushed: pushed))
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .milliseconds(350))
                    var activeBottom: CGFloat?
                    for (step, change) in [(0, true), (0, false), (1, true), (1, false), (0, true)].enumerated() {
                        let (tab, active) = change
                        state.selection = tab
                        state.active = active
                        try await Task.sleep(for: .milliseconds(400))
                        let selected = try XCTUnwrap(tabController(in: host)?.selectedViewController)
                        let scroll = try XCTUnwrap(scrollViews(in: selected.view).first {
                            $0.window === window && !$0.isHidden && $0.contentSize.height > $0.bounds.height
                        })
                        for _ in 0..<3 {
                            scroll.setContentOffset(
                                CGPoint(x: 0, y: max(-scroll.adjustedContentInset.top,
                                                     scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)),
                                animated: false
                            )
                            try await Task.sleep(for: .milliseconds(80))
                        }
                        let bottom = scroll.convert(
                            CGPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - scroll.adjustedContentInset.bottom),
                            to: window
                        ).y
                        let context = "\(kind), step \(step), tab \(tab), pushed \(pushed), width \(size.width), bottom tabs \(state.hasBottomBar)"
                        if active {
                            let clearY = size.height - BottomBar.contentClearance(hasBottomBar: state.hasBottomBar)
                            XCTAssertLessThanOrEqual(bottom, clearY + 1, "The final content must clear the dock's tap area: \(context)")
                            XCTAssertGreaterThanOrEqual(bottom, clearY - 2, "Do not accumulate duplicate dock insets: \(context)")
                            if kind != "playlist" {
                                let lastRow = try XCTUnwrap(state.lastRows[tab])
                                XCTAssertGreaterThan(lastRow.height, 0, "The actual last row must be mounted")
                                XCTAssertLessThanOrEqual(lastRow.maxY, clearY + 1, "The last row must be fully visible: \(context)")
                            }
                            activeBottom = bottom
                        } else {
                            XCTAssertGreaterThan(bottom, try XCTUnwrap(activeBottom) + 20,
                                                 "Stopping music must remove the reserved space: \(context)")
                        }
                    }
                }
            }
        }
    }

    func testResizingAndRemovalPreserveOtherSafeAreaContributions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = DockInsetState()
        state.active = false
        let host = UIHostingController(rootView: DockInsetFixture(state: state, kind: "scroll", pushed: true))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        let tabs = try XCTUnwrap(tabController(in: host))
        let selected = try XCTUnwrap(tabs.selectedViewController)
        let navigation = try XCTUnwrap(descendant(UINavigationController.self, in: selected))
        navigation.additionalSafeAreaInsets.bottom = 11
        try await Task.sleep(for: .milliseconds(100))
        state.active = true

        for size in [CGSize(width: 390, height: 844), CGSize(width: 834, height: 1_194), CGSize(width: 390, height: 844)] {
            window.frame = CGRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(400))
            let scroll = try XCTUnwrap(scrollViews(in: selected.view).first { $0.window === window })
            let bottom = scroll.convert(
                CGPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - scroll.adjustedContentInset.bottom),
                to: window
            ).y
            XCTAssertEqual(bottom, size.height - BottomBar.contentClearance(hasBottomBar: state.hasBottomBar),
                           accuracy: 2, "Resizing must neither lose nor double the dock reservation")
        }

        state.active = false
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(navigation.additionalSafeAreaInsets.bottom, 11, accuracy: 0.5)
        state.active = true
        try await Task.sleep(for: .milliseconds(400))
        let bridge = try XCTUnwrap(descendant(PlozziOSSettingsTabAction.Controller.self, in: host))
        bridge.restore()
        XCTAssertEqual(navigation.additionalSafeAreaInsets.bottom, 11, accuracy: 0.5)
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let match = controller as? T { return match }
        return controller.children.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    func testOverflowPagesClearDockWithoutMovingNativeBar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let state = DockInsetState()
        let host = UIHostingController(rootView: DockInsetFixture(state: state, kind: "scroll", pushed: true, tabCount: 12))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        let tabs = try XCTUnwrap(tabController(in: host))
        let originalBar = tabs.tabBar.convert(tabs.tabBar.bounds, to: window)
        for tab in [0, 11, 0] {
            state.selection = tab
            try await Task.sleep(for: .milliseconds(600))
            let selected = try XCTUnwrap(tabs.selectedViewController)
            let scroll = try XCTUnwrap(scrollViews(in: selected.view).first {
                $0.window === window && !$0.isHidden && $0.contentSize.height > $0.bounds.height
            })
            let bottom = scroll.convert(
                CGPoint(x: scroll.bounds.midX, y: scroll.bounds.maxY - scroll.adjustedContentInset.bottom),
                to: window
            ).y
            XCTAssertEqual(bottom, window.bounds.height - BottomBar.contentClearance(hasBottomBar: state.hasBottomBar),
                           accuracy: 2, "Overflow destinations must inherit exactly one reservation")
            XCTAssertEqual(tabs.tabBar.convert(tabs.tabBar.bounds, to: window), originalBar)
        }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }
}

@MainActor @Observable
private final class DockInsetState {
    var active = true
    var hasBottomBar = false
    var selection = 0
    var lastRows: [Int: CGRect] = [:]
}

private struct DockInsetFixture: View {
    let state: DockInsetState
    let kind: String
    let pushed: Bool
    var tabCount = 2

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.selection) {
            ForEach(0..<tabCount, id: \.self) { tab in
                NavigationStack(path: .constant(pushed ? [1] : [])) {
                    page(tab: tab)
                        .navigationTitle(tab == 0 ? "Library" : "Search")
                        .navigationDestination(for: Int.self) { _ in page(tab: tab).navigationTitle("Detail") }
                }
                .tabItem { Label(tab == 0 ? "Library" : "Search", systemImage: tab == 0 ? "square.stack" : "magnifyingglass") }
                .tag(tab)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .background {
            PlozziOSSettingsTabAction(
                tabIndex: nil, action: {},
                onBottomBarVisibilityChange: { state.hasBottomBar = $0 },
                reservesMusicDockSpace: state.active
            ).frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private func page(tab: Int) -> some View {
        if kind == "playlist" {
            MobileMusicPlaylistDetail(
                playlist: MusicPlaylist(id: "playlist", title: "Playlist"),
                tracks: (0..<40).map { MusicTrack(id: "\($0)", title: "Song \($0)", duration: 120) },
                nowPlayingTrack: nil, isPlaying: false, onPlay: {}, onShuffle: {}, onPlayTrack: { _ in }
            )
        } else if kind == "list" {
            List { rows(tab: tab) }
        } else {
            ScrollView { LazyVStack { rows(tab: tab) } }
        }
    }

    private func rows(tab: Int) -> some View {
        ForEach(0..<40) { index in
            Button("Item \(index)") {}
                .frame(maxWidth: .infinity, minHeight: 44)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    if index == 39 { state.lastRows[tab] = frame }
                }
        }
    }
}
#endif
