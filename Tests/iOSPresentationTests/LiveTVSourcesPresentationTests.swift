#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
@testable import FeatureLiveTV
@testable import FeatureLiveTVCore
@testable import AppShelliOS
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class LiveTVSourcesPresentationTests: XCTestCase {
    func testToastClearsSearchOnFirstNavigationReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let state = ToastNavigationFixtureState()
        let host = UIHostingController(rootView: ToastNavigationFixture(state: state))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await settle(window)
        for page in ["detail", "first-return", "detail-again", "second-return"] {
            state.path = page.hasPrefix("detail") ? [1] : []
            try await Task.sleep(for: .milliseconds(1000))
            if page == "detail" {
                state.showToast = true
                try await settle(window)
            }
            if page.hasPrefix("detail") { continue }
            let image = snapshot(window)
            captureToastFrame(image, name: "guide-toast-navigation-\(page)")
            let search = try XCTUnwrap(searchFields(in: window).first {
                !$0.isHidden && $0.convert($0.bounds, to: window).intersects(window.bounds)
            })
            let searchFrame = search.convert(search.bounds, to: window)
            guard searchFrame.minY > window.bounds.maxY - 120 else {
                throw XCTSkip("Requires native bottom search; iPhone Duo places search beside the content.")
            }
            XCTAssertGreaterThan(searchFrame.minY, window.bounds.midY)
            let caption = try textFrame("Reading guide", in: image)
            let surface = try grayToastBounds(in: image, caption: caption)
            XCTAssertGreaterThanOrEqual(searchFrame.minY - surface.maxY, 14, page)
            XCTAssertLessThanOrEqual(searchFrame.minY - surface.maxY, 30, page)
        }
    }

    func testGuideToastUsesCurrentSheetBoundsAndClearsNativeNavigation() async throws {
        let suite = "ToastSheets.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Guide requested")
        let provider = SetupGuideProvider(started: { started.fulfill() })
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        let previousTheme = app.settings.theme.theme
        app.settings.theme.theme = .dark
        defer { app.settings.theme.theme = previousTheme }
        app.accountsProviders.registry.register(.iptv) { _ in provider }
        XCTAssertTrue(app.persist([provider.session]))
        await fulfillment(of: [started], timeout: 3)
        app.completeLibrarySelection()
        await provider.emit(.init(stage: .downloading, completed: 25, total: 100))
        app.transientStatusPresenter.present(icon: "tv", text: "Preparing", placement: .musicTransport, isProgress: true)
        defer {
            if let id = app.accountsProviders.accounts.first?.id { app.guidePreparation.cancel(accountID: id) }
            Task { await provider.resume() }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let state = ToastSheetFixtureState()
        let host = UIHostingController(rootView: ToastSheetFixture(app: app, state: state)
            .environment(AppLanguageSettingsModel())
            .environment(\.locale, Locale(identifier: "en_US")))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for page in [
            "idle-root", "idle-settings", "source", "settings-return", "root-return",
            "root-live", "root-downloads", "root-search", "settings-reopened",
            "settings-scrolled", "settings-top"
        ] {
            switch page {
            case "idle-settings", "settings-reopened": state.settings = true
            case "source": state.source = true
            case "settings-return": state.source = false
            case "root-return": state.settings = false
            case "root-live": state.tab = 1
            case "root-downloads": state.tab = 2
            case "root-search": state.tab = 3
            default: break
            }
            try await settle(window)
            try await Task.sleep(for: .milliseconds(650))
            if page == "settings-scrolled" || page == "settings-top" {
                let settings = try XCTUnwrap(host.presentedViewController)
                let scroll = try XCTUnwrap(sourceScrollViews(in: settings.view).first {
                    $0.contentSize.height > $0.bounds.height && !$0.isHidden
                })
                scroll.setContentOffset(
                    CGPoint(x: 0, y: page == "settings-scrolled" ? 250 : -scroll.adjustedContentInset.top),
                    animated: true
                )
                try await Task.sleep(for: .milliseconds(700))
            }
            if page.hasPrefix("idle") { continue }
            if page == "source" {
                app.transientStatusPresenter.dismiss()
                try await settle(window)
                try await Task.sleep(for: .milliseconds(400))
            }
            let reading = page.hasPrefix("root")
            await provider.emit(reading
                ? .init(stage: .readingGuide, completed: 603_000)
                : .init(stage: .downloading, completed: 25, total: 100))
            try await settle(window)
            let image = snapshot(window)
            captureToastFrame(image, name: "guide-toast-sheet-\(page)")
            let caption = try textFrame(reading ? "Reading guide" : "Downloading guide", in: image)
            let surface = try grayToastBounds(in: image, caption: caption)
            XCTAssertEqual(surface.minX, 16, accuracy: 2, page)
            XCTAssertEqual(surface.maxX, window.bounds.maxX - 16, accuracy: 2, page)
            if reading {
                let detail = try textFrame("listings scanned", in: image)
                XCTAssertEqual(caption.minX, detail.minX, accuracy: 2, page)
                let spinner = try XCTUnwrap(activityIndicators(in: window).first { indicator in
                    !indicator.isHidden && surface.contains(indicator.convert(indicator.bounds, to: window))
                })
                let spinnerFrame = spinner.convert(spinner.bounds, to: window)
                XCTAssertLessThan(spinnerFrame.maxX, caption.minX, page)
                XCTAssertEqual(spinnerFrame.midY, surface.midY, accuracy: 2, page)
                XCTAssertLessThanOrEqual(surface.height, 90, "Two-line feedback should remain a compact row.")
            }
            if page.hasPrefix("settings") {
                let search = try XCTUnwrap(searchFields(in: window).last)
                let frame = search.convert(search.bounds, to: window)
                XCTAssertGreaterThanOrEqual(frame.minY - surface.maxY, 14, page)
                XCTAssertLessThanOrEqual(frame.minY - surface.maxY, 30, page)
            } else if page == "source" {
                XCTAssertEqual(surface.maxY, window.safeAreaLayoutGuide.layoutFrame.maxY - 16, accuracy: 2)
            } else {
                let tabs = try XCTUnwrap(tabController(in: host))
                let frame = tabs.tabBar.convert(tabs.tabBar.bounds, to: window)
                XCTAssertEqual(surface.maxY, frame.minY - 16, accuracy: 3, page)
            }
        }
    }

    private func activityIndicators(in view: UIView) -> [UIActivityIndicatorView] {
        (view as? UIActivityIndicatorView).map { [$0] } ?? view.subviews.flatMap { activityIndicators(in: $0) }
    }

    func testToastUsesNativeSidebarContentAreaWithoutBottomBarClearance() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Native content layout guide requires iOS 26.") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for direction in [UISemanticContentAttribute.forceLeftToRight, .forceRightToLeft] {
            let host = UIHostingController(rootView:
                TabView {
                    Tab("Home", systemImage: "house") { Color.white }
                    Tab("Library", systemImage: "square.stack") { Color.white }
                    Tab("Live TV", systemImage: "tv") { Color.white }
                    Tab("Settings", systemImage: "gear") { Color.white }
                }
                    .tabViewStyle(.sidebarAdaptable)
                    .adaptiveStatusOverlay(isPresented: true) {
                        Text("Toast position")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .transientStatusSurface(palette: .dark)
                    }
            )
            host.view.semanticContentAttribute = direction
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await settle(window)
            try await Task.sleep(for: .milliseconds(400))
            let tabs = try XCTUnwrap(tabController(in: host))
            let area = tabs.view.convert(tabs.contentLayoutGuide.layoutFrame, to: window)
            guard area.width < window.bounds.width - 40 else {
                throw XCTSkip("Run on iPhone Duo or another device with native side-mounted tabs.")
            }
            XCTAssertLessThan(area.width, window.bounds.width - 40, "Exercise a real native side-mounted navigation area.")
            let image = snapshot(window)
            let attachment = XCTAttachment(image: image)
            attachment.name = "adaptive-toast-native-sidebar-\(direction.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let label = try textFrame("Toast position", in: image)
            XCTAssertEqual(label.midX, area.midX, accuracy: 3)
            XCTAssertGreaterThan(label.minX, area.minX)
            XCTAssertLessThan(label.maxX, area.maxX)
            XCTAssertEqual(
                try toastSurfaceBottom(in: image, x: area.midX),
                window.safeAreaLayoutGuide.layoutFrame.maxY - TransientStatusLayout.controlSpacing,
                accuracy: 2
            )
        }
    }

    func testToastTracksNativeBottomNavigationAndAnimatesWithoutReduceMotion() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for reduceMotion in [false, true] {
            let host = UIHostingController(rootView:
                Color.white
                    .adaptiveStatusOverlay(isPresented: true) {
                        Text("Toast position")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .transientStatusSurface(palette: .dark)
                    }
                    .environment(\._accessibilityReduceMotion, reduceMotion)
            )
            host.tabBarItem = UITabBarItem(title: "Live TV", image: UIImage(systemName: "tv"), tag: 0)
            let tabs = UITabBarController()
            tabs.viewControllers = [host]
            window.rootViewController = tabs
            window.makeKeyAndVisible()
            try await settle(window)
            try await Task.sleep(for: .milliseconds(200))
            let barFrame = tabs.tabBar.convert(tabs.tabBar.bounds, to: window)
            let beforeImage = snapshot(window)
            captureToastFrame(beforeImage, name: "before-\(reduceMotion)")
            let before = try toastSurfaceBottom(in: beforeImage)
            XCTAssertEqual(before, barFrame.minY - TransientStatusLayout.controlSpacing, accuracy: 2)

            tabs.setTabBarHidden(true, animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(90))
            let middleImage = snapshot(window)
            try await Task.sleep(for: .milliseconds(300))
            let afterImage = snapshot(window)
            captureToastFrame(middleImage, name: "middle-\(reduceMotion)")
            captureToastFrame(afterImage, name: "after-\(reduceMotion)")
            let middle = try toastSurfaceBottom(in: middleImage)
            let after = try toastSurfaceBottom(in: afterImage)
            let availableBottom = window.safeAreaLayoutGuide.layoutFrame.maxY
            XCTAssertEqual(after, availableBottom - TransientStatusLayout.controlSpacing, accuracy: 2)
            XCTAssertGreaterThan(after, before + 20)
            if reduceMotion {
                XCTAssertEqual(middle, after, accuracy: 1)
            } else {
                XCTAssertGreaterThan(middle, before + 1)
                XCTAssertLessThan(middle, after - 1, "Capture a real intermediate position, not a snap.")
            }
            tabs.setTabBarHidden(false, animated: false)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(90))
            let returningImage = snapshot(window)
            try await Task.sleep(for: .milliseconds(300))
            let returnedImage = snapshot(window)
            captureToastFrame(returningImage, name: "returning-\(reduceMotion)")
            captureToastFrame(returnedImage, name: "returned-\(reduceMotion)")
            let returning = try toastSurfaceBottom(in: returningImage)
            let returned = try toastSurfaceBottom(in: returnedImage)
            XCTAssertEqual(returned, before, accuracy: 2)
            if reduceMotion {
                XCTAssertEqual(returning, returned, accuracy: 1)
            } else {
                XCTAssertGreaterThan(returning, returned + 1)
                XCTAssertLessThan(returning, after - 1)
            }
        }
    }

    func testSharedToastsClearSettingsSearchAcrossThemesAndTextSizes() async throws {
        let suite = "ToastSettingsPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Guide requested")
        let provider = SetupGuideProvider(started: { started.fulfill() })
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        app.accountsProviders.registry.register(.iptv) { _ in provider }
        XCTAssertTrue(app.persist([provider.session]))
        let id = try XCTUnwrap(app.accountsProviders.accounts.first?.id)
        await fulfillment(of: [started], timeout: 3)
        app.completeLibrarySelection()
        await provider.emit(.init(stage: .preparingListings, completed: 264_000, total: 2_863_983))
        defer {
            app.guidePreparation.cancel(accountID: id)
            Task { await provider.resume() }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for theme in [AppTheme.dark, .pureBlack, .light] {
            app.settings.theme.theme = theme
            let palette = ThemePalette.palette(for: theme, systemColorScheme: .dark)
            for (width, textSize) in [
                (CGFloat(390), DynamicTypeSize.large),
                (CGFloat(320), DynamicTypeSize.large),
                (CGFloat(390), DynamicTypeSize.accessibility2)
            ] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
                window.rootViewController = UIHostingController(rootView:
                    PlozziOSSettingsView(appModel: app, onClose: {}, systemColorScheme: .dark)
                        .environment(AppLanguageSettingsModel())
                        .environment(\.horizontalSizeClass, .compact)
                        .environment(\.dynamicTypeSize, textSize)
                        .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await settle(window)
                let search = try XCTUnwrap(searchFields(in: window).first { field in
                    !field.isHidden && field.convert(field.bounds, to: window).intersects(window.bounds)
                })
                let searchFrame = search.convert(search.bounds, to: window)
                XCTAssertGreaterThan(searchFrame.minY, window.bounds.midY, "Exercise the native bottom search bar.")
                let image = snapshot(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "guide-toast-settings-\(theme)-\(Int(width))-\(textSize)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertEqual(app.guidePreparation.statuses[id]?.progress?.stage, .preparingListings)
                let caption = try textFrame("2,863,983", in: image)
                XCTAssertGreaterThan(caption.minY, window.bounds.midY)
                XCTAssertLessThan(caption.maxY + 24, searchFrame.minY, "Guide progress must clear the search field.")
                let target = try XCTUnwrap(window.hitTest(
                    CGPoint(x: searchFrame.midX, y: searchFrame.midY), with: nil
                ))
                XCTAssertTrue(target === search || target.isDescendant(of: search), "Search must remain tappable.")
                let sample = try pixel(image, at: CGPoint(x: width / 2, y: caption.maxY + 8))
                if !palette.isLight {
                    XCTAssertGreaterThan(sample.min() ?? 0, 50, "Dark feedback must not use the near-black modal surface.")
                }
                app.transientStatusPresenter.present(icon: "bookmark", text: "Added to Watchlist")
                try await settle(window)
                let feedbackImage = snapshot(window)
                let feedback = try textFrame("Watchlist", in: feedbackImage)
                XCTAssertLessThan(feedback.maxY + 16, searchFrame.minY)
                let feedbackAttachment = XCTAttachment(image: feedbackImage)
                feedbackAttachment.name = "watchlist-toast-settings-\(theme)-\(Int(width))-\(textSize)"
                feedbackAttachment.lifetime = .keepAlways
                add(feedbackAttachment)
                app.transientStatusPresenter.dismiss()
                try await settle(window)
                XCTAssertNotNil(app.guidePreparation.notificationStatus)
            }
        }
    }

    func testGuideProgressStaysInBottomToastAcrossSourcesAndBrowsing() async throws {
        let started = expectation(description: "Guide requested")
        let provider = SetupGuideProvider(started: { started.fulfill() })
        let preparation = LiveTVGuidePreparationModel { id in
            .init(accountID: id, authorizationID: "fixture", kind: .iptv, provider: provider)
        }
        let presenter = TransientStatusPresenter()
        preparation.start(accountID: "account")
        await fulfillment(of: [started], timeout: 3)
        defer {
            preparation.cancel(accountID: "account")
            Task { await provider.resume() }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func render(sources: Bool) {
            host.rootView = AnyView(
                GuideProgressFixture(sources: sources)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                    .guidePreparationOverlay(model: preparation, presenter: presenter, palette: .light)
                    .environment(preparation)
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
        }
        func visibleText() throws -> String {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot(window).cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        render(sources: true)
        await provider.emit(.init(stage: .downloading, completed: 2_500_000, total: 10_000_000))
        try await settle(window)
        XCTAssertNotNil(preparation.notificationStatus)
        var text = try visibleText()
        XCTAssertEqual(text.components(separatedBy: "Downloading guide").count - 1, 1, text)
        let sourcesFrame = try textFrame("Downloading guide", in: snapshot(window))
        render(sources: false)
        try await settle(window)
        XCTAssertNotNil(preparation.notificationStatus)
        text = try visibleText()
        XCTAssertTrue(text.contains("Downloading guide"), text)
        XCTAssertTrue(text.contains("25%"), text)
        let browseFrame = try textFrame("Downloading guide", in: snapshot(window))
        XCTAssertEqual(browseFrame.minY, sourcesFrame.minY, accuracy: 1)
        XCTAssertGreaterThan(browseFrame.minY, window.bounds.midY)
        let attachment = XCTAttachment(image: snapshot(window))
        attachment.name = "guide-progress-toast-download"
        attachment.lifetime = .keepAlways
        add(attachment)

        await provider.emit(.init(stage: .readingGuide, completed: 35_000))
        try await settle(window)
        text = try visibleText()
        XCTAssertTrue(text.contains("Reading guide"), text)
        XCTAssertTrue(text.contains("listings scanned"), text)
        XCTAssertFalse(text.contains("%"), text)
        await provider.resume()
        await preparation.waitForCompletion(accountID: "account")
        try await settle(window)
        text = try visibleText()
        XCTAssertTrue(text.contains("Guide ready"), text)
        try await Task.sleep(for: .milliseconds(5_100))
        XCTAssertNil(preparation.notificationStatus)
        XCTAssertEqual(preparation.statuses["account"]?.phase, .loaded)
    }

    func testPlaylistSetupShowsGuideWorkAndContinuingDoesNotCancelIt() async throws {
        let suite = "GuideSetupPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let started = expectation(description: "Initial guide requested during setup")
        let provider = SetupGuideProvider(started: { started.fulfill() }, librariesSuspended: true)
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults)
        )
        app.accountsProviders.registry.register(.iptv) { _ in provider }
        XCTAssertTrue(app.persist([provider.session]))
        let id = try XCTUnwrap(app.accountsProviders.accounts.first?.id)
        defer {
            app.guidePreparation.cancel(accountID: id)
            Task {
                await provider.resumeLibraries()
                await provider.resume()
            }
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertEqual(app.guidePreparation.statuses[id]?.phase, .loading)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView:
            PlozziOSLibrarySelectionView(appModel: app, accountIDs: [id])
                .environment(\.themePalette, .light)
                .environment(\.colorScheme, .light)
                .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await settle(window)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot(window).cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(text.contains("Adding guide"), text)
        XCTAssertTrue(text.contains("Choose later"), text)
        XCTAssertFalse(text.contains("No Video Libraries"), text)
        await provider.resumeLibraries()
        try await settle(window)
        try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot(window).cgImage)).perform([request])
        let ready = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(ready.contains("Adding guide"), ready)
        XCTAssertTrue(ready.contains("Continue"), ready)
        XCTAssertFalse(ready.contains("No Video Libraries"), ready)
        app.completeLibrarySelection()
        XCTAssertEqual(app.guidePreparation.statuses[id]?.phase, .loading)
        await provider.resume()
        await app.guidePreparation.waitForCompletion(accountID: id)
        XCTAssertEqual(app.guidePreparation.statuses[id]?.phase, .loaded)
    }

    func testAccountSourceShowsGuideLoadingAfterChannelsAreReady() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let source = LiveTVServerSource(id: "fixture", name: "Live channels", accountID: "account")
        for phase in [LiveTVImportPhase.loading, .loaded] {
            var status = LiveTVServerSourceStatus(source: source)
            status.phase = .loaded
            status.channelCount = 12_073
            status.availability = .init(status: .available, channelCount: 12_073, supportsGuide: true)
            status.guidePhase = phase
            host.rootView = AnyView(
                LiveTVServerSourceSummary(source: source, status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, Locale(identifier: "en_US"))
            )
            try await settle(window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(snapshot(window).cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertEqual(text.contains("Loading guide"), phase == .loading, text)
            XCTAssertTrue(text.contains("channels"), text)
        }
    }

    func testManualGuideRefreshShowsProgressAndResultInSourceDetails() async throws {
        let source = LiveTVServerSource(id: "fixture", name: "Live channels", accountID: "account")
        let configuration = LiveTVSourcesConfiguration(servers: [source])
        let model = LiveTVSourceManagementModel(store: SourcesFixtureStore(configuration: configuration), canMutate: { true })
        model.reload()
        let imports = LiveTVPrototypeImportModel(configuration: configuration)
        let started = expectation(description: "Manual guide refresh started")
        let provider = SetupGuideProvider(started: { started.fulfill() })
        let preparation = LiveTVGuidePreparationModel { id in
            .init(accountID: id, authorizationID: "fixture", kind: .iptv, provider: provider)
        }
        let presenter = TransientStatusPresenter()
        defer {
            preparation.cancel(accountID: source.accountID)
            Task { await provider.resume() }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 1024)
        window.rootViewController = UIHostingController(rootView:
            NavigationStack {
                LiveTVServerSourceDetails(model: model, imports: imports, sourceID: source.id, removeSource: { _ in false })
            }
            .guidePreparationOverlay(model: preparation, presenter: presenter, palette: .light)
            .environment(preparation)
            .environment(\.themePalette, .light)
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func visibleText() async throws -> String {
            try await settle(window)
            let image = snapshot(window)
            let attachment = XCTAttachment(image: image)
            attachment.name = "manual-guide-refresh"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        let initial = try await visibleText()
        XCTAssertTrue(initial.contains("Refresh guide"), initial)
        preparation.start(accountID: source.accountID, refresh: true)
        await fulfillment(of: [started], timeout: 3)
        let loading = try await visibleText()
        XCTAssertTrue(loading.contains("Refreshing guide"), loading)
        XCTAssertEqual(loading.components(separatedBy: "Refreshing guide").count - 1, 1, loading)
        XCTAssertFalse(loading.contains("0 loaded program listings"), loading)
        XCTAssertFalse(loading.contains("0 channels"), loading)
        XCTAssertFalse(loading.contains("Ready to load"), loading)
        await provider.resume()
        await preparation.waitForCompletion(accountID: source.accountID)
        let completed = try await visibleText()
        XCTAssertTrue(completed.contains("Guide ready"), completed)
        XCTAssertTrue(completed.contains("current listings"), completed)
    }

    func testSourceOverflowUsesMeasuredRowsAndDirectionalSharedFade() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let heights: [CGFloat] = [58, 82, 74, 96, 108, 62]
        for width in [CGFloat(390), 834] {
            for count in [1, 4, 5, 6] {
                let viewport = SourceViewport()
                window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
                host.rootView = AnyView(
                    VStack(spacing: 0) {
                        LiveTVBoundedSourceRows {
                            ForEach(0..<count, id: \.self) { index in
                                Color.red.frame(height: heights[index])
                            }
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            viewport.frame = $0
                        }
                        .id("\(width)-\(count)")
                        Spacer(minLength: 0)
                    }
                    .background(.black)
                )
                try await settle(window)
                let scrolls = sourceScrollViews(in: window)
                if count <= 4 {
                    XCTAssertTrue(scrolls.isEmpty, "Four or fewer sources must use their natural height.")
                    XCTAssertEqual(
                        viewport.frame.height,
                        heights.prefix(count).reduce(0, +) + CGFloat(count - 1) * SettingsRowMetrics.formRowSpacing,
                        accuracy: 1
                    )
                    continue
                }
                let scroll = try XCTUnwrap(scrolls.first, "Missing source scroll view at width \(width), count \(count).")
                XCTAssertEqual(scrolls.count, 1)
                let expected = 8 + heights.prefix(4).reduce(0, +)
                    + heights[4] / 2 + 4 * SettingsRowMetrics.formRowSpacing
                XCTAssertEqual(viewport.frame.height, expected, accuracy: 1,
                               "Show four complete, potentially wrapping rows and half of the fifth.")
                let frame = viewport.frame
                let bottom = CGPoint(x: frame.midX, y: frame.maxY - 15)
                let before = snapshot(window)
                XCTAssertLessThan(try pixel(before, at: bottom)[0], 180,
                                  "The partially visible fifth row must fade, not end abruptly.")
                scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height),
                                        animated: false)
                try await settle(window)
                XCTAssertGreaterThan(try pixel(snapshot(window), at: bottom)[0], 230,
                                     "The last source must stop fading when no content remains below.")
                let attachment = XCTAttachment(image: before)
                attachment.name = "source-overflow-\(Int(width))-\(count)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func sourceScrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { sourceScrollViews(in: $0) }
    }

    private final class SourceViewport {
        var frame: CGRect = .zero
    }

    func testIPTVSetupUsesTheSharedSettingsBackground() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 834] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    var images: [UIImage] = []
                    for showsSetup in [true, false] {
                        host.rootView = AnyView(
                            NavigationStack {
                                if showsSetup {
                                    IPTVSignInView(
                                        deviceID: "setup-presentation-fixture",
                                        onAuthenticated: { _ in }, onCancel: {}
                                    )
                                } else {
                                    ScrollView { Color.clear.frame(height: 100) }
                                        .background { SettingsPageBackground() }
                                        .navigationTitle("IPTV")
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbarBackground(.hidden, for: .navigationBar)
                                }
                            }
                            .environment(\.themePalette, palette)
                            .environment(\.colorScheme, palette.isLight ? .light : .dark)
                            .environment(\.gradientBackgroundsEnabled, gradient)
                            .environment(\.locale, Locale(identifier: "en_US"))
                        )
                        try await settle(window)
                        images.append(snapshot(window))
                    }
                    let attachment = XCTAttachment(image: images[0])
                    attachment.name = "iptv-setup-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    for y in [CGFloat(150), 500, 900] {
                        for x in [CGFloat(8), width - 8] {
                            let point = CGPoint(x: x, y: y)
                            for (actual, reference) in zip(try pixel(images[0], at: point), try pixel(images[1], at: point)) {
                                XCTAssertLessThanOrEqual(abs(actual - reference), 2,
                                    "IPTV setup must reveal the shared settings background at \(point).")
                            }
                        }
                    }
                }
            }
        }
    }

    func testOnboardingDoesNotCoverTheFullPageBackgroundWithAnInsetPanel() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 834] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    var images: [UIImage] = []
                    for showsWelcome in [true, false] {
                        host.rootView = AnyView(
                            SetupBackgroundFixture(showsWelcome: showsWelcome)
                                .environment(\.themePalette, palette)
                                .environment(\.colorScheme, palette.isLight ? .light : .dark)
                                .environment(\.gradientBackgroundsEnabled, gradient)
                                .environment(\.locale, Locale(identifier: "en_US"))
                        )
                        try await settle(window)
                        images.append(snapshot(window))
                    }
                    let attachment = XCTAttachment(image: images[0])
                    attachment.name = "onboarding-surface-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    for x in [CGFloat(8), 18, 32, width / 2, width - 32, width - 18, width - 8] {
                        let point = CGPoint(x: x, y: 930)
                        for (actual, reference) in zip(try pixel(images[0], at: point), try pixel(images[1], at: point)) {
                            XCTAssertLessThanOrEqual(abs(actual - reference), 2,
                                                    "The onboarding canvas must match the page at \(point).")
                        }
                    }
                }
            }
        }
    }

    func testSetupChoicesFitTabletWidthsInBothDirections() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 768, 834] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
                window.rootViewController = UIHostingController(rootView:
                    LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
                        .background { AppBackground(palette: .light) }
                        .environment(\.themePalette, .light)
                        .environment(\.colorScheme, .light)
                        .environment(\.dynamicTypeSize, .large)
                        .environment(\.layoutDirection, direction)
                        .environment(\.locale, Locale(identifier: "en_US"))
                )
                window.makeKeyAndVisible()
                try await waitForHostedLayout(window)
                let image = snapshot(window)
                let attachment = XCTAttachment(image: image)
                attachment.name = "tablet-onboarding-\(Int(width))-\(direction)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.customWords = ["IPTV", "Plozz"]
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: " ")
                for choice in ["IPTV provider", "Media server", "Plozz channels"] {
                    XCTAssertTrue(text.contains(choice), "\(choice) must be visible without scrolling: \(text)")
                }
                XCTAssertTrue(text.contains("Experimental"), "Setup must disclose Live TV's status: \(text)")
            }
        }
    }

    func testEmbeddedSourcesRevealTheSettingsBackgroundWithoutExtraRowInsets() async throws {
        let suite = "LiveTVSourcesPresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiles = ProfilesModel(store: ProfileStore(defaults: defaults))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [CGFloat(390), 768] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 1024)
            for (theme, palette) in [("dark", ThemePalette.dark), ("black", .pureBlack), ("light", .light)] {
                for gradient in [false, true] {
                    window.overrideUserInterfaceStyle = palette.isLight ? .light : .dark
                    host.rootView = AnyView(
                        NavigationStack {
                            SettingsPageList {
                                LiveTVSourcesView(
                                    store: SourcesFixtureStore(), presentation: .settingsPane,
                                    connectServer: {}, createChannel: {}, scanChannels: {}
                                )
                            }
                            .navigationTitle("Sources")
                            .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(profiles)
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                        .environment(\.locale, Locale(identifier: "en_US"))
                    )
                    try await settle(window)
                    let actual = snapshot(window)
                    let attachment = XCTAttachment(image: actual)
                    attachment.name = "sources-\(Int(width))-\(theme)-gradient-\(gradient)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: XCTUnwrap(actual.cgImage)).perform([request])
                    let header = try XCTUnwrap(request.results?.first {
                        $0.topCandidates(1).first?.string == "ADD A SOURCE"
                    })
                    let headerFrame = CGRect(
                        x: header.boundingBox.minX * width,
                        y: (1 - header.boundingBox.maxY) * window.bounds.height,
                        width: header.boundingBox.width * width,
                        height: header.boundingBox.height * window.bounds.height
                    )
                    let y = headerFrame.midY
                    host.rootView = AnyView(
                        NavigationStack {
                            Color.clear.settingsPageSurface()
                                .navigationTitle("Sources")
                                .navigationBarTitleDisplayMode(.inline)
                        }
                        .environment(\.themePalette, palette)
                        .environment(\.colorScheme, palette.isLight ? .light : .dark)
                        .environment(\.gradientBackgroundsEnabled, gradient)
                    )
                    try await settle(window)
                    let reference = snapshot(window)
                    XCTAssertEqual(try leadingInkEdge(actual, background: reference, header: headerFrame),
                                   24, accuracy: 2, "The pane must not gain a second native List row inset.")
                    for x in [width * 0.7, width - 32] {
                        let point = CGPoint(x: x, y: y)
                        for (observed, expected) in zip(try pixel(actual, at: point), try pixel(reference, at: point)) {
                            XCTAssertLessThanOrEqual(abs(observed - expected), 2,
                                                     "The Sources list cell must not cover the shared settings background.")
                        }
                    }
                }
            }
        }
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
    }

    private func snapshot(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func textFrame(_ text: String, in image: UIImage) throws -> CGRect {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let match = try XCTUnwrap(request.results?.first {
            $0.topCandidates(1).first?.string.contains(text) == true
        }, "Missing visible text: \(text). Observed: \((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | "))")
        let rect = match.boundingBox
        return CGRect(
            x: rect.minX * image.size.width, y: (1 - rect.maxY) * image.size.height,
            width: rect.width * image.size.width, height: rect.height * image.size.height
        )
    }

    private func searchFields(in view: UIView) -> [UISearchTextField] {
        (view as? UISearchTextField).map { [$0] } ?? view.subviews.flatMap { searchFields(in: $0) }
    }

    private func leadingInkEdge(_ image: UIImage, background: UIImage, header: CGRect) throws -> CGFloat {
        let top = max(0, Int(floor(header.minY)) - 2)
        let bottom = min(Int(image.size.height), Int(ceil(header.maxY)) + 2)
        let right = min(Int(image.size.width), Int(ceil(header.maxX)) + 2)
        var leading: Int?
        // Vision's line box can extend beyond the glyphs; ignore faint panel shadows.
        scan: for x in 0..<right {
            for y in top..<bottom {
                let point = CGPoint(x: x, y: y)
                let observed = try pixel(image, at: point)
                let expected = try pixel(background, at: point)
                if zip(observed, expected).contains(where: { abs($0.0 - $0.1) > 40 }) {
                    leading = x
                    break scan
                }
            }
        }
        return CGFloat(try XCTUnwrap(leading, "The source header must have visible text."))
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let crop = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).map(Int.init)
    }

    private func toastSurfaceBottom(in image: UIImage, x: CGFloat? = nil) throws -> CGFloat {
        // Sample the flat surface beside the compact tab pill, which can cover its center during motion.
        for y in stride(from: Int(image.size.height) - 1, through: Int(image.size.height / 2), by: -1) {
            let color = try pixel(image, at: CGPoint(x: x ?? image.size.width / 2 - 60, y: CGFloat(y)))
            if color.allSatisfy({ (50...110).contains($0) }) {
                return CGFloat(y + 1)
            }
        }
        XCTFail("Missing visible toast surface.")
        let attachment = XCTAttachment(image: image)
        attachment.name = "missing-toast-surface"
        attachment.lifetime = .keepAlways
        add(attachment)
        throw NSError(domain: "ToastPresentationTests", code: 1)
    }

    private func captureToastFrame(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func grayToastBounds(in image: UIImage, caption: CGRect) throws -> CGRect {
        func isSurface(_ point: CGPoint) throws -> Bool {
            try pixel(image, at: point).allSatisfy { (50...110).contains($0) }
        }
        let y = Int(caption.midY)
        let xs = try (0..<Int(image.size.width)).filter {
            try isSurface(CGPoint(x: $0, y: y))
        }
        let left = try XCTUnwrap(xs.first)
        let right = try XCTUnwrap(xs.last)
        // The leading inset clears both the rounded corners and the row's content.
        let x = left + 20
        var top = y
        while top > 0, try isSurface(CGPoint(x: x, y: top - 1)) {
            top -= 1
        }
        var bottom = y
        while bottom + 1 < Int(image.size.height),
              try isSurface(CGPoint(x: x, y: bottom + 1)) {
            bottom += 1
        }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { self.tabController(in: $0) }.first
    }
}

