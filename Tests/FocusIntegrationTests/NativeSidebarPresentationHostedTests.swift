import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShell
@testable import FeatureSettings

@MainActor
final class NativeSidebarPresentationHostedTests: XCTestCase {
    func testNativeSidebarHidesOnSettingsSubpages() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let navigation = SettingsNavigationModel()
        fixture.window.rootViewController = UIHostingController(rootView:
            TabView {
                Tab("Settings", systemImage: "gearshape") {
                    SettingsWorkspace(navigation: navigation) {
                        SettingsSectionButton(title: Text("Playback"), icon: "play", route: .playback)
                    } detail: { _ in
                        Button("Return") { navigation.returnToSidebar() }
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .environment(\.plozzNavigationStyle, .sidebar)
        )
        try await waitUntil { navigation.sidebarFocusRequest > 0 }
        navigation.enterDetail()
        try await waitUntil {
            let presented = fixture.window.rootViewController?.presentedViewController
            return presented?.viewIfLoaded?.window != nil
                && presented?.isBeingPresented == false && !navigation.pages.isTransitioning
        }
        fixture.window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
            XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Native Settings subpage"
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertTrue(labels.contains("Return"), "\(labels)")
        XCTAssertFalse(labels.contains("Settings"), "\(labels)")
        navigation.returnToSidebar()
        try await waitUntil { fixture.window.rootViewController?.presentedViewController == nil }
        XCTAssertFalse(navigation.isCategoryOpen)
    }

    func testSettingsRetainsRootNavigationAndDefersStyleChangesUntilExit() async throws {
        for initialStyle in [NavigationStyle.rail, .tabBar, .sidebar] {
            let fixture = try await makeFixture()
            defer { fixture.close() }
            let model = ShellModel(style: initialStyle)
            fixture.window.rootViewController = UIHostingController(rootView:
                NavigationRailFocusHost { _ in SettingsShell(model: model) }
            )
            try await waitUntil { model.pages[initialStyle]?.window != nil }
            let original = try XCTUnwrap(model.pages[initialStyle])

            model.showsSettings = true
            try await waitUntil { model.settingsButton?.window != nil }
            let settings = try XCTUnwrap(model.settingsButton)
            XCTAssertTrue(original.isEnabled, "Root Settings must retain usable navigation.")
            model.settingsNavigation.enterDetail()
            try await waitUntil { !original.isEnabled }
            fixture.window.layoutIfNeeded()
            let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
            let owner = try XCTUnwrap(NavigationRailFocusHostController.containing(settings))
            XCTAssertTrue(owner.requestFocus(to: settings, using: focusSystem))
            try await waitUntil { settings.isFocused }

            for style in [NavigationStyle.sidebar, .rail, .tabBar, .sidebar] {
                model.style = style
                fixture.window.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.creations, [initialStyle: 1],
                               "Changing a preference must not build hidden navigation.")
                XCTAssertTrue(settings.isFocused)
                XCTAssertTrue(model.pages[initialStyle] === original)
                XCTAssertNotNil(original.window)
            }

            let finalStyle: NavigationStyle = initialStyle == .sidebar ? .rail : .sidebar
            model.style = finalStyle
            model.settingsNavigation.returnToSidebar()
            try await waitUntil { original.isEnabled }
            XCTAssertTrue(model.pages[initialStyle] === original)
            XCTAssertNotNil(original.window, "Returning to Settings root must not reparent its content.")
            model.showsSettings = false
            try await waitUntil { model.pages[finalStyle]?.window != nil }
            XCTAssertEqual(model.creations[finalStyle], 1)
            XCTAssertNil(original.window)
            let sidebar = try XCTUnwrap(model.pages[finalStyle])
            try await waitUntil { model.settingsButton?.window == nil }
            model.showsSettings = true
            try await waitUntil { model.settingsButton?.window != nil }
            XCTAssertTrue(model.pages[finalStyle] === sidebar)
            XCTAssertEqual(model.creations[finalStyle], 1, "Ordinary Settings visits must retain the active tab.")
        }
    }

    func testSettingsFirstLaunchConstructsUsableNavigation() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let model = ShellModel(style: .sidebar)
        model.showsSettings = true
        fixture.window.rootViewController = UIHostingController(rootView: SettingsShell(model: model))
        try await waitUntil { model.settingsButton?.window != nil }
        XCTAssertEqual(model.creations, [.sidebar: 1])
        XCTAssertTrue(try XCTUnwrap(model.pages[.sidebar]).isEnabled)
        model.showsSettings = false
        try await waitUntil { model.pages[.sidebar]?.window != nil }
        XCTAssertEqual(model.creations, [.sidebar: 1])
    }

