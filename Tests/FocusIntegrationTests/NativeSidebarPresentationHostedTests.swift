import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShell

@MainActor
final class NativeSidebarPresentationHostedTests: XCTestCase {
    func testNativeSidebarDisplaysOfflineStatusAndRemovesItAfterRecovery() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = LibraryStatusModel()
        let host = UIHostingController(rootView: LibraryStatusSidebar(model: model)
            .environment(\.locale, Locale(identifier: "en_US")))
        fixture.window.rootViewController = host
        let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
        for appearance in [UIUserInterfaceStyle.dark, .light] {
            fixture.window.overrideUserInterfaceStyle = appearance
            for offline in [false, true, false] {
                model.isOffline = offline
                try await waitUntil {
                    fixture.window.layoutIfNeeded()
                    focusSystem.requestFocusUpdate(to: host)
                    focusSystem.updateFocusIfNeeded()
                    guard let item = focusSystem.focusedItem,
                          let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: fixture.window)
                    else { return false }
                    return frame.width > 150
                }
                try await Task.sleep(for: .milliseconds(500))
                fixture.window.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                    XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Native sidebar \(appearance == .dark ? "dark" : "light") offline=\(offline)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["Offline"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                XCTAssertTrue(labels.contains { $0.contains("Movies") }, "\(labels)")
                XCTAssertEqual(labels.filter { $0.contains("Offline") }.count, offline ? 2 : 0, "\(labels)")
                XCTAssertEqual(model.selection, "home", "Reachability updates must not select another tab.")
            }
        }
    }

    func testLiveTVWaitsForFirstVisitThenRetainsStateWithinItsProfile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = RetentionModel()
        fixture.window.rootViewController = UIHostingController(rootView: RetainedPage(model: model))
        fixture.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.factoryCalls, 0, "Cold Home must not construct the hidden Live TV runtime or guide.")
        XCTAssertEqual(model.creations, 0)

        model.isActive = true
        try await waitUntil { model.creations == 1 && model.isEnabled }
        let firstView = try XCTUnwrap(model.view)
        let firstState = try XCTUnwrap(model.stateID)
        model.isActive = false
        try await waitUntil { !model.isEnabled }
        XCTAssertTrue(model.view === firstView)
        XCTAssertNotNil(firstView.window)
        model.isActive = true
        try await waitUntil { model.isEnabled }
        XCTAssertEqual(model.creations, 1)
        XCTAssertEqual(model.stateID, firstState)

        model.isActive = false
        try await waitUntil { !model.isEnabled }
        let previousCalls = model.factoryCalls
        model.profileID = "second"
        try await waitUntil { firstView.window == nil }
        fixture.window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.factoryCalls, previousCalls, "A different profile must not inherit a prior visit.")
        XCTAssertEqual(model.creations, 1, "Changing profiles on Home must not mount the new profile's Live TV.")
        model.isActive = true
        try await waitUntil { model.creations == 2 && model.isEnabled }
        XCTAssertFalse(model.view === firstView)
        XCTAssertNotEqual(model.stateID, firstState)
    }

    func testInitiallySelectedLiveTVIsConstructedOnTheFirstLayout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = RetentionModel()
        model.isActive = true
        fixture.window.rootViewController = UIHostingController(rootView: RetainedPage(model: model))
        fixture.window.layoutIfNeeded()
        XCTAssertGreaterThan(model.factoryCalls, 0, "Standalone Live TV must not wait for another navigation event.")
        XCTAssertEqual(model.creations, 1)
        XCTAssertTrue(model.isEnabled)
    }

    func testInactiveAndUnpresentedPagesCannotAcceptFocus() async throws {
        try await exercisePresentation(sharedPinnedHost: false)
    }

    func testDestinationPresentationCompletesInsidePinnedFocusHost() async throws {
        try await exercisePresentation(sharedPinnedHost: true)
    }

    private func exercisePresentation(sharedPinnedHost: Bool) async throws {
        let fixture = try await makeFixture(sharedPinnedHost: sharedPinnedHost)
        defer { fixture.close() }
        try await waitUntil { fixture.model.buttons[.home]?.isFocused == true }
        let inactive = try XCTUnwrap(fixture.model.buttons[.settings])
        XCTAssertFalse(inactive.isEnabled)

        fixture.model.handoff.begin(.settings)
        fixture.model.selection = .settings
        try await waitUntil { fixture.model.buttons[.home]?.isEnabled == false }
        XCTAssertFalse(inactive.isEnabled)
        XCTAssertTrue(fixture.model.handoff.isWaiting)
        XCTAssertEqual(fixture.model.prematureFocusCount, 0)

        fixture.model.mountDestinationAnchor = true
        try await waitUntil {
            !fixture.model.handoff.isWaiting && fixture.model.buttons[.settings]?.isEnabled == true
        }
        XCTAssertFalse(try XCTUnwrap(fixture.model.buttons[.home]).isEnabled)
        XCTAssertEqual(fixture.model.prematureFocusCount, 0)
    }

    private func makeFixture(sharedPinnedHost: Bool = false) async throws -> Fixture {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        return Fixture(scene: scene, sharedPinnedHost: sharedPinnedHost)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(predicate())
    }

    @MainActor
    private final class Fixture {
        let model = Model()
        let window: UIWindow
        let previous: UIWindow?

        init(scene: UIWindowScene, sharedPinnedHost: Bool) {
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = UIHostingController(rootView: Group {
                if sharedPinnedHost {
                    NavigationRailFocusHost { [model] _ in Pages(model: model) }
                        .ignoresSafeArea()
                } else {
                    Pages(model: model)
                }
            })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            model.buttons.removeAll()
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor @Observable
    fileprivate final class LibraryStatusModel {
        var isOffline = false
        var selection = "home"
        let library = AggregatedLibrary(
            accountID: "fixture", accountName: "Fixture", serverName: "Fixture", providerKind: .plex,
            library: MediaLibrary(id: "movies", title: "Movies", kind: .movie)
        )
    }

    private struct LibraryStatusSidebar: View {
        @Bindable var model: LibraryStatusModel

        var body: some View {
            let entries = [
                NavigationRailLibraryEntry(
                    key: model.library.key, library: model.library, isOffline: model.isOffline),
                NavigationRailLibraryEntry(
                    key: NavigationLibraryLayout.allLibrariesKey, library: nil, isOffline: model.isOffline)
            ]
            TabView(selection: $model.selection) {
                Tab(value: "home") {
                    AnyView(Color.clear)
                } label: {
                    AnyView(Label("Home", systemImage: "house"))
                }
                ForEach(entries, id: \.key) { entry in
                    Tab(value: entry.key) {
                        AnyView(Color.clear)
                    } label: {
                        AnyView(MainTabView.navigationLibraryLabel(entry))
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
        }
    }

    @MainActor @Observable
    final class Model {
        var selection = NavigationRailDestination.home
        let handoff = NavigationDestinationFocusHandoff()
        var mountDestinationAnchor = false
        var prematureFocusCount = 0
        @ObservationIgnored var buttons: [NavigationRailDestination: UIButton] = [:]
    }

    @MainActor @Observable
    fileprivate final class RetentionModel {
        var isActive = false
        var profileID = "first"
        @ObservationIgnored var factoryCalls = 0
        @ObservationIgnored var creations = 0
        @ObservationIgnored var isEnabled = false
        @ObservationIgnored var stateID: UUID?
        @ObservationIgnored var view: UIView?
    }

    private struct RetainedPage: View {
        let model: RetentionModel

        var body: some View {
            RetainedLiveTVDestination(isActive: model.isActive) {
                let _ = model.factoryCalls += 1
                RetainedContent(model: model)
            }
            .id(model.profileID)
            .disabled(!model.isActive)
            .opacity(model.isActive ? 1 : 0)
        }
    }

    private struct RetainedContent: View {
        let model: RetentionModel
        @State private var identity = UUID()

        var body: some View {
            RetainedProbe(model: model, identity: identity)
                .frame(width: 300, height: 200)
        }
    }

    private struct RetainedProbe: UIViewRepresentable {
        let model: RetentionModel
        let identity: UUID

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            model.view = view
            model.creations += 1
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            model.isEnabled = context.environment.isEnabled
            model.stateID = identity
        }
    }

    private struct Pages: View {
        let model: Model

        var body: some View {
            HStack(spacing: 100) {
                NativeSidebarFocusDestination(
                    destination: .home, selection: model.selection, handoff: model.handoff,
                    content: FocusButton(destination: .home, model: model)
                )
                if model.mountDestinationAnchor {
                    NativeSidebarFocusDestination(
                        destination: .settings, selection: model.selection, handoff: model.handoff,
                        content: FocusButton(destination: .settings, model: model)
                    )
                } else {
                    FocusButton(destination: .settings, model: model)
                        .disabled(true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct FocusButton: UIViewRepresentable {
        let destination: NavigationRailDestination
        let model: Model

        func makeUIView(context: Context) -> Button {
            let button = Button(type: .system)
            button.setTitle(destination.storageValue, for: .normal)
            model.buttons[destination] = button
            return button
        }

        func updateUIView(_ button: Button, context: Context) {
            button.isEnabled = context.environment.isEnabled
            button.onFocus = {
                if model.handoff.isWaiting { model.prematureFocusCount += 1 }
            }
        }

        final class Button: UIButton {
            var onFocus: (() -> Void)?
            override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
                super.didUpdateFocus(in: context, with: coordinator)
                if context.nextFocusedView === self { onFocus?() }
            }
        }
    }
}