@MainActor @Observable
private final class ToastSheetFixtureState {
    var settings = false
    var source = false
    var tab = 0
}

private struct ToastSheetFixture: View {
    let app: PlozziOSAppModel
    @Bindable var state: ToastSheetFixtureState

    var body: some View {
        TabView(selection: $state.tab) {
            Tab("Home", systemImage: "house", value: 0) { Color.white }
            Tab("Live TV", systemImage: "tv", value: 1) { Color.white }
            Tab("Downloads", systemImage: "arrow.down", value: 2) { Color.white }
            Tab("Search", systemImage: "magnifyingglass", value: 3, role: .search) { Color.white }
        }
        .tabViewStyle(.sidebarAdaptable)
        .guidePreparationOverlay(model: app.guidePreparation, presenter: app.transientStatusPresenter, palette: .dark)
        .plozzSheet(isPresented: $state.settings) {
            PlozziOSSettingsView(appModel: app, onClose: { state.settings = false }, systemColorScheme: .dark)
                .plozzSheet(isPresented: $state.source) {
                    NavigationStack {
                        Color.white.navigationTitle("Add TV source")
                    }
                    .guidePreparationOverlay(
                        model: app.guidePreparation, presenter: app.transientStatusPresenter, palette: .dark
                    )
                }
        }
    }
}

