#if os(tvOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import XCTest
@testable import AppShell

@MainActor
final class NavigationStartupFocusHostedTests: XCTestCase {
    func testReadyAndDelayedPagesEnterTheirFirstItemAcrossAllStyles() async throws {
        for style in NavigationStyle.allCases {
            for delayed in [false, true] {
                try await exercise(style: style, delayed: delayed, empty: false)
            }
        }
    }

    func testEmptyPagesEnterRecoveryAcrossAllStyles() async throws {
        for style in NavigationStyle.allCases {
            try await exercise(style: style, delayed: true, empty: true)
        }
    }

    func testInputWhileLoadingCancelsStartupAcrossAllStyles() async throws {
        for style in NavigationStyle.allCases {
            try await exercise(style: style, delayed: true, empty: false, cancelled: true)
        }
    }

    func testInputBeforePresentationCancelsStartupOnce() {
        let view = NavigationContentFocusRequester.RequestView()
        var cancellations = 0
        view.onStartupCancelled = { cancellations += 1 }
        view.isStartupRequest = true
        let gesture = UITapGestureRecognizer()
        XCTAssertFalse(view.gestureRecognizer(gesture, shouldReceive: StartupPress()))
        XCTAssertFalse(view.gestureRecognizer(gesture, shouldReceive: StartupPress()))
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(view.isStartupRequest)
    }

    private func exercise(
        style: NavigationStyle, delayed: Bool, empty: Bool, cancelled: Bool = false
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let model = Model()
        model.ready = !delayed
        model.empty = empty
        let host = UIHostingController(rootView: Fixture(style: style, model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        if delayed {
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertFalse(model.first?.isFocused == true)
            if cancelled {
                let request = try XCTUnwrap(requestViews(in: window).first { $0.request != nil })
                let source = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                XCTAssertFalse(request.gestureRecognizer(UITapGestureRecognizer(), shouldReceive: StartupPress()))
                model.ready = true
                try await Task.sleep(for: .milliseconds(500))
                XCTAssertNil(request.request)
                XCTAssertTrue(UIFocusSystem.focusSystem(for: window)?.focusedItem === source)
                return
            }
            model.ready = true
        }
        try await waitUntil {
            if empty {
                let item = UIFocusSystem.focusSystem(for: window)?.focusedItem
                return self.regions(in: window).contains {
                    $0.preference == .fallback && NativeFocusRegion.contains(item, in: $0)
                }
            }
            return model.first?.isFocused == true
        }
        guard !empty else { return }
        let second = try XCTUnwrap(model.second)
        let owner = try XCTUnwrap(NavigationRailFocusHostController.containing(second))
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        XCTAssertTrue(owner.requestFocus(to: second, using: system))
        model.revision += 1
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(second.isFocused, "\(style) must not repeat startup focus after a content refresh.")
    }

    private func regions(in view: UIView) -> [NavigationEntryFocusRegionView] {
        ((view as? NavigationEntryFocusRegionView).map { [$0] } ?? [])
            + view.subviews.flatMap { regions(in: $0) }
    }

    private func requestViews(in view: UIView) -> [NavigationContentFocusRequester.RequestView] {
        ((view as? NavigationContentFocusRequester.RequestView).map { [$0] } ?? [])
            + view.subviews.flatMap { requestViews(in: $0) }
    }

    private final class StartupPress: UIPress {
        override var type: UIPress.PressType { .rightArrow }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Startup must enter the first real page target without remote input.")
    }

    @Observable
    final class Model {
        var ready = false
        var empty = false
        var revision = 0
        var selection = NavigationRailDestination.home
        let handoff = NavigationDestinationFocusHandoff()
        let chrome = NavigationChromeModel()
        @ObservationIgnored var first: UIButton?
        @ObservationIgnored var second: UIButton?
    }

    private struct Fixture: View {
        let style: NavigationStyle
        @Bindable var model: Model

        var body: some View {
            Group {
                switch style {
                case .rail:
                    NavigationRailShell(
                        profile: Profile(name: "Viewer"), entries: [], destinations: [.home, .search],
                        selection: $model.selection, onOpenProfileSwitcher: {}, chrome: model.chrome,
                        content: page, contentDestination: model.selection
                    )
                case .tabBar:
                    TopBarNavigation(
                        destinations: [.home, .search], selection: $model.selection,
                        preventsAccidentalExit: false, content: { _, _ in AnyView(page) },
                        label: { AnyView(Text(verbatim: $0.storageValue)) }, chrome: model.chrome
                    )
                case .sidebar:
                    NativeSidebarNavigation(
                        selection: model.selection, handoff: model.handoff,
                        content: TabView(selection: $model.selection) {
                            Tab("Home", systemImage: "house", value: NavigationRailDestination.home) {
                                NativeSidebarFocusDestination(
                                    destination: .home, selection: model.selection,
                                    handoff: model.handoff, content: page
                                )
                            }
                            Tab("Search", systemImage: "magnifyingglass", value: NavigationRailDestination.search) {
                                Button("Search content") {}
                            }
                        }.tabViewStyle(.sidebarAdaptable)
                    )
                }
            }
            .environment(\.plozzNavigationStyle, style)
        }

        private var page: some View {
            ContentStateView(
                state: model.ready ? (model.empty ? LoadState<Int>.empty : .loaded(model.revision)) : .loading,
                onRetry: {}
            ) { _ in
                HStack(spacing: 60) {
                    Target(title: "First", model: model, isFirst: true)
                    Target(title: "Second", model: model, isFirst: false)
                }
                .frame(width: 700, height: 150)
                .navigationEntryFocus(.content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationEntryFocus(.fallback)
        }
    }

    private struct Target: UIViewRepresentable {
        let title: String
        let model: Model
        let isFirst: Bool

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            if isFirst { model.first = button } else { model.second = button }
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            button.isEnabled = context.environment.isEnabled
        }
    }
}
#endif
