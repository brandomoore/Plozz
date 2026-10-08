#if os(iOS)
import CoreModels
import CoreUI
import FeatureHomeCore
import Foundation
import MediaDownloads
import SwiftUI
import UIKit
import UserNotifications
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class DownloadNotificationNavigationTests: XCTestCase {
    func testPayloadRoundTripPreservesExactGenerationWithoutMediaOrCredentials() throws {
        let record = record()
        let target = try target(record)
        let encoded = try PropertyListSerialization.data(fromPropertyList: target.userInfo, format: .binary, options: 0)
        let restored = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: encoded, format: nil) as? [AnyHashable: Any]
        )
        XCTAssertEqual(PlozziOSDownloadNotificationTarget(userInfo: restored), target)
        XCTAssertEqual(target.recordCreatedAt, record.createdAt)
        let payload = try XCTUnwrap(restored["plozz.download"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["version", "profile", "item", "createdAt"])
        XCTAssertNil(payload["title"])
        XCTAssertNil(payload["url"])
    }

    func testMalformedAndUnsupportedPayloadsAreRejected() throws {
        let target = try target(record())
        let original = try XCTUnwrap(target.userInfo["plozz.download"] as? [String: Any])
        for (field, value) in [
            ("version", 2), ("profile", ""), ("item", ""), ("createdAt", Double.nan),
            ("createdAt", "yesterday"), ("batch", 42), ("batch", "")
        ] as [(String, Any)] {
            var payload = original
            payload[field] = value
            XCTAssertNil(PlozziOSDownloadNotificationTarget(userInfo: ["plozz.download": payload]), field)
        }
        for field in ["version", "profile", "item", "createdAt"] {
            var payload = original
            payload.removeValue(forKey: field)
            XCTAssertNil(PlozziOSDownloadNotificationTarget(userInfo: ["plozz.download": payload]), field)
        }
        XCTAssertNil(PlozziOSDownloadNotificationTarget(userInfo: [:]))
    }

    func testOnlyTheDefaultTapOfADownloadNotificationNavigates() throws {
        let target = try target(record())
        for action in [UNNotificationDismissActionIdentifier, "pause", "reply"] {
            XCTAssertNil(PlozziOSDownloadNotificationBridge.target(
                actionIdentifier: action, requestIdentifier: "plozz.download.notice", userInfo: target.userInfo
            ))
        }
        XCTAssertNil(PlozziOSDownloadNotificationBridge.target(
            actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: "another.notification",
            userInfo: target.userInfo
        ))
        XCTAssertEqual(PlozziOSDownloadNotificationBridge.target(
            actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: "plozz.download.notice",
            userInfo: target.userInfo
        ), target)
        XCTAssertNil(PlozziOSDownloadNotificationBridge.target(
            actionIdentifier: UNNotificationDefaultActionIdentifier, requestIdentifier: "plozz.download.legacy",
            userInfo: [:]
        ))
    }

    func testColdTapWaitsForAdmissionAndTheProfilesLoadedRegistry() throws {
        let navigation = PlozziOSDownloadNotificationNavigation()
        navigation.receive(try target(record()))
        var resolutions = 0
        func advance(_ context: PlozziOSDownloadNotificationNavigation.Context) {
            navigation.advance(context: context, selectProfile: { _ in XCTFail("The active profile is already authorized") }) { _ in
                resolutions += 1
                return .unavailable
            }
        }
        advance(context(navigation, canEnter: false))
        advance(context(navigation, ready: false))
        XCTAssertNotNil(navigation.pending)
        XCTAssertNil(navigation.presentation)
        XCTAssertEqual(resolutions, 0)
        advance(context(navigation))
        XCTAssertNil(navigation.pending)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(navigation.presentation?.destination, .unavailable)
    }

    func testWarmTapWaitsForActualSheetDismissalBeforeRequestingProfileAccess() throws {
        let navigation = PlozziOSDownloadNotificationNavigation()
        navigation.receive(try target(record()))
        var activations: [String] = []
        let resolve: (PlozziOSDownloadNotificationTarget) -> PlozziOSDownloadNotificationDestination = { _ in
            XCTFail("A different profile must never resolve this download")
            return .unavailable
        }
        navigation.advance(
            context: context(navigation, active: "child", authorized: false, presentationAvailable: false),
            selectProfile: { activations.append($0) }, resolve: resolve
        )
        XCTAssertTrue(activations.isEmpty)
        for _ in 0..<3 {
            navigation.advance(
                context: context(navigation, active: "child", authorized: false),
                selectProfile: { activations.append($0) }, resolve: resolve
            )
        }
        XCTAssertEqual(activations, ["profile"], "Request the ordinary profile gate once, never bypass it or repeatedly reopen it.")
        XCTAssertNil(navigation.presentation)
        navigation.advance(
            context: context(navigation, active: "profile", authorized: false, gate: true),
            selectProfile: { _ in XCTFail("PIN entry is still pending") }, resolve: resolve
        )
        navigation.advance(
            context: context(navigation), selectProfile: { _ in XCTFail("Already unlocked") },
            resolve: { _ in .library }
        )
        XCTAssertEqual(navigation.presentation?.profileID, "profile")
        XCTAssertEqual(navigation.presentation?.destination, .library)
    }

    func testCancellingProfileEntryDiscardsTheTapInsteadOfOpeningItAfterALaterUnlock() throws {
        let navigation = PlozziOSDownloadNotificationNavigation()
        navigation.receive(try target(record()))
        navigation.advance(context: context(navigation, authorized: false), selectProfile: { _ in }) { _ in
            XCTFail("Locked profile"); return .unavailable
        }
        navigation.cancelPending()
        navigation.advance(context: context(navigation), selectProfile: { _ in XCTFail("Cancelled") }) { _ in
            XCTFail("Cancelled"); return .unavailable
        }
        XCTAssertNil(navigation.pending)
        XCTAssertNil(navigation.presentation)
    }

    func testRemovedProfileAndSupersededRequestsCannotOpenAnotherProfilesDownloads() throws {
        let navigation = PlozziOSDownloadNotificationNavigation()
        navigation.receive(try target(record()))
        let obsolete = context(navigation)
        navigation.receive(try target(record(id: "second")))
        navigation.advance(context: obsolete, selectProfile: { _ in XCTFail("Stale request") }) { _ in
            XCTFail("Stale request"); return .unavailable
        }
        XCTAssertNotNil(navigation.pending)
        navigation.advance(context: context(navigation, exists: false), selectProfile: { _ in XCTFail("Deleted profile") }) { _ in
            XCTFail("Deleted profile"); return .unavailable
        }
        XCTAssertNil(navigation.pending)
        XCTAssertNil(navigation.presentation)
        XCTAssertTrue(navigation.profileUnavailable)
    }

    func testTabAndDestinationAreClaimedOnceInOrderAndOnlyByTheAuthorizedProfile() throws {
        let navigation = PlozziOSDownloadNotificationNavigation()
        navigation.receive(try target(record()))
        navigation.advance(context: context(navigation), selectProfile: { _ in XCTFail("Already active") }) { _ in
            .show(id: "series:show", seasonID: nil)
        }
        XCTAssertNil(navigation.claimDestination(profileID: "profile"))
        XCTAssertFalse(navigation.claimTabSelection(profileID: "different"))
        XCTAssertTrue(navigation.claimTabSelection(profileID: "profile"))
        XCTAssertFalse(navigation.claimTabSelection(profileID: "profile"))
        XCTAssertNil(navigation.claimDestination(profileID: "different"))
        XCTAssertEqual(navigation.claimDestination(profileID: "profile"), .show(id: "series:show", seasonID: nil))
        XCTAssertNil(navigation.claimDestination(profileID: "profile"), "Returning to Downloads must not reopen a consumed notification.")
    }

    func testStandaloneTargetsRequireTheSameCompletedGeneration() throws {
        for kind in [MediaItemKind.movie, .episode] {
            let record = record(kind: kind)
            let target = try target(record)
            XCTAssertEqual(
                PlozziOSDownloadNotificationDestination.resolve(target, records: [record]),
                .item(identityKey: record.identityKey, createdAt: record.createdAt)
            )
            XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: []), .unavailable)
            var replacement = record
            replacement.createdAt.addTimeInterval(1)
            XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [replacement]), .unavailable)
            replacement = record
            replacement.status = .downloading
            XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [replacement]), .unavailable)
        }
    }

    func testBatchTargetsTheDownloadedShowAndSeasonEvenIfTheLastEpisodeWasRemoved() throws {
        var first = record(id: "first")
        first.batchID = "season-batch"
        var last = record(id: "last")
        last.batchID = first.batchID
        let target = try target(last, batch: true)
        let show = try XCTUnwrap(PlozziOSDownloadLibrary.make(from: [first, last]).shows.first)
        let season = try XCTUnwrap(show.seasons.first)
        let expected = PlozziOSDownloadNotificationDestination.show(id: show.id, seasonID: season.id)
        XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [first, last]), expected)
        XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [last, first]), expected)
        XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [first]), expected)
        first.batchID = "a-new-batch"
        XCTAssertEqual(PlozziOSDownloadNotificationDestination.resolve(target, records: [first]), .unavailable)
    }

    func testWholeShowBatchOpensTheShowRatherThanTheLastCompletedSeason() throws {
        var first = record(id: "first", season: 1)
        first.batchID = "whole-show"
        var last = record(id: "last", season: 2)
        last.batchID = first.batchID
        let target = try target(last, batch: true)
        XCTAssertEqual(
            PlozziOSDownloadNotificationDestination.resolve(target, records: [last, first]),
            .show(id: "series:show", seasonID: nil)
        )
    }

    func testNativeTabsOpenNotificationOnceInDirectOverflowAndHiddenDownloadsLayouts() async throws {
        let keys = NavigationDestinationDefaults.iOS
        let layouts: [(String, [String])] = [
            ("direct", [NavigationLibraryLayout.downloadsKey, NavigationLibraryLayout.settingsKey]),
            ("overflow", [
                NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey,
                NavigationLibraryLayout.liveTVKey, NavigationLibraryLayout.searchKey,
                NavigationLibraryLayout.settingsKey, NavigationLibraryLayout.downloadsKey,
            ]),
            ("hidden", [NavigationLibraryLayout.homeKey, NavigationLibraryLayout.settingsKey]),
        ]
        for (name, enabled) in layouts {
            let app = PlozziOSAppModel(appAdmissionStore: NotificationAdmissionStore())
            let originalProfileID = app.profiles.activeProfileID
            let profile = app.profiles.add(name: "Notification \(name)", isAwaitingSetup: false)
            let layout = NavigationLibraryLayout(
                order: enabled + keys.filter { !enabled.contains($0) },
                hiddenKeys: Set(keys).subtracting(enabled),
                shownKeys: Set(enabled)
            )
            let layoutStore = NavigationLibraryLayoutStore(namespace: profile.id)
            layoutStore.save(layout)
            app.selectProfile(profile.id)
            app.clearFirstRunStepIfHouseholdSetUp()
            defer {
                PlozziOSDownloadNotificationNavigation.shared.cancelPending()
                app.selectProfile(originalProfileID)
                app.profiles.remove(profile.id)
                layoutStore.save(.default)
            }
            guard app.isActiveProfileAuthorized else {
                XCTFail("The hosted fixture must finish profile setup before exercising notification navigation.")
                return
            }
            try await withTabShell(app) { window in
                let navigation = PlozziOSDownloadNotificationNavigation.shared
                for destination in [
                    PlozziOSDownloadNotificationDestination.unavailable, .unavailable, .library, .unavailable
                ] {
                    navigation.receive(try self.target(self.record(), profileID: profile.id))
                    navigation.advance(
                        context: self.context(navigation, active: profile.id),
                        selectProfile: { _ in XCTFail("The test profile is already active") },
                        resolve: { _ in destination }
                    )
                    try await Task.sleep(for: .milliseconds(300))
                    let expectedDepth = (name == "overflow" ? 2 : 1) + (destination == .library ? 0 : 1)
                    let stack = try await self.waitForNavigation(in: window, depth: expectedDepth)
                    let text = try self.captureText(window, name: "notification-\(name)")
                    XCTAssertEqual(text.contains("removed or replaced"), destination == .unavailable, text)
                    XCTAssertEqual(app.settings.navigation.libraryLayout, layout, "A notification must not overwrite hidden-tab preferences.")
                    XCTAssertEqual(stack.viewControllers.count, expectedDepth, "A second tap resets the Downloads stack rather than stacking copies.")
                }
                let stack = try XCTUnwrap(self.visibleNavigation(in: window))
                stack.popViewController(animated: false)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(stack.viewControllers.count, name == "overflow" ? 2 : 1)
                XCTAssertFalse(try self.captureText(window, name: "notification-\(name)-back").contains("removed or replaced"))
            }
        }
    }

    func testNativeWatchlistIconDoesNotInheritDownloadsIcon() async throws {
        let app = PlozziOSAppModel(appAdmissionStore: NotificationAdmissionStore())
        let originalProfileID = app.profiles.activeProfileID
        let profile = app.profiles.add(name: "Tab icon isolation", isAwaitingSetup: false)
        let store = NavigationLibraryLayoutStore(namespace: profile.id)
        let keys = NavigationDestinationDefaults.iOS
        let order = [
            NavigationLibraryLayout.homeKey, NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.liveTVKey, NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.searchKey, NavigationLibraryLayout.settingsKey,
        ]
        store.save(.init(order: order, hiddenKeys: [], shownKeys: Set(keys)))
        app.selectProfile(profile.id)
        app.clearFirstRunStepIfHouseholdSetUp()
        defer {
            app.selectProfile(originalProfileID)
            app.profiles.remove(profile.id)
            store.save(.default)
        }
        try await withTabShell(app) { window in
            @MainActor func tabs(in controller: UIViewController) -> UITabBarController? {
                if let tabs = controller as? UITabBarController { return tabs }
                return controller.children.lazy.compactMap { tabs(in: $0) }.first
            }
            let controller = try XCTUnwrap(window.rootViewController.flatMap { tabs(in: $0) })
            _ = try self.captureText(window, name: "download-tab-icon-isolation")
            let items = try XCTUnwrap(controller.tabBar.items)
            let watchlist = try XCTUnwrap(items.first { $0.title == "Watchlist" }, "\(items)")
            let downloads = try XCTUnwrap(items.first { $0.title == "Downloads" }, "\(items)")
            let watchlistImage = try XCTUnwrap(watchlist.image)
            let downloadImage = try XCTUnwrap(downloads.image)
            print("TAB_ICONS watchlist=\(watchlistImage) downloads=\(downloadImage)")
            XCTAssertNotEqual(
                watchlistImage.pngData(), downloadImage.pngData(),
                "Watchlist must retain its bookmark instead of inheriting the Downloads image."
            )
        }
    }

    private func withTabShell(
        _ app: PlozziOSAppModel, exercise: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView:
            PlozziOSTabShell(
                appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
                showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
                deferredPairingURL: .constant(nil), systemColorScheme: .dark
            )
            .environment(app)
            .environment(HeroTrailerController())
            .environment(PlozziOSSidebarGeometryModel())
            .environment(\.themePalette, .dark)
            .environment(\.horizontalSizeClass, .compact)
            .environment(\.locale, Locale(identifier: "en"))
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        try await exercise(window)
    }

    private func visibleNavigation(in window: UIWindow) -> UINavigationController? {
        func find(_ controller: UIViewController) -> UINavigationController? {
            if let navigation = controller as? UINavigationController,
               navigation.topViewController?.viewIfLoaded?.window === window { return navigation }
            return controller.children.lazy.compactMap(find).first
        }
        return window.rootViewController.flatMap(find)
    }

    private func waitForNavigation(in window: UIWindow, depth: Int) async throws -> UINavigationController {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            window.layoutIfNeeded()
            if let navigation = visibleNavigation(in: window), navigation.viewControllers.count == depth {
                try await Task.sleep(for: .milliseconds(300))
                return navigation
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let text = try captureText(window, name: "notification-navigation-timeout")
        XCTFail("Expected \(depth) navigation pages; found \(visibleNavigation(in: window)?.viewControllers.count ?? 0). \(text)")
        return try XCTUnwrap(visibleNavigation(in: window))
    }

    private func captureText(_ window: UIWindow, name: String) throws -> String {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func context(
        _ navigation: PlozziOSDownloadNotificationNavigation,
        active: String = "profile", canEnter: Bool = true, authorized: Bool = true,
        gate: Bool = false, ready: Bool = true, exists: Bool = true,
        presentationAvailable: Bool = true
    ) -> PlozziOSDownloadNotificationNavigation.Context {
        .init(
            requestID: navigation.pending?.id, targetExists: exists, activeProfileID: active,
            canEnterApp: canEnter, profileIsAuthorized: authorized, profileGateIsPresented: gate,
            downloadsAreReady: ready, presentationIsAvailable: presentationAvailable
        )
    }

    private func target(
        _ record: DownloadedMediaRecord, batch: Bool = false, profileID: String = "profile"
    ) throws -> PlozziOSDownloadNotificationTarget {
        var payload: [String: Any] = [
            "version": 1, "profile": profileID, "item": record.identityKey,
            "createdAt": record.createdAt.timeIntervalSinceReferenceDate,
        ]
        if batch { payload["batch"] = try XCTUnwrap(record.batchID) }
        return try XCTUnwrap(PlozziOSDownloadNotificationTarget(userInfo: ["plozz.download": payload]))
    }

    private func record(
        id: String = "episode", kind: MediaItemKind = .episode, season: Int = 1
    ) -> DownloadedMediaRecord {
        DownloadedMediaRecord(
            identity: .external(source: "plozz-account:emby", value: id),
            sourceKind: .managedHTTP, status: .completed, localFileName: "media.mkv",
            bytesDownloaded: 100, totalBytes: 100,
            snapshot: .init(
                title: id, kind: kind, sourceAccountID: "emby", sourceItemID: id,
                seriesTitle: "Show", seriesID: "show", seasonNumber: season, episodeNumber: 4
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 813_000_000.1234567)
        )
    }
}

private struct NotificationAdmissionStore: AppAdmissionStoring {
    func loadStandaloneChoice() -> Bool { true }
    func recordStandaloneChoice() {}
    func resetStandaloneChoiceForDebugging() {}
}
#endif