@MainActor @Observable
private final class ToastNavigationFixtureState {
    var path: [Int] = []
    var showToast = false
}

private struct ToastNavigationFixture: View {
    @Bindable var state: ToastNavigationFixtureState
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $state.path) {
            List { Text("Settings") }
                .searchable(text: $query, placement: .automatic, prompt: "Search settings")
                .toolbar {
                    if #available(iOS 26.0, *) {
                        DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    }
                }
                .navigationDestination(for: Int.self) { _ in
                    Text("Live TV settings")
                        .navigationTitle("Live TV")
                }
        }
        .adaptiveStatusOverlay(isPresented: state.showToast) {
            if state.showToast {
                Text("Reading guide")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.white)
                    .transientStatusSurface(palette: .dark)
                    .padding(.horizontal, 16)
            }
        }
        .environment(\.horizontalSizeClass, .compact)
    }
}

private struct GuideProgressFixture: View {
    let sources: Bool
    var body: some View {
        VStack {
            if sources {
                let source = LiveTVServerSource(id: "fixture", name: "Live channels", accountID: "account")
                LiveTVServerSourceSummary(source: source, status: .init(source: source))
            } else {
                Text("Live TV")
            }
        }
        .padding()
    }
}

private struct SetupBackgroundFixture: View {
    let showsWelcome: Bool
    @Environment(\.themePalette) private var palette

