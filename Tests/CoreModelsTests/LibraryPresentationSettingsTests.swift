import XCTest
@testable import CoreModels

final class LibraryPresentationSettingsTests: XCTestCase {
    func testPopupDurationStepsFromZeroToTenAndZeroNeverTimesOut() {
        XCTAssertEqual(LibraryPresentationSettings.popupDurationChoices, [0, 2, 4, 6, 8, 10])
        var settings = LibraryPresentationSettings()
        XCTAssertEqual(settings.seeAllPopupDuration, 0, "Existing profiles keep pop-ups until focus moves")
        XCTAssertNil(settings.popupHideAfter)
        settings.seeAllPopupDuration = 6
        XCTAssertEqual(settings.popupHideAfter, .seconds(6))
        XCTAssertEqual(LibraryPresentationSettings(seeAllPopupDuration: 99).seeAllPopupDuration, 10)
        XCTAssertEqual(LibraryPresentationSettings(seeAllPopupDuration: 3.1).seeAllPopupDuration, 4)
        let decoded = try? JSONDecoder().decode(
            LibraryPresentationSettings.self,
            from: JSONEncoder().encode(LibraryPresentationSettings(seeAllPopupDuration: 8)))
        XCTAssertEqual(decoded?.seeAllPopupDuration, 8)
        let legacy = try? JSONDecoder().decode(LibraryPresentationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy?.seeAllPopupDuration, 0)
    }

    func testDefaultsAndMissingFieldsPreserveExistingLibraryPresentation() throws {
        let settings = try JSONDecoder().decode(LibraryPresentationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, .default)
        XCTAssertEqual(settings.visibleModes(supported: LibraryContentMode.allCases), LibraryContentMode.allCases)
        XCTAssertEqual(settings.logoSize, .default)
        let rows = [LibrarySection(id: "recent", title: "Recent"), .init(id: "hub", title: "Discovery")]
        XCTAssertEqual(settings.visibleRows(rows, at: "library"), rows)
    }

    func testSeeAllPopupDefaultsToPlainGridAndClampsDelayToOneThroughFive() throws {
        let settings = LibraryPresentationSettings.default
        XCTAssertEqual(settings.seeAllLayout, .grid)
        XCTAssertEqual(settings.seeAllPopupDelay, 2.0)
        XCTAssertNil(settings.seeAllPopupDelayIfEnabled)

        var popup = LibraryPresentationSettings(seeAllLayout: .gridWithPopup, seeAllPopupDelay: 9)
        XCTAssertEqual(popup.seeAllPopupDelay, 5)
        XCTAssertEqual(popup.seeAllPopupDelayIfEnabled, .seconds(5))
        popup.seeAllPopupDelay = 0
        XCTAssertEqual(popup.seeAllPopupDelayIfEnabled, .seconds(0.5))
        popup.seeAllPopupDelay = 1.3
        XCTAssertEqual(popup.seeAllPopupDelayIfEnabled, .seconds(1.5))
        XCTAssertEqual(LibraryPresentationSettings.popupDelayChoices.count, 10)

        let decoded = try JSONDecoder().decode(
            LibraryPresentationSettings.self, from: JSONEncoder().encode(LibraryPresentationSettings(
                seeAllLayout: .gridWithPopup, seeAllPopupDelay: 4.5)))
        XCTAssertEqual(decoded.seeAllLayout, .gridWithPopup)
        XCTAssertEqual(decoded.seeAllPopupDelay, 4.5)
    }

    func testSharedNavigationPreservesUnsupportedIntentAndAlwaysLeavesAnExit() {
        var settings = LibraryPresentationSettings(
            navigation: .init(order: ["playlists", "collections", "titles", "recommended"], hidden: ["titles"])
        )
        XCTAssertEqual(settings.visibleModes(supported: [.recommended, .titles, .collections]), [.collections, .recommended])
        XCTAssertEqual(settings.visibleModes(supported: [.titles]), [.titles])
        XCTAssertEqual(settings.navigation.hidden, ["titles"])
        settings.navigation.hidden = Set(LibraryContentMode.allCases.map(\.rawValue))
        XCTAssertEqual(settings.visibleModes(supported: [.recommended, .titles, .collections]), [.titles])
    }

