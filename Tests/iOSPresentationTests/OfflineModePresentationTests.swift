#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import FeatureHomeCore
import FeatureProfiles
import MediaDownloads
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppRuntime
@testable import AppShelliOS

@MainActor
final class OfflineModePresentationTests: XCTestCase {
    private func makeApp(
        initiallyOffline: Bool = false, featureFlags: RuntimeFeatureFlags = .buildDefault
    ) throws -> PlozziOSAppModel {
        let previous = UserDefaults.standard.object(forKey: OfflineMode.preferenceKey)
        let previousPolicy = OfflineMode.shared.isEnabled
        UserDefaults.standard.set(initiallyOffline, forKey: OfflineMode.preferenceKey)
        addTeardownBlock {
            UserDefaults.standard.set(previous, forKey: OfflineMode.preferenceKey)
            OfflineMode.shared.setEnabled(previousPolicy)
        }
        let suite = "OfflineModePresentation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let app = PlozziOSAppModel(
            appAdmissionStore: AppAdmissionStore(defaults: defaults),
            accountStore: AccountStore(secureStore: InMemorySecureStore()),
            profileStore: ProfileStore(defaults: defaults),
            runtimeFeatureFlags: featureFlags
        )
        addTeardownBlock { @MainActor in app.downloads.beginProfileTransition() }
        return app
    }

    func testModeTransitionInstallsAnEmptyLocalOverrideAndRestoresNormalRouting() async throws {
        let app = try makeApp()
        XCTAssertFalse(app.isOfflineMode)
        XCTAssertNil(app.accountsProviders.localProviders)
        let initialGeneration = app.offlineModeGeneration
        await app.setOfflineMode(true)
        XCTAssertTrue(app.isOfflineMode)
        XCTAssertTrue(OfflineMode.shared.isEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: OfflineMode.preferenceKey))
        XCTAssertNotNil(app.accountsProviders.localProviders)
        XCTAssertTrue(app.accountsProviders.homeAccounts.isEmpty)
        XCTAssertTrue(app.visibleNavigationLibraries.isEmpty)
        XCTAssertGreaterThan(app.offlineModeGeneration, initialGeneration)
        XCTAssertFalse(app.isChangingOfflineMode)
        XCTAssertNil(app.downloads.initializationError)
        await app.setOfflineMode(false)
        XCTAssertFalse(app.isOfflineMode)
        XCTAssertFalse(OfflineMode.shared.isEnabled)
        XCTAssertNil(app.accountsProviders.localProviders)
        XCTAssertFalse(app.isChangingOfflineMode)
    }

    func testColdLaunchRetainsExplicitOfflineModeWithoutAProfileSetting() throws {
        let app = try makeApp(initiallyOffline: true)
        XCTAssertTrue(app.isOfflineMode)
        XCTAssertTrue(OfflineMode.shared.isEnabled)
        XCTAssertNotNil(app.accountsProviders.localProviders)
        XCTAssertFalse(app.isLiveTVProfileAuthorized)
    }

    func testDisabledFlagIgnoresSavedModeAndRefusesActivationWithoutErasingPreference() async throws {
        var flags = RuntimeFeatureFlags.buildDefault
        flags.set(.offlineMode, enabled: false)
        let app = try makeApp(initiallyOffline: true, featureFlags: flags)
        XCTAssertFalse(app.isOfflineModeAvailable)
        XCTAssertFalse(app.isOfflineMode)
        XCTAssertFalse(OfflineMode.shared.isEnabled)
        XCTAssertNil(app.accountsProviders.localProviders)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: OfflineMode.preferenceKey))
        await app.setOfflineMode(true)
        XCTAssertFalse(app.isOfflineMode)
        XCTAssertFalse(OfflineMode.shared.isEnabled)
        XCTAssertNil(app.accountsProviders.localProviders)
        XCTAssertNoThrow(try OfflineMode.shared.requireNetworkAccess())
    }

    func testModeChangesReplaceTheRetainedHomeModel() async throws {
        let app = try makeApp()
        let shell = PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(),
            onAddServer: {}, showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        )
        let online = shell.sharedHomeViewModel
        await app.setOfflineMode(true)
        let offline = shell.sharedHomeViewModel
        XCTAssertFalse(online === offline)
        XCTAssertTrue(offline === shell.sharedHomeViewModel)
        await app.setOfflineMode(false)
        XCTAssertFalse(offline === shell.sharedHomeViewModel)
    }

    func testDetectedNetworkLossDoesNotEnableDownloadedOnlyMode() {
        let model = PlozziOSOfflineModeModel(isEnabled: false, monitorsConnectivity: false)
        XCTAssertNil(model.notice, "The initial path is unknown, not offline.")
        model.updateNetworkConnection(false)
        XCTAssertEqual(model.notice, .noNetwork)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.generation, 0)
        model.dismissNotice()
        model.updateNetworkConnection(false)
        XCTAssertNil(model.notice, "Repeated path callbacks must not redisplay a dismissed notice.")
        model.updateNetworkConnection(true)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.isEnabled, "A usable LAN must not select downloaded-only browsing.")
        model.updateNetworkConnection(false)
        XCTAssertEqual(model.notice, .noNetwork, "A new outage should be indicated again.")
    }

    func testOfflineNoticeDismissalDoesNotDisableModeAndResetsOnReentry() {
        let model = PlozziOSOfflineModeModel(isEnabled: true, monitorsConnectivity: false)
        XCTAssertEqual(model.notice, .offlineMode)
        model.dismissNotice()
        XCTAssertTrue(model.isEnabled)
        XCTAssertNil(model.notice)
        model.updateNetworkConnection(false)
        model.updateNetworkConnection(true)
        XCTAssertNil(model.notice, "Path changes do not replace the explicit mode notice.")
        model.isEnabled = false
        XCTAssertNil(model.notice)
        model.isEnabled = true
        XCTAssertEqual(model.notice, .offlineMode)
    }

    func testCompactNoticeUsesOneLineAndContentWidthOnPhoneAndTablet() {
        for width in [390.0, 820.0] {
            for notice in [PlozziOSOfflineModeModel.Notice.offlineMode, .noNetwork] {
                let host = UIHostingController(rootView:
                    PlozziOSOfflineStatusNotice(notice: notice, palette: .dark, onDismiss: {})
                        .environment(\.locale, Locale(identifier: "en"))
                        .environment(\.dynamicTypeSize, .large)
                )
                let size = host.sizeThatFits(in: CGSize(width: width - 32, height: 1_000))
                XCTAssertEqual(size.height, 52, accuracy: 1)
                XCTAssertLessThan(size.width, 320, "A short notice must not stretch to the guide-toast width.")
                XCTAssertGreaterThan(size.width, 100)
            }
        }
    }

    func testCompactNoticeExpandsForAccessibilityTextInsteadOfClipping() {
        let host = UIHostingController(rootView:
            PlozziOSOfflineStatusNotice(notice: .noNetwork, palette: .dark, onDismiss: {})
                .environment(\.locale, Locale(identifier: "en"))
                .environment(\.dynamicTypeSize, .accessibility5)
        )
        let size = host.sizeThatFits(in: CGSize(width: 288, height: 1_000))
        XCTAssertLessThanOrEqual(size.width, 288)
        XCTAssertGreaterThan(size.height, 52)
    }

    func testSharedToastKeepsStandardInsetsUnlessCompactIsRequested() {
        let standard = UIHostingController(rootView:
            Color.clear.frame(width: 100, height: 44).transientStatusSurface(palette: .dark)
        ).sizeThatFits(in: CGSize(width: 400, height: 400))
        let compact = UIHostingController(rootView:
            Color.clear.frame(width: 100, height: 44).transientStatusSurface(palette: .dark, style: .compact)
        ).sizeThatFits(in: CGSize(width: 400, height: 400))
        XCTAssertEqual(standard, CGSize(width: 148, height: 76))
        XCTAssertEqual(compact, CGSize(width: 120, height: 52))
    }

    func testOfflineToggleIsANativeAccessibleControlOnPhoneAndTablet() async throws {
        let app = try makeApp(initiallyOffline: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for width in [390.0, 820.0] {
            window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
            window.rootViewController = UIHostingController(rootView:
                NavigationStack {
                    PlozziOSDownloadSettingsView(model: app.downloads, appModel: app)
                }
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
            )
            window.makeKeyAndVisible()
            await settle(window)
            let controls = descendants(window).compactMap { $0 as? UISwitch }
            // SwiftUI owns accessibility identifiers, not the backing UISwitch.
            let toggle = try XCTUnwrap(controls.min {
                $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY
            })
            XCTAssertTrue(toggle.isOn)
            XCTAssertTrue(toggle.isEnabled)
            var ancestor: UIView? = toggle.superview
            while ancestor != nil, !(ancestor is UICollectionViewCell) { ancestor = ancestor?.superview }
            let row = try XCTUnwrap(ancestor as? UICollectionViewCell)
            let toggleFrame = toggle.convert(toggle.alignmentRect(forFrame: toggle.bounds), to: row)
            XCTAssertGreaterThanOrEqual(row.bounds.height, 44)
            XCTAssertGreaterThanOrEqual(row.bounds.height - toggleFrame.height, 24)
            XCTAssertGreaterThanOrEqual(toggleFrame.minY, 8)
            XCTAssertGreaterThanOrEqual(row.bounds.maxY - toggleFrame.maxY, 8)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "offline-mode-control-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            toggle.setOn(false, animated: false)
            toggle.sendActions(for: .valueChanged)
            let deadline = ContinuousClock.now + .seconds(5)
            while (app.isOfflineMode || app.isChangingOfflineMode), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(app.isOfflineMode)
            XCTAssertFalse(app.isChangingOfflineMode)
            await app.setOfflineMode(true)
        }
    }

    func testDownloadSettingsKeepOnlyContextualHelpOnPhoneAndTablet() async throws {
        let app = try makeApp()
        app.downloads.maximumDownloadMegabitsPerSecond = nil
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (size, sizeClass, name) in [
            (CGSize(width: 402, height: 874), UserInterfaceSizeClass.compact, "phone"),
            (CGSize(width: 820, height: 1180), .regular, "tablet")
        ] {
            app.downloads.downloadQuality = .original
            window.frame = CGRect(origin: .zero, size: size)
            await show(
                NavigationStack {
                    PlozziOSDownloadSettingsView(model: app.downloads, appModel: app)
                }.environment(\.horizontalSizeClass, sizeClass),
                in: window
            )
            let top = try recognizedText(in: window)
            XCTAssertTrue(top.contains("Use Cellular"), top)
            XCTAssertTrue(top.contains("Ask Each Time"), top)
            XCTAssertTrue(top.contains("Keeps embedded audio and subtitles"), top)
            XCTAssertFalse(top.contains("All Audio Tracks"), top)
            XCTAssertFalse(top.contains("Text Subtitles"), top)
            XCTAssertFalse(top.contains("Live Activities"), top)
            XCTAssertFalse(top.contains("without transcoding"), top)
            capture(window, name: "download-settings-simplified-\(name)")
            if let scroll = descendants(window).compactMap({ $0 as? UIScrollView })
                .first(where: { $0.contentSize.height > $0.bounds.height }) {
                scroll.setContentOffset(CGPoint(
                    x: 0, y: scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                ), animated: false)
            }
            await settle(window)
            let bottom = try recognizedText(in: window)
            XCTAssertTrue((top + bottom).contains("Season or Show Complete"), top + bottom)
            XCTAssertFalse((top + bottom).contains("About Downloads"), top + bottom)
            XCTAssertFalse((top + bottom).contains("Batch Complete"), top + bottom)
            XCTAssertFalse(bottom.contains("server CPU"), bottom)
            capture(window, name: "download-settings-notifications-\(name)")
            app.downloads.downloadQuality = .hd720
            await show(
                NavigationStack {
                    PlozziOSDownloadSettingsView(model: app.downloads, appModel: app)
                }.environment(\.horizontalSizeClass, sizeClass),
                in: window
            )
            let reducedTop = try recognizedText(in: window)
            if let scroll = descendants(window).compactMap({ $0 as? UIScrollView })
                .first(where: { $0.contentSize.height > $0.bounds.height }) {
                scroll.setContentOffset(CGPoint(
                    x: 0, y: scroll.contentSize.height - scroll.bounds.height
                        + scroll.adjustedContentInset.bottom
                ), animated: false)
            }
            await settle(window)
            let reduced = reducedTop + (try recognizedText(in: window))
            XCTAssertTrue(reduced.contains("Requires server conversion"), reduced)
            XCTAssertTrue(reduced.contains("May include fewer audio and subtitle tracks"), reduced)
            XCTAssertFalse(reduced.contains("Keeps embedded audio"), reduced)
            XCTAssertFalse(reduced.contains("About Downloads"), reduced)
            capture(window, name: "download-settings-reduced-quality-\(name)")
        }
    }

    func testDownloadSelectionShowsTrackLimitsAndOnlyRelevantSourceRestrictions() async throws {
        let app = try makeApp()
        let item = MediaItem(
            id: "movie", title: "Example Movie", kind: .movie,
            versions: [.init(id: "original", height: 1080, sizeBytes: 420_000_000)]
        )
        let selection = EpisodeDownloadSelection(
            items: [item], preferences: app.versionPreferences, capabilities: .default
        )
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (size, sizeClass, name) in [
            (CGSize(width: 402, height: 874), UserInterfaceSizeClass.compact, "phone"),
            (CGSize(width: 820, height: 1180), .regular, "tablet")
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            for (quality, supportsReduced, suffix) in [
                (DownloadQuality.original, true, "original"),
                (.hd720, true, "smaller"),
                (.original, false, "original-only")
            ] {
                await show(
                    PlozziOSDownloadSelectionContent(
                        title: Text("Example Movie"), selection: .constant(selection),
                        quality: .constant(quality), supportsReducedQuality: supportsReduced,
                        availableSpace: "72 GB", isBulk: false,
                        onCancel: {}, onDownload: {}
                    ).environment(\.horizontalSizeClass, sizeClass),
                    in: window
                )
                let text = try recognizedText(in: window)
                XCTAssertTrue(text.contains("Available external text subtitles are saved too"), text)
                XCTAssertEqual(text.contains("Only Original is available for this source"), !supportsReduced, text)
                XCTAssertEqual(text.contains("Keeps embedded audio and subtitles"), quality == .original, text)
                XCTAssertEqual(text.contains("Requires server conversion"), quality != .original, text)
                XCTAssertEqual(text.contains("May include fewer audio and subtitle tracks"), quality != .original, text)
                XCTAssertTrue(text.contains("Quality"), text)
                capture(window, name: "download-selection-\(name)-\(suffix)")
            }
        }
    }

    private func recognizedText(in window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    func testOfflineScreensInContext() async throws {
        let app = try makeApp(initiallyOffline: true)
        let originalTheme = app.settings.theme.theme
        app.settings.theme.theme = .dark
        defer { app.settings.theme.theme = originalTheme }
        let accountID = "offline-preview-\(UUID())"
        try app.accountStore.add(Account(
            id: accountID,
            server: .init(id: accountID, name: "Home server", baseURL: URL(string: "https://fixture.invalid")!, provider: .jellyfin),
            userID: "preview", userName: "Alex", deviceID: "preview"
        ), token: "FIXTURE")
        app.accountsProviders.reloadAccounts()
        var profile = app.profiles.activeProfile
        profile.name = "Alex"
        app.profiles.update(profile)
        app.profiles.markFirstRunProfileSetupComplete()
        app.selectProfile(profile.id)
        _ = app.profiles.add(name: "Sam", avatarSymbol: "person.fill", colorIndex: 2, isAwaitingSetup: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (size, sizeClass, name) in [
            (CGSize(width: 402, height: 874), UserInterfaceSizeClass.compact, "phone"),
            (CGSize(width: 1024, height: 1366), .regular, "tablet")
        ] {
            window.frame = CGRect(origin: .zero, size: size)
            await show(
                PlozziOSSettingsView(appModel: app, onClose: {}, systemColorScheme: .dark)
                    .environment(\.horizontalSizeClass, sizeClass),
                in: window
            )
            capture(window, name: "offline-context-settings-\(name)")
            await show(
                NavigationStack {
                    PlozziOSDownloadSettingsView(model: app.downloads, appModel: app)
                }
                    .offlineStatusOverlay(appModel: app, palette: .dark)
                    .environment(\.horizontalSizeClass, sizeClass),
                in: window
            )
            try await revealOfflineToggle(in: window)
            capture(window, name: "offline-context-download-settings-\(name)")
            await show(PlozziOSProfileSelectionView(appModel: app, onComplete: {})
                .environment(\.horizontalSizeClass, sizeClass), in: window)
            capture(window, name: "offline-context-profiles-\(name)")
        }
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        await show(PlozziOSRootView(appModel: app).environment(\.horizontalSizeClass, .compact), in: window)
        capture(window, name: "offline-context-home-status")
        for destination in ["discover", "liveTV"] {
            app.screenshotDirector.tab = destination
            await settle(window)
            capture(window, name: "offline-context-\(destination)")
        }
        await show(
            NavigationStack {
                PlozziOSServersSettingsView(appModel: app, onAddServer: {})
            }
            .environment(app.profiles)
            .transientStatusOverlay(presenter: app.transientStatusPresenter, palette: .dark),
            in: window
        )
        app.transientStatusPresenter.present(icon: "wifi.slash", text: "Unavailable in Offline Mode.")
        await settle(window)
        capture(window, name: "offline-context-add-source")
        app.transientStatusPresenter.dismiss()

        let plexID = "offline-pin-preview-\(UUID())"
        try app.accountStore.add(Account(
            id: plexID,
            server: .init(id: plexID, name: "Plex", baseURL: URL(string: "https://fixture.invalid")!, provider: .plex),
            userID: "owner", userName: "Alex", deviceID: "preview"
        ), token: "FIXTURE")
        app.accountsProviders.reloadAccounts()
        app.profiles.update(app.profiles.activeProfile.settingHomeUserBinding(
            .init(homeUserID: "alex", name: "Alex", requiresPIN: true, pinRequirementVerified: true),
            forPlexAccount: plexID
        ))
        app.profiles.setActiveAccountIDs([plexID], for: app.profiles.activeProfileID)
        app.plexHomeUsers.ensurePlexIdentityForActiveProfile()
        await app.plexHomeUsers.waitForPlexPINRequirementCheck()
        XCTAssertNotNil(app.plexHomeUsers.plexPINError)
        await show(PlozziOSProfileAccessGateView(appModel: app, profile: app.profiles.activeProfile, onCancel: {}), in: window)
        capture(window, name: "offline-context-sign-in-required")
    }

    private func show<Content: View>(_ content: Content, in window: UIWindow) async {
        window.rootViewController = UIHostingController(rootView:
            content.environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: "en"))
        )
        window.makeKeyAndVisible()
        await settle(window)
    }

    private func settle(_ window: UIWindow) async {
        try? await Task.sleep(for: .milliseconds(700))
        window.layoutIfNeeded()
    }

    private func revealOfflineToggle(in window: UIWindow) async throws {
        for _ in 0..<12 {
            if let toggle = descendants(window).compactMap({ $0 as? UISwitch }).first(where: {
                $0.accessibilityIdentifier == "offline-mode-toggle"
                    && window.bounds.insetBy(dx: 0, dy: 80).contains($0.convert($0.bounds, to: window))
            }) {
                XCTAssertTrue(toggle.isOn)
                return
            }
            for scroll in descendants(window).compactMap({ $0 as? UIScrollView }) where scroll.contentSize.height > scroll.bounds.height {
                let maximum = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + 180)), animated: false)
            }
            await settle(window)
        }
        XCTFail("Offline Mode must be visible in its real settings section.")
    }

    private func capture(_ window: UIWindow, name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
#endif
