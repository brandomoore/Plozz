import CoreModels
import XCTest

final class WatchlistBrowsePreferencesTests: XCTestCase {
    private let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    private let later = Date(timeIntervalSince1970: 1_800_000_000)

    func testFiltersIntersectSortingWithoutChangingSourceItems() {
        let items = [
            MediaItem(id: "show", title: "Show", kind: .series),
            MediaItem(id: "movie", title: "Movie", kind: .movie)
        ]
        XCTAssertEqual(WatchlistBrowsePreferences(filter: .movies).items(from: items).map(\.id), ["movie"])
        XCTAssertEqual(WatchlistBrowsePreferences(filter: .shows).items(from: items).map(\.id), ["show"])
        XCTAssertEqual(WatchlistBrowsePreferences.default.items(from: items), items)
        XCTAssertEqual(items.map(\.id), ["show", "movie"])
        XCTAssertTrue(WatchlistBrowsePreferences(filter: .movies).items(from: [items[0]]).isEmpty)
        XCTAssertTrue(WatchlistBrowsePreferences.default.items(from: []).isEmpty)
    }

    func testDateAddedUsesWatchlistDatesNeverLibraryDates() {
        let items = [
            MediaItem(id: "old", title: "Old", kind: .movie, watchlistAddedAt: earlier,
                      librarySortValues: .init(dateAdded: later)),
            MediaItem(id: "unknown", title: "Unknown", kind: .series,
                      librarySortValues: .init(dateAdded: later)),
            MediaItem(id: "new", title: "New", kind: .series, watchlistAddedAt: later,
                      librarySortValues: .init(dateAdded: earlier))
        ]
        XCTAssertEqual(WatchlistBrowsePreferences.default.items(from: items).map(\.id), ["new", "old", "unknown"])
        let ascending = WatchlistBrowsePreferences(sort: .init(field: .dateAdded, direction: .ascending))
        XCTAssertEqual(ascending.items(from: items).map(\.id), ["old", "new", "unknown"])
    }

    func testUndatedAndTiedEntriesRetainProviderOrderInEitherDirection() {
        let items = [
            MediaItem(id: "z", title: "Z", kind: .movie),
            MediaItem(id: "b", title: "B", kind: .movie, watchlistAddedAt: earlier),
            MediaItem(id: "a", title: "A", kind: .series, watchlistAddedAt: earlier),
            MediaItem(id: "y", title: "Y", kind: .series)
        ]
        for direction in SortDirection.allCases {
            let preferences = WatchlistBrowsePreferences(sort: .init(field: .dateAdded, direction: direction))
            XCTAssertEqual(preferences.items(from: items).map(\.id), ["b", "a", "z", "y"])
        }
    }

    func testNameAndReleaseDateUseTheLibraryComparator() {
        let items = [
            MediaItem(id: "2", title: "The Zebra", kind: .movie, releaseDate: earlier, sourceAccountID: "plex"),
            MediaItem(id: "1", title: "An Apple", kind: .series, releaseDate: later, sourceAccountID: "jellyfin"),
            MediaItem(id: "1", title: "An Apple", kind: .movie, sourceAccountID: "plex")
        ]
        for field in [SortField.name, .releaseDate] {
            for direction in SortDirection.allCases {
                let sort = CoreModels.SortDescriptor(field: field, direction: direction)
                XCTAssertEqual(
                    WatchlistBrowsePreferences(sort: sort).items(from: items),
                    items.sorted { MediaItemSortOrder.isOrderedBefore($0, $1, sort: sort) }
                )
            }
        }
    }

    func testPreferencesPersistSeparatelyForEachProfile() throws {
        let suite = "WatchlistBrowsePreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = WatchlistBrowsePreferencesStore(defaults: defaults)
        let other = WatchlistBrowsePreferencesStore(namespace: "other", defaults: defaults)
        let value = WatchlistBrowsePreferences(filter: .shows, sort: .init(field: .name, direction: .descending))
        legacy.save(value)
        XCTAssertEqual(legacy.load(), value)
        XCTAssertEqual(other.load(), .default)
        other.save(.init(filter: .movies))
        XCTAssertEqual(other.load().filter, .movies)
        XCTAssertEqual(legacy.load(), value)
    }