    func testEditingLiveRowsRetainsUnavailableRowsAndHiddenState() {
        var layout = LibraryContentLayout(order: ["first", "offline", "last"], hidden: ["offline", "first"])
        layout.apply(.init(enabled: ["last"], disabled: ["first"]), available: ["first", "last"])
        XCTAssertEqual(layout.order, ["last", "offline", "first"])
        XCTAssertEqual(layout.hidden, ["offline", "first"])
        XCTAssertEqual(
            layout.sections(available: ["first", "offline", "last", "new"]),
            .init(enabled: ["last", "new"], disabled: ["offline", "first"])
        )
    }

    func testRowsAreAccountAndLibraryQualified() {
        let a = LibraryPresentationSettings.rowAddress(accountID: "a:b", libraryID: "c")
        let b = LibraryPresentationSettings.rowAddress(accountID: "a", libraryID: "b:c")
        let c = LibraryPresentationSettings.rowAddress(accountID: "a:b", libraryID: "other")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        let settings = LibraryPresentationSettings(
            recommendedRows: [a: .init(order: ["recent", "watching"], hidden: ["watching"])]
        )
        let rows = [LibrarySection(id: "watching", title: "Watching"), .init(id: "recent", title: "Recent")]
        XCTAssertEqual(settings.visibleRows(rows, at: a).map(\.id), ["recent"])
        XCTAssertEqual(settings.visibleRows(rows, at: b), rows)
        XCTAssertEqual(settings.visibleRows(rows, at: c), rows)
    }

    @MainActor
    func testProfileStorageTransferResetAndIndependentLogoSizes() throws {
        let suite = "LibraryPresentationSettingsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LibraryPresentationSettingsModel(
            store: LibraryPresentationSettingsStore(defaults: defaults, namespace: "one")
        )
        model.settings.logoSize = HeroLogoSize(rawValue: 10)
        model.settings.navigation = .init(order: ["titles", "recommended"], hidden: ["collections"])
        model.settings.recommendedRows["library"] = .init(order: ["recent", "hub"], hidden: ["hub"])
        model.settings.collectionCoverLayouts["covers"] = .landscape
        XCTAssertEqual(LibraryPresentationSettingsStore(defaults: defaults, namespace: "one").load(), model.settings)
        XCTAssertEqual(LibraryPresentationSettingsStore(defaults: defaults, namespace: "two").load(), .default)
        XCTAssertEqual(HeroSettingsStore(defaults: defaults, namespace: "one").load().showcaseLogoSize, .default)
        XCTAssertEqual(DetailPageSettingsStore(defaults: defaults, namespace: "one").load().logoSize, .default)
        let snapshot = ProfileSettingsTransfer.capture(namespace: "one", defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "two", defaults: defaults)
        XCTAssertEqual(LibraryPresentationSettingsStore(defaults: defaults, namespace: "two").load(), model.settings)
        model.settings.recommendedRows.removeValue(forKey: "library")
        XCTAssertEqual(model.settings.logoSize.rawValue, 10)
        XCTAssertEqual(model.settings.navigation.hidden, ["collections"])
        XCTAssertNotNil(LibraryPresentationSettingsStore(defaults: defaults, namespace: "two").load().recommendedRows["library"])
    }

    func testCollectionCoverOverridesAreGroupQualifiedAndDefaultToAuto() {
        let addresses = [
            LibraryPresentationSettings.collectionCoverAddress(accountID: "a:b", libraryID: "c"),
            LibraryPresentationSettings.collectionCoverAddress(accountID: "a", libraryID: "b:c"),
            LibraryPresentationSettings.collectionCoverAddress(accountID: "a:b", libraryID: "c", rowID: "hub"),
            LibraryPresentationSettings.collectionCoverAddress(for: .library(key: "a:b:c", section: "hub"))
        ]
        XCTAssertEqual(Set(addresses).count, addresses.count)
        var settings = LibraryPresentationSettings.default
        settings.collectionCoverLayouts[addresses[0]] = .landscape
        XCTAssertEqual(settings.collectionCoverLayout(at: addresses[0]), .landscape)
        for address in addresses.dropFirst() {
            XCTAssertEqual(settings.collectionCoverLayout(at: address), .auto)
        }
    }
}
