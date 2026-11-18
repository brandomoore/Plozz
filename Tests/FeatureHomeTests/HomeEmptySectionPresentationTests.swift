import XCTest
import CoreModels
@testable import FeatureHomeCore

@MainActor
final class HomeEmptySectionPresentationTests: XCTestCase {
    private func definition(_ id: String, account: String = "server") -> HomeServerRowDefinition {
        .init(
            accountID: account, serverName: "Media server", providerKind: .silo,
            section: .init(id: id, kind: .recommendations, title: id)
        )
    }

    private func issue(_ row: HomeServerRowDefinition, reason: HomeSectionIssue.Reason = .empty) -> HomeSectionIssue {
        .init(choice: HomeRowChoice(serverRow: row), reason: reason)
    }

    private func visibility(_ rows: [HomeServerRowDefinition]) -> HomeLibraryVisibility {
        .init(rowCustomization: .init(
            defaults: .custom, order: rows.map(\.id), shown: Set(rows.map(\.id)), serverRows: rows
        ))
    }

    func testDismissalHidesOnlyTheSelectedEmptyRowWithoutChangingItsEnabledState() {
        let seasonal = definition("seasonal")
        let another = definition("another")
        let otherAccount = definition("seasonal", account: "other")
        var settings = visibility([seasonal, another, otherAccount])
        settings.dismissedEmptyHomeRows = [seasonal.id]
        var content = HomeViewModel.Content()
        content.sectionIssues = [issue(seasonal), issue(another), issue(otherAccount)]
        let rows = HomePresentationRow.resolve(rows: [], content: content, visibility: settings)
        XCTAssertEqual(rows.map(\.id), [another.id, otherAccount.id])
        XCTAssertTrue(settings.isHomeRowVisible(HomeRowChoice(serverRow: seasonal)))
        XCTAssertEqual(content.sectionIssues.count, 3, "The editor retains completed-load evidence.")
    }

    func testDismissedRowReturnsWithContentAndHidesAgainOnlyWhenEmpty() throws {
        let seasonal = definition("seasonal")
        var settings = visibility([seasonal])
        settings.dismissedEmptyHomeRows = [seasonal.id]
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        var content = HomeViewModel.Content(serverRows: [.init(definition: seasonal, items: [item])])
        content.sectionIssues = [issue(seasonal)]
        let rows = HomePresentationRow.resolve(rows: [], content: content, visibility: settings)
        XCTAssertEqual(rows.map(\.id), [seasonal.id])
        guard case let .library(row) = try XCTUnwrap(rows.first).source else {
            return XCTFail("Expected the populated row.")
        }
        XCTAssertEqual(row.section.items, [item])
        content.serverRows = [.init(definition: seasonal, items: [])]
        XCTAssertTrue(HomePresentationRow.resolve(rows: [], content: content, visibility: settings).isEmpty)
    }

    func testDismissalAndShowcaseNeverHideFailuresOrLoadingContent() {
        let seasonal = definition("seasonal")
        var settings = visibility([seasonal])
        settings.dismissedEmptyHomeRows = [seasonal.id]
        for reason: HomeSectionIssue.Reason in [.failed(.serverUnreachable), .notReturned, .sourceUnavailable] {
            var content = HomeViewModel.Content()
            content.sectionIssues = [issue(seasonal, reason: reason)]
            for showsMessages in [false, true] {
                let rows = HomePresentationRow.resolve(
                    rows: [], content: content, visibility: settings, showsEmptySectionMessages: showsMessages
                )
                XCTAssertEqual(rows.map(\.id), [seasonal.id])
            }
        }
        var loading = HomeViewModel.Content(serverRows: [
            .init(definition: seasonal, items: [], isLoading: true)
        ])
        loading.sectionIssues = [issue(seasonal)]
        XCTAssertEqual(HomePresentationRow.resolve(
            rows: [], content: loading, visibility: settings, showsEmptySectionMessages: false
        ).map(\.id), [seasonal.id])
    }

    func testShowcaseOmitsConfirmedEmptyRowsWithoutSavingADismissal() {
        let seasonal = definition("seasonal")
        let settings = visibility([seasonal])
        var content = HomeViewModel.Content()
        content.sectionIssues = [issue(seasonal)]
        XCTAssertTrue(HomePresentationRow.resolve(
            rows: [], content: content, visibility: settings, showsEmptySectionMessages: false
        ).isEmpty)
        XCTAssertEqual(HomePresentationRow.resolve(
            rows: [], content: content, visibility: settings
        ).map(\.id), [seasonal.id])
        XCTAssertTrue(settings.dismissedEmptyHomeRows.isEmpty)
    }

    func testSharedLoadingPlaceholdersSurviveAnEarlierEmptyResult() throws {
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.watchlist) })
        let settings = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, shown: [choice.id]),
            dismissedEmptyHomeRows: [choice.id]
        )
        var content = HomeViewModel.Content()
        content.sectionIssues = [.init(choice: choice, reason: .empty)]
        let rows = HomePresentationRow.resolve(
            rows: [.init(kind: .watchlist, loadingPlaceholderCount: 8)],
            content: content, visibility: settings, showsEmptySectionMessages: false
        )
        guard case let .home(row) = try XCTUnwrap(rows.first).source else {
            return XCTFail("Keep the active loading row.")
        }
        XCTAssertEqual(row.loadingPlaceholderCount, 8)
    }

    func testDismissalPersistsPerProfileAndCanBeRestored() throws {
        let name = "HomeEmptySectionPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HomeLibraryVisibilityStore(defaults: defaults, namespace: "one")
        let other = HomeLibraryVisibilityStore(defaults: defaults, namespace: "two")
        let row = definition("seasonal")
        let initial = visibility([row])
        store.save(initial)
        let model = HomeLibraryVisibilityModel(store: store)
        model.setEmptyHomeRowDismissed(true, id: row.id)
        let restored = HomeLibraryVisibilityModel(store: store)
        XCTAssertEqual(restored.visibility.dismissedEmptyHomeRows, [row.id])
        XCTAssertEqual(restored.visibility.rowCustomization, initial.rowCustomization)
        XCTAssertTrue(other.load().dismissedEmptyHomeRows.isEmpty)
        restored.setEmptyHomeRowDismissed(false, id: row.id)
        XCTAssertEqual(store.load(), initial)
    }

    func testLegacySettingsDoNotDismissMessagesAndNewSettingsRoundTrip() throws {
        let legacy = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.dismissedEmptyHomeRows.isEmpty)
        var settings = visibility([definition("seasonal")])
        settings.dismissedEmptyHomeRows = [definition("seasonal").id]
        XCTAssertEqual(
            try JSONDecoder().decode(HomeLibraryVisibility.self, from: JSONEncoder().encode(settings)), settings
        )
    }
}
