#if canImport(UIKit) && canImport(SwiftUI)
import CoreModels
import SwiftUI
import UIKit
import XCTest
@testable import FeatureSettings

@MainActor
final class NavigationLibrariesDetailViewTests: XCTestCase {
    func testNavigationEditorRendersInAListWithoutAnEnvironmentModel() async throws {
        let suite = "NavigationLibrariesDetailViewTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = makeScope(defaults: defaults, profileID: "profile")
        let navigation = makeNavigation(defaults: defaults, profileID: "profile")
        let editor = NavigationLibrariesDetailView(
            scope: scope, navigation: navigation, includesIndividualLibraries: false
        )
        let host = UIHostingController(rootView: List { editor })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await Task.yield()
        host.view.layoutIfNeeded()
        XCTAssertFalse(host.view.subviews.isEmpty)
        navigation.showsWatchlist = false
        await Task.yield()
        host.view.layoutIfNeeded()
        XCTAssertFalse(navigation.showsWatchlist)
    }

    func testEditorKeepsItsExplicitProfileModelWhenTheAncestorHasAnotherModel() async throws {
        let suite = "NavigationLibrariesDetailViewTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = makeNavigation(defaults: defaults, profileID: "first")
        let second = makeNavigation(defaults: defaults, profileID: "second")
        let editor = NavigationLibrariesDetailView(
            scope: makeScope(defaults: defaults, profileID: "second"),
            navigation: second, includesIndividualLibraries: false
        )
        let host = UIHostingController(rootView: List { editor }.environment(first))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        await Task.yield()
        XCTAssertTrue(editor.navigation === second)
        editor.navigation.showsWatchlist = false
        await Task.yield()
        host.view.layoutIfNeeded()
        XCTAssertTrue(first.showsWatchlist)
        XCTAssertFalse(second.showsWatchlist)
        XCTAssertFalse(makeNavigation(defaults: defaults, profileID: "second").showsWatchlist)
    }

    private func makeNavigation(defaults: UserDefaults, profileID: String) -> NavigationStyleSettingsModel {
        NavigationStyleSettingsModel(
            store: NavigationStyleSettingsStore(defaults: defaults, namespace: profileID),
            layoutStore: NavigationLibraryLayoutStore(defaults: defaults, namespace: profileID)
        )
    }

    private func makeScope(defaults: UserDefaults, profileID: String) -> ProfileLibrariesScope {
        ProfileLibrariesScope(
            accounts: [], activeProfile: Profile(id: profileID, name: "Profile"),
            discoveredLibraries: .loaded([]),
            refreshingLibraryAccountIDs: [], unreachableLibraryAccountIDs: [],
            reloadLibraries: {},
            homeVisibility: HomeLibraryVisibilityModel(
                store: HomeLibraryVisibilityStore(defaults: defaults, namespace: profileID)
            ),
            isAccountIncludedInActiveProfile: { _ in false },
            onSetAccountIncluded: { _, _ in }, onAddAccount: {},
            plexHomeUsersFetcher: { _ in [] }, onSelectPlexHomeUser: { _, _ in }
        )
    }
}
#endif