    func testEveryProviderAndMixedServerListsShareTheSameQueriesWithoutIdentityLoss() {
        var mixed: [MediaItem] = []
        for provider in ProviderKind.allCases {
            let items = [
                MediaItem(id: "same-movie-id", title: "Alpha", kind: .movie,
                          watchlistAddedAt: earlier, releaseDate: later),
                MediaItem(id: "same-show-id", title: "Zulu", kind: .series,
                          watchlistAddedAt: later, releaseDate: earlier),
                MediaItem(id: "same-undated-id", title: "Oscar", kind: .movie)
            ].map { item in
                item.selectingSource(.init(accountID: provider.rawValue, itemID: item.id,
                                           kind: item.kind, providerKind: provider))
            }
            mixed += items
            XCTAssertEqual(WatchlistBrowsePreferences(filter: .movies).items(from: items).map(\.title), ["Alpha", "Oscar"])
            XCTAssertEqual(WatchlistBrowsePreferences(filter: .shows).items(from: items).map(\.title), ["Zulu"])
            for direction in SortDirection.allCases {
                for field in WatchlistBrowsePreferences.sortFields {
                    let result = WatchlistBrowsePreferences(sort: .init(field: field, direction: direction)).items(from: items)
                    let expected: [String]
                    switch field {
                    case .dateAdded: expected = direction == .descending ? ["Zulu", "Alpha", "Oscar"] : ["Alpha", "Zulu", "Oscar"]
                    case .releaseDate: expected = direction == .descending ? ["Alpha", "Zulu", "Oscar"] : ["Zulu", "Alpha", "Oscar"]
                    default: expected = direction == .descending ? ["Zulu", "Oscar", "Alpha"] : ["Alpha", "Oscar", "Zulu"]
                    }
                    XCTAssertEqual(result.map(\.title), expected, "\(provider) \(field) \(direction)")
                    XCTAssertTrue(result.allSatisfy { $0.sourceAccountID == provider.rawValue })
                }
            }
        }
        let baseline = mixed
        for filter in WatchlistMediaFilter.allCases {
            for field in WatchlistBrowsePreferences.sortFields {
                let result = WatchlistBrowsePreferences(filter: filter, sort: .init(field: field, direction: .descending))
                    .items(from: mixed)
                let perProvider = filter == .all ? 3 : filter == .movies ? 2 : 1
                XCTAssertEqual(result.count, ProviderKind.allCases.count * perProvider)
                XCTAssertEqual(Set(result.map(\.stablePresentationID)).count, result.count)
                XCTAssertEqual(Set(result.compactMap(\.sourceAccountID)), Set(ProviderKind.allCases.map(\.rawValue)))
            }
        }
        XCTAssertEqual(mixed, baseline)
    }

    func testOldCachesDecodeAndNewDatesRoundTripWithoutChangingIdentity() throws {
        let item = MediaItem(id: "1", title: "Movie", kind: .movie, watchlistAliasID: MediaAliasID(),
                             watchlistAddedAt: later, productionYear: 2023, releaseDate: earlier,
                             sourceAccountID: "server")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let encoded = try encoder.encode(item)
        XCTAssertEqual(try decoder.decode(MediaItem.self, from: encoded), item)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "watchlistAddedAt")
        let decoded = try decoder.decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.watchlistAddedAt)
        XCTAssertEqual(decoded.stablePresentationID, item.stablePresentationID)

        let presentation = try XCTUnwrap(MediaAliasEvidence(item: item)?.presentation)
        XCTAssertEqual(presentation.sanitizedForSync().releaseDate, earlier)
        XCTAssertEqual(try decoder.decode(MediaAliasPresentation.self, from: encoder.encode(presentation)), presentation)
        XCTAssertNil(try decoder.decode(MediaAliasPresentation.self, from: Data(#"{"title":"Old","year":2020}"#.utf8)).releaseDate)
    }
}