    func testNativeSidebarDisplaysOfflineStatusAndRemovesItAfterRecovery() async throws {
        for appearance in [UIUserInterfaceStyle.dark, .light] {
            let fixture = try await makeFixture()
            defer { fixture.close() }
            // Set traits before constructing the native sidebar, not during its focus transition.
            fixture.window.overrideUserInterfaceStyle = appearance
            let model = LibraryStatusModel()
            let host = UIHostingController(rootView: LibraryStatusSidebar(model: model)
                .environment(\.locale, Locale(identifier: "en_US")))
            fixture.window.rootViewController = host
            let focusSystem = try XCTUnwrap(UIFocusSystem.focusSystem(for: fixture.window))
            for offline in [false, true, false] {
                model.isOffline = offline
                let deadline = ContinuousClock.now + .seconds(5)
                var presentation: (image: UIImage, labels: [String])?
                repeat {
                    fixture.window.layoutIfNeeded()
                    focusSystem.requestFocusUpdate(to: host)
                    focusSystem.updateFocusIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    let image = UIGraphicsImageRenderer(bounds: fixture.window.bounds).image { _ in
                        XCTAssertTrue(fixture.window.drawHierarchy(in: fixture.window.bounds, afterScreenUpdates: true))
                    }
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    request.customWords = ["Offline"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                    let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    presentation = (image, labels)
                    if labels.contains(where: { $0.contains("Movies") }),
                       labels.filter({ $0.contains("Offline") }).count == (offline ? 2 : 0) {
                        break
                    }
                } while ContinuousClock.now < deadline
                let (image, labels) = try XCTUnwrap(presentation)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Native sidebar \(appearance == .dark ? "dark" : "light") offline=\(offline)"
                attachment.lifetime = .keepAlways
                add(attachment)
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
    fileprivate final class ShellModel {
        var style: NavigationStyle
        var showsSettings = false
        let settingsNavigation = SettingsNavigationModel()
        @ObservationIgnored var creations: [NavigationStyle: Int] = [:]
        @ObservationIgnored var pages: [NavigationStyle: UIButton] = [:]
        @ObservationIgnored weak var settingsButton: UIButton?

        init(style: NavigationStyle) { self.style = style }
    }

    private struct SettingsShell: View {
        let model: ShellModel

        var body: some View {
            SettingsNavigationShell(
                style: model.style, showsSettings: model.showsSettings
            ) { style in
                VStack {
                    ShellButton(model: model, style: style)
                        .frame(width: 480, height: 80)
                        .disabled(model.settingsNavigation.isCategoryOpen)
                    if model.showsSettings {
                        ShellButton(model: model, style: nil)
                            .frame(width: 480, height: 80)
                    }
                }
                .id(style)
            }
        }
    }

    private struct ShellButton: UIViewRepresentable {
        let model: ShellModel
        let style: NavigationStyle?

        func makeUIView(context: Context) -> UIButton {
            let button = UIButton(type: .system)
            button.setTitle(style?.rawValue ?? "Settings", for: .normal)
            if let style {
                model.creations[style, default: 0] += 1
                model.pages[style] = button
            } else {
                model.settingsButton = button
            }
            return button
        }

        func updateUIView(_ button: UIButton, context: Context) {
            button.isEnabled = context.environment.isEnabled
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