    var body: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets)
            ZStack(alignment: .topLeading) {
                AppBackground(palette: palette)
                PrototypePreviewScrim(layout: layout, reduceTransparency: false)
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(x: layout.bounds.midX, y: layout.bounds.midY)
                if showsWelcome {
                    PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: geometry.size.width) {
                        LiveTVSetupWelcome(addPlaylist: {}, useServer: {}, createChannel: {})
                    }
                }
            }
        }
    }
}

private struct SourcesFixtureStore: LiveTVSourcesStoring {
    var configuration = LiveTVSourcesConfiguration.empty
    func load() throws -> LiveTVSourcesConfiguration { configuration }
    func save(_ configuration: LiveTVSourcesConfiguration) throws { throw LiveTVSourcesStoreError.saveFailed }
}

private actor SetupGuideProvider: MediaProvider, ServerLiveTVProviding {
    nonisolated let kind = ProviderKind.iptv
    nonisolated let session = UserSession(
        server: .init(id: "setup", name: "Playlist", baseURL: URL(string: "https://fixture.invalid")!, provider: .iptv),
        userID: "playlist", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
    )
    let started: @Sendable () -> Void
    var pending: CheckedContinuation<Void, Never>?
    var resumed = false
    var librariesSuspended: Bool
    var progress: ServerLiveTVGuideProgress.Handler?
    var pendingLibraries: [CheckedContinuation<Void, Never>] = []
    init(started: @escaping @Sendable () -> Void, librariesSuspended: Bool = false) {
        self.started = started
        self.librariesSuspended = librariesSuspended
    }
    func libraries() async -> [MediaLibrary] {
        if librariesSuspended { await withCheckedContinuation { pendingLibraries.append($0) } }
        return []
    }
    func resumeLibraries() {
        librariesSuspended = false
        for continuation in pendingLibraries { continuation.resume() }
        pendingLibraries.removeAll()
    }
    func continueWatching(limit: Int) -> [MediaItem] { [] }
    func latest(limit: Int) -> [MediaItem] { [] }
    func item(id: String) throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) -> MediaPage {
        .init(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    func liveTVAvailability() -> ServerLiveTVAvailability {
        .init(status: .available, channelCount: 1, supportsGuide: true)
    }
    func liveTVChannels() -> [ServerLiveTVChannel] { [.init(id: "one", name: "One")] }
    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async -> [ServerLiveTVProgramme] {
        progress = ServerLiveTVGuideProgress.report
        started()
        if !resumed { await withCheckedContinuation { pending = $0 } }
        return [.init(id: "show", channelID: "one", title: "Show", startDate: from, endDate: to)]
    }
    func emit(_ value: ServerLiveTVGuideProgress) { progress?(value) }
    func resume() {
        resumed = true
        pending?.resume()
        pending = nil
    }
    func openLiveTVChannel(id: String) throws -> any LiveTVStreamLease {
        throw ServerLiveTVError.unsupportedAPI
    }
}
#endif
