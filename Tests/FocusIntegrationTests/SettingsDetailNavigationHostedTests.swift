@testable import FeatureSettings
import CoreModels
import CoreUI
@testable import AppShell
import FeatureProfiles
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SettingsDetailNavigationHostedTests: XCTestCase {
    func testTopBarSettingsSlidesWithoutChangingScrollGeometry() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for reducedMotion in [false, true] {
            for rootOffset: CGFloat in [0, 600] {
                let window = UIWindow(windowScene: scene)
                let navigation = SettingsNavigationModel()
                let probes = PageMotionProbes()
                let chrome = NavigationChromeModel()
                window.rootViewController = UIHostingController(rootView:
                    SettingsTopBarMotionFixture(navigation: navigation, probes: probes, chrome: chrome)
                        .environment(\._accessibilityReduceMotion, reducedMotion)
                )
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await Task.sleep(for: .milliseconds(250))
                func scrollView(_ id: String) throws -> UIScrollView {
                    var view = probes.views["\(id)-content"]
                    while let current = view {
                        if let scroll = current as? UIScrollView { return scroll }
                        view = current.superview
                    }
                    return try XCTUnwrap(nil as UIScrollView?, "Missing native scroll view for \(id)")
                }
                let rootScroll = try scrollView("root")
                rootScroll.setContentOffset(CGPoint(x: 0, y: rootOffset), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let rootFrame = try XCTUnwrap(probes.frame("root", in: window))
                let rootPosition = rootScroll.contentOffset
                XCTAssertEqual(rootPosition.y, rootOffset, accuracy: 1)
                XCTAssertEqual(navigation.pages.animationsEnabled, !reducedMotion && !UIAccessibility.isReduceMotionEnabled)

                func assertStableScrollDuringSlide(current: String, returning: Bool = false) async throws {
                    var movingFrames = 0
                    for _ in 0..<15 {
                        try await Task.sleep(for: .milliseconds(40))
                        let root = try XCTUnwrap(probes.frame("root", in: window))
                        XCTAssertEqual(root.minY, rootFrame.minY, accuracy: 0.5)
                        XCTAssertEqual(root.height, rootFrame.height, accuracy: 0.5)
                        XCTAssertEqual(rootScroll.contentOffset.y, rootPosition.y, accuracy: 0.5)
                        let visible = try XCTUnwrap(probes.frame(current, in: window))
                        let travel = abs(visible.midX - rootFrame.midX)
                        let opacity = try XCTUnwrap(probes.opacity(current))
                        if travel > 0.5, travel < SettingsPageMotion.travelDistance - 0.5,
                           opacity > 0.01, opacity < 0.99 {
                            movingFrames += 1
                        }
                        XCTAssertLessThanOrEqual(travel, SettingsPageMotion.travelDistance + 0.5)
                    }
                    XCTAssertEqual(try XCTUnwrap(probes.frame(current, in: window)).midX, rootFrame.midX, accuracy: 0.5)
                    XCTAssertEqual(try XCTUnwrap(probes.opacity(current)), 1, accuracy: 0.01)
                    XCTAssertEqual(chrome.isChromeHidden, !returning)
                    if navigation.pages.animationsEnabled {
                        XCTAssertGreaterThan(movingFrames, 2, "The page must slide and fade, not appear instantly.")
                    } else {
                        XCTAssertEqual(movingFrames, 0)
                    }
                }

                navigation.enterDetail()
                try await assertStableScrollDuringSlide(current: "detail")
                let detailScroll = try scrollView("detail")
                detailScroll.setContentOffset(CGPoint(x: 0, y: 280), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let detailPosition = detailScroll.contentOffset
                XCTAssertEqual(detailPosition.y, 280, accuracy: 1)
                navigation.pages.push(.artwork)
                try await assertStableScrollDuringSlide(current: "nested")
                navigation.pages.pop()
                try await assertStableScrollDuringSlide(current: "detail")
                XCTAssertTrue(try scrollView("detail") === detailScroll)
                XCTAssertEqual(detailScroll.contentOffset.y, detailPosition.y, accuracy: 0.5)
                navigation.pages.pop()
                try await assertStableScrollDuringSlide(current: "root", returning: true)
                XCTAssertTrue(try scrollView("root") === rootScroll)
                XCTAssertEqual(probes.creations["root"], 1)
                XCTAssertEqual(probes.creations["detail"], 1)
                XCTAssertEqual(navigation.pages.returnGeneration, 2)
            }
        }
    }

    func testDiscoveredLibrariesRenderAsEnabledNavigationRowsInEveryTVStyle() async throws {
        let suite = "NavigationLibraryEditorHosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let libraries: [AggregatedLibrary] = [
            .init(accountID: "plex", accountName: "Viewer", serverName: "Plex",
                  providerKind: .plex, library: .init(id: "movies", title: "Plex Movies", kind: .movie)),
            .init(accountID: "jellyfin", accountName: "Viewer", serverName: "Jellyfin",
                  providerKind: .jellyfin, library: .init(id: "shows", title: "Jellyfin Shows", kind: .series))
        ]
        let scope = ProfileLibrariesScope(
            accounts: [], activeProfile: Profile(id: "viewer", name: "Viewer"),
            discoveredLibraries: .loaded(libraries),
            refreshingLibraryAccountIDs: [], unreachableLibraryAccountIDs: [],
            reloadLibraries: {},
            homeVisibility: HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults)),
            isAccountIncludedInActiveProfile: { _ in true },
            onSetAccountIncluded: { _, _ in }, onAddAccount: {},
            plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
        let navigation = NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults)
        )
        let builtIns = Set(NavigationDestinationDefaults.compact(hasMusic: true))
            .union([NavigationLibraryLayout.allLibrariesKey])
        for style in NavigationStyle.allCases {
            navigation.style = style
            try await withProfileDestination(.navigationLayout, direction: .leftToRight) {
                NavigationLibrariesDetailView(
                    scope: scope, navigation: navigation, excludedKeys: builtIns
                )
            } inspect: { window in
                let labels = try self.captureLabels(window, name: "navigation-libraries-\(style.rawValue)")
                let hidden = try self.label("HIDDEN", in: labels)
                for title in ["Plex Movies", "Jellyfin Shows"] {
                    let row = try XCTUnwrap(
                        labels.first { $0.text.contains(title) }, "Missing library row: \(title)"
                    ).frame
                    XCTAssertLessThan(row.maxY, hidden.minY, "New libraries belong above Hidden.")
                }
            }
        }
    }

    func testDialogDismissDoesNotPopItsPresentingSettingsPage() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let navigation = SettingsPageNavigation<Int>()
        let probe = SettingsDialogProbe()
        window.rootViewController = UIHostingController(rootView:
            SettingsPageStack(navigation: navigation, pageWidth: 1920, onRootBack: {}) {
                Text("Categories")
            } destination: { _ in
                Text("Settings page")
                    .plozzSheet(isPresented: Binding(get: { probe.isPresented }, set: { probe.isPresented = $0 })) {
                        SettingsDialogDismissProbe(probe: probe)
                    }
            }
        )
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        navigation.push(1)
        try await Task.sleep(for: .milliseconds(600))
        probe.isPresented = true
        let presented = ContinuousClock.now + .seconds(5)
        while probe.dismiss == nil, ContinuousClock.now < presented {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(probe.inheritsSettingsPage, false)
        try await Task.sleep(for: .milliseconds(350))
        try XCTUnwrap(probe.dismiss)()
        let dismissed = ContinuousClock.now + .seconds(5)
        while probe.isPresented, ContinuousClock.now < dismissed {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(probe.isPresented)
        XCTAssertEqual(navigation.routes, [1], "Closing a dialog must not pop the underlying page.")
    }

    func testSharedStackMovesAndFadesRetainsParentsAndMirrorsInRightToLeftLayout() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
            let navigation = SettingsPageNavigation<Int>()
            let probes = PageMotionProbes()
            window.rootViewController = UIHostingController(rootView:
                SettingsPageStack(navigation: navigation, pageWidth: 960, onRootBack: {}) {
                    PageMotionProbe(id: "root", probes: probes)
                } destination: { route in
                    PageMotionProbe(id: route == 1 ? "detail" : "nested", probes: probes)
                }
                .environment(\.layoutDirection, direction)
                .ignoresSafeArea()
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await Task.sleep(for: .milliseconds(200))
            let sampler = PageMotionSampler(probes: probes, window: window)
            sampler.start()
            defer { sampler.stop() }
            navigation.push(1)
            try await Task.sleep(for: .milliseconds(600))
            let sign: CGFloat = direction == .leftToRight ? 1 : -1
            if !UIAccessibility.isReduceMotionEnabled {
                assertIntermediatePages(sampler.samples, width: 960, sign: sign)
            }
            navigation.push(2)
            try await Task.sleep(for: .milliseconds(600))
            navigation.pop()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(probes.creations["root"], 1)
            XCTAssertEqual(probes.creations["detail"], 1)
            XCTAssertEqual(try XCTUnwrap(probes.frame("detail", in: window)).minX, 0, accuracy: 2)
            sampler.samples.removeAll()
            navigation.pop()
            try await Task.sleep(for: .milliseconds(600))
            if !UIAccessibility.isReduceMotionEnabled {
                assertIntermediatePages(sampler.samples, width: 960, sign: sign)
            }
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, 0, accuracy: 2)
            XCTAssertEqual(navigation.returnGeneration, 2)
        }
    }

    func testWorkspaceStyleDestinationsStayFullWidthDuringEntryAndReturn() async throws {
        try await verifyWorkspaceWidth(
            parent: .subtitles,
            destinations: [.subtitleStyle(liveTV: false), .subtitleStyle(liveTV: true)]
        )
    }

    func testProfileSetupDestinationsStayFullWidthDuringEntryAndReturn() async throws {
        try await verifyWorkspaceWidth(
            parent: .profileSettings(profileID: "fixture"),
            destinations: [
                .profileAppearance(profileID: "fixture"),
                .profileLockSetup(profileID: "fixture"),
                .parentalPINSetup
            ]
        )
    }

    func testCategoriesAndNestedPagesKeepOneCenteredWidthThroughoutMotion() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for reducedMotion in [false, true] {
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
                let navigation = SettingsNavigationModel()
                let probes = PageMotionProbes()
                window.rootViewController = UIHostingController(rootView:
                    SettingsWorkspace(navigation: navigation) {
                        PageMotionProbe(id: "root", probes: probes)
                    } detail: { route in
                        PageMotionProbe(id: route == .playback ? "detail" : "nested", probes: probes)
                    }
                    .padding(.horizontal, 80)
                    .environment(\.layoutDirection, direction)
                    .ignoresSafeArea()
                )
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await Task.sleep(for: .milliseconds(200))
                navigation.pages.animationsEnabled = !reducedMotion && !UIAccessibility.isReduceMotionEnabled
                XCTAssertNil(probes.frame("detail", in: window), "The category list must not preload a second pane.")
                let root = try XCTUnwrap(probes.frame("root", in: window))
                XCTAssertEqual(root.width, SettingsFormMetrics.pageWidth, accuracy: 1)
                XCTAssertEqual(root.midX, window.bounds.midX, accuracy: 1)
                let sampler = PageMotionSampler(probes: probes, window: window)
                sampler.start()
                defer { sampler.stop() }
                navigation.enterDetail()
                try await Task.sleep(for: .milliseconds(600))
                let detail = try XCTUnwrap(probes.frame("detail", in: window))
                XCTAssertEqual(detail, root)
                if navigation.pages.animationsEnabled {
                    XCTAssertGreaterThan(sampler.samples.filter {
                        abs($0.rootX - root.minX) > 5 && abs($0.detailX - detail.minX) > 5
                    }.count, 1, "Both centered pages must move, not switch abruptly.")
                }
                for sample in sampler.samples {
                    XCTAssertEqual(sample.rootWidth, SettingsFormMetrics.pageWidth, accuracy: 1)
                    XCTAssertEqual(sample.detailWidth, SettingsFormMetrics.pageWidth, accuracy: 1)
                }
                navigation.pages.push(.artwork)
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(try XCTUnwrap(probes.frame("nested", in: window)), root)
                navigation.pages.pop()
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(try XCTUnwrap(probes.frame("detail", in: window)), root)
                navigation.pages.pop()
                try await Task.sleep(for: .milliseconds(600))
                XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)), root)
                XCTAssertEqual(probes.creations["root"], 1, "Returning must retain the category list and its scroll.")
                XCTAssertFalse(navigation.isCategoryOpen)
            }
        }
    }

    private func verifyWorkspaceWidth(parent: SettingsRoute, destinations: [SettingsRoute]) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let navigation = SettingsNavigationModel()
        navigation.select(parent)
        navigation.enterDetail()
        let probes = PageMotionProbes()
        let host = UIHostingController(rootView:
            SettingsWorkspace(navigation: navigation) {
                Button("Subtitles") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } detail: { route in
                Button(route == parent ? "Open editor" : "Editor control") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        PageMotionProbe(id: route == parent ? "root" : "detail", probes: probes)
                    }
            }
            .padding(.horizontal, 80)
            .ignoresSafeArea()
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        let sampler = PageMotionSampler(probes: probes, window: window)
        sampler.start()
        defer { sampler.stop() }
        let expectedWidth = window.bounds.width - 160
        for destination in destinations {
            for opening in [true, false] {
                sampler.samples.removeAll()
                navigation.path = opening ? [parent, destination] : [parent]
                try await Task.sleep(for: .milliseconds(650))
                if opening {
                    XCTAssertEqual(try XCTUnwrap(probes.frame("detail", in: window)).width,
                                   expectedWidth, accuracy: 1)
                }
                if !reduceMotion {
                    XCTAssertGreaterThanOrEqual(sampler.samples.count, 2,
                                               "Sample the actual animated overlap, not only the settled layout.")
                }
                for sample in sampler.samples {
                    XCTAssertEqual(sample.detailWidth, expectedWidth, accuracy: 1,
                                   "The editor must not grow from or shrink to the ordinary Settings width.")
                    XCTAssertEqual(sample.rootWidth, SettingsFormMetrics.pageWidth, accuracy: 1)
                }
                let attachment = XCTAttachment(string: String(describing: sampler.samples))
                attachment.name = "workspace-editor-\(destination)-opening-\(opening)-reduced-\(reduceMotion)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testProfileAppearanceContentKeepsReadableHeadingAndControls() async throws {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-layout-\(UUID()).png")
        let avatar = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        try avatar.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let profiles = [
            Profile(id: "symbol", name: "Sample profile", avatarSymbol: "person.fill"),
            Profile(id: "emoji", name: "Sample profile", avatarSymbol: "person.fill", avatarEmoji: "😀"),
            Profile(id: "photo", name: "Sample profile", avatarSymbol: "person.fill", avatarImageURL: imageURL.absoluteString)
        ]
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for profile in profiles {
                try await withProfileDestination(
                    .profileAppearance(profileID: profile.id), direction: direction
                ) {
                    ProfileEditorView(
                        editingProfile: profile, onSave: { _ in }, onLiveChange: { _ in },
                        ownsFullScreen: false, onCancel: {}
                    )
                } inspect: { window in
                    let labels = try self.captureLabels(window, name: "profile-appearance-\(profile.id)-\(direction)")
                    let heading = try self.label("Edit Profile", in: labels)
                    XCTAssertLessThan(heading.height, 80, "The heading must not wrap into a vertical strip.")
                    XCTAssertGreaterThan(heading.width, 200)
                    for text in ["Revert All Changes", "Done", "NAME", "AVATAR"] {
                        let frame = try self.label(text, in: labels)
                        XCTAssertTrue(window.bounds.insetBy(dx: 40, dy: 0).contains(frame), "\(text) is clipped.")
                    }
                    let preview = try self.label("PREVIEW", in: labels)
                    if direction == .leftToRight {
                        XCTAssertLessThan(preview.maxX, heading.minX)
                    } else {
                        XCTAssertGreaterThan(preview.minX, heading.maxX)
                    }
                }
            }
        }
    }

    func testPINSetupCompositionIsCenteredWithinTheWorkspace() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for parental in [false, true] {
                try await withProfileDestination(
                    parental ? .parentalPINSetup : .profileLockSetup(profileID: "fixture"),
                    direction: direction
                ) {
                    if parental {
                        ParentalPINSetupView(onComplete: { _ in }, onCancel: {})
                    } else {
                        ProfileLockSetupView(
                            profile: Profile(id: "fixture", name: "Sample profile"),
                            offersPlexPINReuse: true, onComplete: { _ in }, onCancel: {}
                        )
                    }
                } inspect: { window in
                    let labels = try self.captureLabels(window, name: "profile-pin-\(parental)-\(direction)")
                    let heading = try self.label(parental ? "Create a Parental PIN" : "Add a Profile PIN?", in: labels)
                    XCTAssertLessThan(heading.height, 80)
                    let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
                    let items = self.focusItems(in: window)
                    XCTAssertTrue(items.contains { $0 === focused }, "Entry focus must land on the keypad.")
                    let keys = try items.map { item in
                        let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: item, relativeTo: window))
                        if item !== focused {
                            XCTAssertEqual(frame.height, 108, accuracy: 1,
                                           "The native control itself must fill the original key height.")
                            XCTAssertEqual(frame.width, frame.width > 180 ? 238 : 108, accuracy: 1)
                        }
                        return frame
                    }
                    XCTAssertEqual(keys.count, 11, "All ten digits and Delete must remain focusable.")
                    let pad = keys.reduce(CGRect.null) { $0.union($1) }
                    let focusedFrame = try XCTUnwrap(
                        NavigationRowFocusRequester.frame(of: focused, relativeTo: window)
                    )
                    XCTAssertEqual(focusedFrame.minY, pad.minY, accuracy: 1)
                    XCTAssertEqual(
                        direction == .leftToRight ? focusedFrame.minX : focusedFrame.maxX,
                        direction == .leftToRight ? pad.minX : pad.maxX,
                        accuracy: 1, "Digit 1 must receive entry focus in both layout directions."
                    )
                    let padOffset: CGFloat = 420 // Half the shared 720pt prose column plus 120pt gap.
                    XCTAssertEqual(
                        pad.midX, window.bounds.midX + (direction == .leftToRight ? padOffset : -padOffset),
                        accuracy: 8, "The prose/keypad pair must be centered, not overflowing the narrow Settings column."
                    )
                    for frame in keys + [heading] {
                        XCTAssertTrue(window.bounds.insetBy(dx: 40, dy: 0).contains(frame))
                    }
                }
            }
        }
    }

    func testProfileEditorActionsShareOneNativeControlRow() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            for reduceTransparency in [false, true] {
                for autoSave in [false, true] {
                    try await withProfileDestination(
                        .profileAppearance(profileID: "controls"), direction: direction
                    ) {
                        ProfileEditorView(
                            editingProfile: Profile(id: "controls", name: "Sample profile"),
                            canDelete: true, onSave: { _ in },
                            onLiveChange: autoSave ? { _ in } : nil,
                            ownsFullScreen: false, onDelete: {}, onCancel: {}
                        )
                        .environment(\.plozzReduceTransparency, reduceTransparency)
                    } inspect: { window in
                        let labels = try self.captureLabels(
                            window, name: "profile-controls-\(direction)-opaque-\(reduceTransparency)-autosave-\(autoSave)"
                        )
                        let action = try self.label(autoSave ? "Done" : "Save", in: labels)
                        let controls = try self.focusItems(in: window).map {
                            try XCTUnwrap(NavigationRowFocusRequester.frame(of: $0, relativeTo: window))
                        }.filter { abs($0.midY - action.midY) < 8 }
                        XCTAssertEqual(
                            controls.count, autoSave ? 3 : 4,
                            "Back, Delete and Done/Cancel/Save must share one row; unchanged Revert is disabled."
                        )
                        let trash = try XCTUnwrap(controls.min { $0.width < $1.width })
                        XCTAssertGreaterThanOrEqual(trash.width, 44)
                        XCTAssertGreaterThanOrEqual(trash.height, 44)
                        for frame in controls {
                            XCTAssertEqual(frame.midY, trash.midY, accuracy: 1)
                            XCTAssertTrue(window.bounds.insetBy(dx: 40, dy: 0).contains(frame))
                        }
                        let ordered = controls.sorted { $0.minX < $1.minX }
                        for pair in zip(ordered, ordered.dropFirst()) {
                            XCTAssertLessThan(pair.0.maxX, pair.1.minX, "Action hit targets must not overlap.")
                        }
                    }
                }
            }
        }
    }

    private func withProfileDestination<Content: View>(
        _ route: SettingsRoute, direction: LayoutDirection,
        @ViewBuilder content: () -> Content, inspect: (UIWindow) throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let navigation = SettingsNavigationModel()
        let destination = content()
        window.rootViewController = UIHostingController(rootView:
            SettingsWorkspace(navigation: navigation) {
                Button("Profile settings") {}
            } detail: { _ in
                destination
            }
            .padding(.horizontal, 80)
            .environment(\.layoutDirection, direction)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        navigation.pages.push(route)
        try await Task.sleep(for: .milliseconds(750))
        window.layoutIfNeeded()
        XCTAssertNotNil(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        try inspect(window)
    }

    private func captureLabels(_ window: UIWindow, name: String) throws -> [(text: String, frame: CGRect)] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.minimumTextHeight = 0.01
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let bounds = observation.boundingBox
            return (text, CGRect(
                x: bounds.minX * window.bounds.width, y: (1 - bounds.maxY) * window.bounds.height,
                width: bounds.width * window.bounds.width, height: bounds.height * window.bounds.height
            ))
        }
    }

    private func label(_ text: String, in labels: [(text: String, frame: CGRect)]) throws -> CGRect {
        try XCTUnwrap(labels.first { $0.text == text }, "Missing or clipped \(text): \(labels.map(\.text))").frame
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) {
                    items[ObjectIdentifier(item)] = item
                }
            }
        }
        return Array(items.values)
    }

    func testBothPagesMoveAndFadeInBothDirectionsAndRetainTheRoot() async throws {
        try await verifySlides(direction: .leftToRight)
    }

    func testBothPagesMirrorTheirMovementInRightToLeftLayout() async throws {
        try await verifySlides(direction: .rightToLeft)
    }

    func testUnanimatedNavigationAndCancelledReturnsDoNotReleaseANewerTransition() async throws {
        try await withPages { navigation, probes, window in
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            let hiddenX: CGFloat = UIAccessibility.isReduceMotionEnabled ? 0 : -SettingsPageMotion.travelDistance
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, hiddenX, accuracy: 2)
            XCTAssertEqual(try XCTUnwrap(probes.opacity("root")), 0, accuracy: 0.01)
            navigation.pop(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, 0, accuracy: 2)
            XCTAssertEqual(navigation.returnFocusGeneration, 1)
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(100))
            navigation.pop(animated: true)
            navigation.reset()
            navigation.push(animated: false)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(navigation.isPresented)
            XCTAssertTrue(navigation.awaitingFocus)
            XCTAssertEqual(navigation.returnFocusGeneration, 0)
        }
    }

    func testSlideViewportPreservesVerticalSafeAreaWithoutHorizontalBleed() async throws {
        try await withPages(verticalSafeArea: 40, horizontalInset: 80) { navigation, probes, window in
            for isDetail in [false, true, false] {
                if isDetail {
                    navigation.push(animated: true)
                } else if navigation.isPresented {
                    navigation.focusArrived()
                    navigation.pop(animated: true)
                }
                try await Task.sleep(for: .milliseconds(600))
                window.layoutIfNeeded()
                let frame = try XCTUnwrap(probes.frame(isDetail ? "detail" : "root", in: window))
                XCTAssertGreaterThan(frame.minY, 8)
                XCTAssertLessThan(frame.maxY + 8, window.bounds.maxY)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = isDetail ? "detail-safe-area" : "root-safe-area"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                let expected = try self.pixel(image, at: CGPoint(x: frame.midX, y: frame.midY))
                let background = try self.pixel(image, at: CGPoint(x: 8, y: frame.midY))
                for y in [frame.minY - 8, frame.maxY + 8] {
                    XCTAssertEqual(
                        try self.pixel(image, at: CGPoint(x: frame.midX, y: y)), expected,
                        "The slide mask must not cut off content at the vertical safe-area boundary."
                    )
                }
                for x in [frame.minX - 8, frame.maxX + 8] {
                    let outside = try self.pixel(image, at: CGPoint(x: x, y: frame.midY))
                    XCTAssertEqual(outside, background,
                                   "Pages must remain clipped horizontally to preserve the slide.")
                }
            }
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let source = try XCTUnwrap(image.cgImage)
        let crop = try XCTUnwrap(source.cropping(to: CGRect(x: point.x, y: point.y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    private func verifySlides(direction: LayoutDirection) async throws {
        try await withPages(direction: direction) { navigation, probes, window in
            let width = window.bounds.width
            let sign: CGFloat = direction == .leftToRight ? 1 : -1
            let sampler = PageMotionSampler(probes: probes, window: window)
            sampler.start()
            defer { sampler.stop() }
            navigation.push(animated: true)
            try await Task.sleep(for: .milliseconds(600))
            self.assertIntermediatePages(sampler.samples, width: width, sign: sign)
            let hiddenX: CGFloat = UIAccessibility.isReduceMotionEnabled ? 0 : -sign * SettingsPageMotion.travelDistance
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, hiddenX, accuracy: 2)
            navigation.focusArrived()
            sampler.samples.removeAll()
            navigation.pop(animated: true)
            try await Task.sleep(for: .milliseconds(600))
            self.assertIntermediatePages(sampler.samples, width: width, sign: sign)
            XCTAssertEqual(try XCTUnwrap(probes.frame("root", in: window)).minX, 0, accuracy: 2)
            XCTAssertEqual(probes.creations["root"], 1, "The parent page must retain its view/state during navigation.")
            XCTAssertEqual(navigation.returnFocusGeneration, 1)
        }
    }

    private func assertIntermediatePages(_ samples: [PageMotionSampler.Sample], width: CGFloat, sign: CGFloat) {
        let distance = SettingsPageMotion.travelDistance
        let moving = samples.filter {
            let root = $0.rootX * sign
            let detail = $0.detailX * sign
            return root < -distance * 0.05 && root > -distance * 0.95
                && detail > distance * 0.05 && detail < distance * 0.95
        }
        XCTAssertGreaterThanOrEqual(moving.count, 3, "Both pages must move gently between endpoints: \(samples)")
        if let first = moving.first, let last = moving.last {
            XCTAssertGreaterThan(last.time - first.time, 0.18, "The transition must not rush through its movement.")
        }
        for sample in samples {
            XCTAssertLessThanOrEqual(abs(sample.rootX), distance + 1)
            XCTAssertLessThanOrEqual(abs(sample.detailX), distance + 1)
            XCTAssertEqual(sample.rootWidth, width, accuracy: 1)
            XCTAssertEqual(sample.detailWidth, width, accuracy: 1)
        }
        for sample in moving {
            XCTAssertEqual((sample.detailX - sample.rootX) * sign, distance, accuracy: 2)
        }
        XCTAssertGreaterThanOrEqual(moving.filter {
            $0.rootOpacity > 0.01 && $0.rootOpacity < 0.99
                && $0.detailOpacity > 0.01 && $0.detailOpacity < 0.99
        }.count, 3, "Both pages must fade, not just move.")
        let attachment = XCTAttachment(string: String(describing: samples))
        attachment.name = "settings-page-motion"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func withPages(
        direction: LayoutDirection = .leftToRight,
        verticalSafeArea: CGFloat = 0,
        horizontalInset: CGFloat = 0,
        inspect: (SettingsDetailNavigation, PageMotionProbes, UIWindow) async throws -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let navigation = SettingsDetailNavigation()
        let probes = PageMotionProbes()
        let host = UIHostingController(rootView:
            SettingsDetailPages(navigation: navigation) {
                PageMotionProbe(id: "root", probes: probes)
                    .background {
                        Color.blue
                            .ignoresSafeArea(.container, edges: .vertical)
                            .padding(.horizontal, -24)
                    }
            } detail: {
                PageMotionProbe(id: "detail", probes: probes)
                    .background {
                        Color.orange
                            .ignoresSafeArea(.container, edges: .vertical)
                            .padding(.horizontal, -24)
                    }
            }
            .padding(.horizontal, horizontalInset)
            .background { Color.red.ignoresSafeArea() }
            .environment(\.layoutDirection, direction)
            .ignoresSafeArea(edges: verticalSafeArea > 0 ? .horizontal : .all)
        )
        host.additionalSafeAreaInsets = UIEdgeInsets(
            top: verticalSafeArea, left: 0, bottom: verticalSafeArea, right: 0
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(200))
        try await inspect(navigation, probes, window)
    }
}

@MainActor
@Observable
private final class SettingsDialogProbe {
    var isPresented = false
    var inheritsSettingsPage: Bool?
    var dismiss: (() -> Void)?
}

private struct SettingsDialogDismissProbe: View {
    let probe: SettingsDialogProbe
    @SettingsPageDismiss private var dismiss
    @Environment(\.settingsPageContext) private var context

    var body: some View {
        Button("Close", action: dismiss)
            .onAppear {
                probe.inheritsSettingsPage = context != nil
                probe.dismiss = dismiss
            }
    }
}

@MainActor
private final class PageMotionProbes {
    var views: [String: UIView] = [:]
    var creations: [String: Int] = [:]

    func frame(_ id: String, in window: UIWindow) -> CGRect? {
        guard let view = views[id], view.window === window else { return nil }
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }

    func opacity(_ id: String) -> Float? {
        guard let view = views[id], view.window != nil else { return nil }
        var opacity: Float = 1
        var layer: CALayer? = view.layer
        while let current = layer {
            opacity *= (current.presentation() ?? current).opacity
            layer = current.superlayer
        }
        return opacity
    }
}

private struct SettingsTopBarMotionFixture: View {
    let navigation: SettingsNavigationModel
    let probes: PageMotionProbes
    let chrome: NavigationChromeModel

    var body: some View {
        TopBarNavigation(
            destinations: [.home, .settings], selection: .constant(.settings),
            preventsAccidentalExit: false,
            content: { _, _ in
                AnyView(SettingsWorkspace(navigation: navigation) {
                    page("root").scrollsTopNavigation()
                } detail: { route in
                    page(route == .playback ? "detail" : "nested")
                })
            },
            label: { AnyView(Text($0.storageValue)) },
            chrome: chrome
        )
        .environment(\.plozzNavigationStyle, .tabBar)
        .disabled(true)
    }

    private func page(_ id: String) -> some View {
        ScrollView {
            PageMotionProbe(id: "\(id)-content", probes: probes).frame(height: 2400)
        }
        .background { PageMotionProbe(id: id, probes: probes) }
    }
}

private struct PageMotionProbe: UIViewRepresentable {
    let id: String
    let probes: PageMotionProbes

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        probes.views[id] = view
        probes.creations[id, default: 0] += 1
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
private final class PageMotionSampler: NSObject {
    struct Sample: CustomStringConvertible {
        let time: CFTimeInterval
        let rootX: CGFloat
        let rootWidth: CGFloat
        let rootOpacity: Float
        let detailX: CGFloat
        let detailWidth: CGFloat
        let detailOpacity: Float
        var description: String {
            "time=\(time), root=\(rootX)/\(rootOpacity), detail=\(detailX)/\(detailOpacity), width=\(detailWidth)"
        }
    }

    var samples: [Sample] = []
    private let probes: PageMotionProbes
    private let window: UIWindow
    private var displayLink: CADisplayLink?

    init(probes: PageMotionProbes, window: UIWindow) {
        self.probes = probes
        self.window = window
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func sample() {
        guard let root = probes.frame("root", in: window),
              let detail = probes.frame("detail", in: window),
              let rootOpacity = probes.opacity("root"),
              let detailOpacity = probes.opacity("detail") else { return }
        samples.append(Sample(time: CACurrentMediaTime(), rootX: root.minX, rootWidth: root.width,
                              rootOpacity: rootOpacity, detailX: detail.minX, detailWidth: detail.width,
                              detailOpacity: detailOpacity))
    }
}
