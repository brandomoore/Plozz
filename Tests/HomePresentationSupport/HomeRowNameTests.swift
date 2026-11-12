import CoreModels
@testable import FeatureHomeCore
import XCTest

@MainActor
final class HomeRowNameTests: XCTestCase {
    func testNamesPersistPerProfileWithoutChangingLayoutAndSurvivePresetChanges() throws {
        let suite = "HomeRowNames.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HomeLibraryVisibilityStore(defaults: defaults)
        let model = HomeLibraryVisibilityModel(store: store)
        let original = model.visibility
        let id = HomeRowID.global(.continueWatching)
        model.setHomeRowName("  In progress \n", for: id)
        XCTAssertEqual(model.visibility.homeRowName(for: id), "In progress")
        XCTAssertEqual(model.visibility.rowCustomization, original.rowCustomization)
        XCTAssertEqual(model.visibility.disabledKeys, original.disabledKeys)
        XCTAssertEqual(HomeLibraryVisibilityModel(store: store).visibility.homeRowName(for: id), "In progress")
        let other = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults, namespace: "other"))
        XCTAssertNil(other.visibility.homeRowName(for: id))
        other.setHomeRowName("Other profile", for: id)
        XCTAssertEqual(store.load().homeRowName(for: id), "In progress")
        model.useRowDefaults(.combined)
        XCTAssertEqual(model.visibility.homeRowName(for: id), "In progress")
        var arrangement = model.visibility.rowSections(choices: HomeRowChoice.shared)
        arrangement.enabled.removeAll { $0 == id }
        arrangement.disabled.append(id)
        model.applyRows(arrangement, choices: HomeRowChoice.shared)
        XCTAssertEqual(model.visibility.homeRowName(for: id), "In progress")
        arrangement.disabled.removeAll { $0 == id }
        arrangement.enabled.append(id)
        model.applyRows(arrangement, choices: HomeRowChoice.shared)
        XCTAssertEqual(model.visibility.homeRowName(for: id), "In progress")
        let snapshot = ProfileSettingsTransfer.capture(namespace: nil, defaults: defaults)
        ProfileSettingsTransfer.apply(snapshot, namespace: "restored", defaults: defaults)
        XCTAssertEqual(
            HomeLibraryVisibilityStore(defaults: defaults, namespace: "restored").load().homeRowName(for: id),
            "In progress"
        )
        model.setHomeRowName(" \n ", for: id)
        XCTAssertNil(store.load().homeRowName(for: id))
        XCTAssertEqual(other.visibility.homeRowName(for: id), "Other profile")
    }

    func testOldSettingsDecodeAndNamesRoundTripWithoutCreatingAnArrangement() throws {
        var settings = try JSONDecoder().decode(HomeLibraryVisibility.self, from: Data("{}".utf8))
        XCTAssertTrue(settings.homeRowNames.isEmpty)
        XCTAssertNil(settings.rowCustomization)
        let first = HomeRowID.library(key: "a:films", section: "recentlyAdded")
        let second = HomeRowID.library(key: "b:films", section: "recentlyAdded")
        settings.setHomeRowName("Café & 映画 %@", for: first)
        settings.setHomeRowName("Second server", for: second)
        let restored = try JSONDecoder().decode(HomeLibraryVisibility.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertNil(restored.rowCustomization)
        XCTAssertEqual(restored.homeRowName(for: first), "Café & 映画 %@")
        XCTAssertEqual(restored.homeRowName(for: second), "Second server")
    }

    func testRenamingChangesGlobalAndServerHeadingsWithoutChangingFeeds() throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let definition = HomeServerRowDefinition(
            accountID: "server", serverName: "Server", providerKind: .plex,
            section: .init(id: "recommendations", kind: .recommendations, title: "Picks")
        )
        let content = HomeViewModel.Content(
            continueWatching: [item],
            serverRows: [.init(definition: definition, items: [item])]
        )
        var visibility = HomeLibraryVisibility(
            rowCustomization: .init(defaults: .custom, shown: [.global(.continueWatching), definition.id],
                                    serverRows: [definition])
        )
        let raw = HomeRow.rows(for: content, isLibraryVisible: { _ in true })
        let baseline = HomePresentationRow.resolve(rows: raw, content: content, visibility: visibility)
        visibility.setHomeRowName("Keep going", for: .global(.continueWatching))
        visibility.setHomeRowName("Movie night", for: definition.id)
        let renamed = HomePresentationRow.resolve(rows: raw, content: content, visibility: visibility)
        XCTAssertEqual(renamed.map(\.id), baseline.map(\.id))
        let global = try XCTUnwrap(renamed.first { $0.id == .global(.continueWatching) })
        XCTAssertEqual(global.choice.title, "Keep going")
        XCTAssertNil(global.choice.localizedTitle)
        guard case let .home(home) = global.source else { return XCTFail("Expected global row") }
        XCTAssertEqual(home.customTitle, "Keep going")
        XCTAssertEqual(home.items, [item])
        let server = try XCTUnwrap(renamed.first { $0.id == definition.id })
        guard case let .library(row) = server.source else { return XCTFail("Expected server row") }
        XCTAssertEqual(row.section.title, "Movie night")
        XCTAssertNil(row.section.localizedTitle)
        XCTAssertNil(row.section.localizedTitleSuffix)
        XCTAssertEqual(row.section.items, [item])
        XCTAssertEqual(server.choice.serverRow, definition)
        let browser = HomeRowBrowseFactory.make(server, accounts: [], visibility: visibility, isCurrent: { true })
        XCTAssertEqual(browser.title, "Movie night")
        XCTAssertNil(browser.localizedTitle)
        XCTAssertEqual(content.serverRows.first?.definition.section.title, "Picks")
        visibility.setHomeRowName("", for: definition.id)
        XCTAssertEqual(
            HomePresentationRow.resolve(rows: raw, content: content, visibility: visibility)
                .first { $0.id == definition.id }?.choice.title,
            "Picks"
        )
    }

    func testEmptyRowDiagnosticsUseTheCustomHeading() throws {
        let choice = try XCTUnwrap(HomeRowChoice.shared.first { $0.id == .global(.watchlist) })
        var content = HomeViewModel.Content()
        content.sectionIssues = [.init(choice: choice, reason: .empty)]
        var visibility = HomeLibraryVisibility()
        visibility.setHomeRowName("For later", for: choice.id)
        let resolved = try XCTUnwrap(HomePresentationRow.resolve(
            rows: [], content: content, visibility: visibility
        ).first)
        guard case let .library(row) = resolved.source else { return XCTFail("Expected empty row") }
        XCTAssertEqual(row.section.title, "For later")
        XCTAssertEqual(row.issue?.choice.title, "For later")
        XCTAssertEqual(row.issue?.reason, .empty)
        XCTAssertEqual(row.id, choice.id.presentationID)
    }

    func testLibraryRowKeepsBrowseRoutingAndRestoresLocalizedHeading() throws {
        let library = AggregatedLibrary(
            accountID: "a", accountName: "Account", serverName: "Server",
            providerKind: .jellyfin, library: .init(id: "movies", title: "Movies", kind: .movie)
        )
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie)
        let section = LibrarySection(
            id: "picks", title: "Picks", localizedTitle: "Recommended", localizedTitleSuffix: "Movies",
            style: .landscape, items: [item], isHomeDefault: true, isLegacyHomeDefault: false,
            browseID: "provider-picks", hasMore: true
        )
        let content = HomeViewModel.Content(librarySections: [.init(library: library, sections: [section])])
        let id = HomeRowID.library(key: library.key, section: section.id)
        var visibility = HomeLibraryVisibility(rowCustomization: .init(defaults: .custom, shown: [id]))
        visibility.setHomeRowName("Friday favorites", for: id)
        let entry = try XCTUnwrap(HomePresentationRow.resolve(rows: [], content: content, visibility: visibility).first)
        guard case let .library(row) = entry.source else { return XCTFail("Expected library row") }
        XCTAssertEqual(row.section.title, "Friday favorites")
        XCTAssertNil(row.section.localizedTitle)
        XCTAssertNil(row.section.localizedTitleSuffix)
        XCTAssertEqual(row.section.style, .landscape)
        XCTAssertEqual(row.section.items, [item])
        XCTAssertEqual(row.section.browseID, section.browseID)
        XCTAssertEqual(row.section.hasMore, section.hasMore)
        XCTAssertEqual(row.section.isHomeDefault, section.isHomeDefault)
        XCTAssertEqual(row.section.isLegacyHomeDefault, section.isLegacyHomeDefault)
        XCTAssertTrue(entry.canBrowse)
        let browse = HomeRowBrowseFactory.make(entry, accounts: [], visibility: visibility, isCurrent: { true })
        XCTAssertEqual(browse.title, "Friday favorites")
        XCTAssertNil(browse.localizedTitle)
        XCTAssertEqual(content.librarySections.first?.sections.first, section)
        visibility.setHomeRowName("", for: id)
        let restored = try XCTUnwrap(HomePresentationRow.resolve(rows: [], content: content, visibility: visibility).first)
        guard case let .library(original) = restored.source else { return XCTFail("Expected library row") }
        XCTAssertEqual(original.section, section)
    }

    func testLibrariesAndLiveTVNamesFollowTheSamePresentation() throws {
        let library = AggregatedLibrary(
            accountID: "a", accountName: "Account", serverName: "Server",
            providerKind: .plex, library: .init(id: "movies", title: "Movies", kind: .movie)
        )
        let channel = HomeLiveTVChannel(
            route: .init(
                profileID: "profile", channelID: "news", sourceID: "source",
                sourceAuthorizationID: "approval", serverAuthorizationID: "servers"
            ), name: "News", sourceName: "Source", number: 1
        )
        let content = HomeViewModel.Content(libraries: [library])
        var visibility = HomeLibraryVisibility(rowCustomization: .init(defaults: .custom, shown: [.libraries, .liveTV]))
        visibility.setHomeRowName("My media", for: .libraries)
        visibility.setHomeRowName("On air", for: .liveTV)
        let rows = HomePresentationRow.resolve(
            rows: HomeRow.rows(for: content, isLibraryVisible: { _ in true }),
            content: content, visibility: visibility, liveTV: .init(recentChannels: [], channels: [channel])
        )
        let libraries = try XCTUnwrap(rows.first { $0.id == .libraries })
        XCTAssertEqual(libraries.choice.title, "My media")
        guard case let .home(row) = libraries.source else { return XCTFail("Expected libraries row") }
        XCTAssertEqual(row.customTitle, "My media")
        XCTAssertEqual(row.libraries, [library])
        let live = try XCTUnwrap(rows.first { $0.id == .liveTV })
        XCTAssertEqual(live.choice.title, "On air")
        guard case let .liveTV(channels) = live.source else { return XCTFail("Expected live TV row") }
        XCTAssertEqual(channels, [channel])
    }
}
