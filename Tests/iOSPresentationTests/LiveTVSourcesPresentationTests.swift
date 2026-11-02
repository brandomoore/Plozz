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
    func testGuideProgressMovesFromInlineToToastAndExpiresAfterCompletion() async throws {
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
        func render(inline: Bool) {
            host.rootView = AnyView(
                GuideProgressFixture(model: preparation, inline: inline)
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
        render(inline: true)
        await provider.emit(.init(stage: .downloading, completed: 2_500_000, total: 10_000_000))
        try await settle(window)
        XCTAssertNil(preparation.notificationStatus)
        var text = try visibleText()
        XCTAssertEqual(text.components(separatedBy: "Downloading guide").count - 1, 1, text)
        render(inline: false)
        try await settle(window)
        XCTAssertNotNil(preparation.notificationStatus)
        text = try visibleText()
        XCTAssertTrue(text.contains("Downloading guide"), text)
        XCTAssertTrue(text.contains("25%"), text)
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
}

private struct GuideProgressFixture: View {
    let model: LiveTVGuidePreparationModel
    let inline: Bool
    var body: some View {
        VStack {
            if inline, let status = model.statuses["account"] {
                LiveTVGuidePreparationStatus(status: status)
            }
            Text("Live TV")
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
