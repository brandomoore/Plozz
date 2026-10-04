import CoreModels
import Foundation
import XCTest

final class LibraryQueryTests: XCTestCase {
    func testDuplicatesCountsDistinctItemsRatherThanRepeatedReferences() {
        let first = MediaSourceRef(accountID: "account", itemID: "first", kind: .movie)
        let second = MediaSourceRef(accountID: "account", itemID: "second", kind: .movie)
        let duplicate = LibraryQueryRecord(MediaItem(
            id: "first", title: "Movie", kind: .movie, sourceAccountID: "account", sources: [first, second]))
        let repeated = LibraryQueryRecord(MediaItem(
            id: "first", title: "Movie", kind: .movie, sourceAccountID: "account", sources: [first, first]))
        XCTAssertTrue(duplicate.matches(.init(filter: .duplicates)))
        XCTAssertFalse(repeated.matches(.init(filter: .duplicates)))
    }

    func testFilterSummaryNamesSelectedOptionsInsteadOfCountingThem() {
        let locale = Locale(identifier: "en")
        XCTAssertEqual(LibraryFilters.all.summary(in: locale), "")
        for filter in LibraryFilter.allCases where filter != .all {
            var name = filter.displayName
            name.locale = locale
            XCTAssertEqual(LibraryFilters(filter: filter).summary(in: locale), String(localized: name))
        }
        XCTAssertEqual(LibraryFilters(filter: .dolbyVision).summary(in: locale), "Dolby Vision")
        XCTAssertEqual(LibraryFilters(genre: "Science Fiction").summary(in: locale), "Science Fiction")
        XCTAssertEqual(LibraryFilters(year: 2024).summary(in: locale), "2024")
        XCTAssertEqual(LibraryFilters(genre: "Drama", year: 2024).summary(in: locale), "Drama · 2024")
        XCTAssertEqual(LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024).summary(in: locale),
                       "Unwatched · Drama · 2024")
    }

    func testQuickFilterIntersectsGenreAndYear() {
        let item = MediaItem(id: "a", title: "A", kind: .movie, productionYear: 2024,
                             genres: ["Drama"], runtime: 100, resumePosition: 25,
                             librarySortValues: .init(hasAtmos: true))
        let record = LibraryQueryRecord(item)
        XCTAssertTrue(record.matches(.init(filter: .atmos, genre: "drama", year: 2024)))
        XCTAssertFalse(record.matches(.init(filter: .atmos, genre: "Comedy", year: 2024)))
        XCTAssertFalse(record.matches(.init(filter: .atmos, genre: "Drama", year: 2023)))
        XCTAssertTrue(record.matches(.init(filter: .inProgress)))
        XCTAssertEqual(record.progress, 0.25)
    }

    func testCompletionIsDistinctFromResumingAPreviouslyWatchedTitle() {
        let record = LibraryQueryRecord(MediaItem(
            id: "rewatch", title: "Rewatch", kind: .movie, playedPercentage: 0.2,
            librarySortValues: .init(watched: true)
        ))
        XCTAssertFalse(record.matches(.init(filter: .unwatched)))
        XCTAssertTrue(record.matches(.init(filter: .inProgress)))
    }

    func testMissingRatingsStayLastInBothDirectionsAndTiesAreStable() {
        let items = [
            MediaItem(id: "unknown", title: "Unknown", kind: .movie),
            MediaItem(id: "b", title: "Same", kind: .movie, librarySortValues: .init(criticRating: 90)),
            MediaItem(id: "a", title: "Same", kind: .movie, librarySortValues: .init(criticRating: 90))
        ].map { LibraryQueryRecord($0) }
        for direction: SortDirection in [.ascending, .descending] {
            let sort = SortDescriptor(field: .criticRating, direction: direction)
            XCTAssertEqual(items.sorted { $0.isOrdered(before: $1, by: sort) }.map(\.reference.id),
                           ["a", "b", "unknown"])
        }
    }

    func testFullReleaseDatesAndOriginalSortNamesArePreserved() {
        let earlier = MediaItem(id: "e", title: "The Zebra", kind: .movie,
                                releaseDate: Date(timeIntervalSince1970: 100),
                                librarySortValues: .init(sortName: "Zebra"))
        let later = MediaItem(id: "l", title: "Apple", kind: .movie,
                              releaseDate: Date(timeIntervalSince1970: 101))
        XCTAssertTrue(LibraryQueryRecord(earlier).isOrdered(
            before: LibraryQueryRecord(later), by: .init(field: .releaseDate, direction: .ascending)))
        XCTAssertTrue(LibraryQueryRecord(later).isOrdered(before: LibraryQueryRecord(earlier), by: .default))
    }

    func testPageAdvancementKeepsAllQueryOptions() {
        let page = PageRequest(startIndex: 10, limit: 15, sort: .init(field: .plays, direction: .descending),
                               filters: .init(filter: .unwatched, genre: "Drama", year: 2024))
        XCTAssertEqual(page.next().startIndex, 25)
        XCTAssertEqual(page.next().filters, page.filters)
        XCTAssertEqual(page.next().sort, page.sort)
    }

    func testPreferencesAreIsolatedAndAddressesCannotCollide() throws {
        let name = "LibraryQueryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = LibraryBrowsePreferencesStore.address(accountID: "a:b", libraryID: "c", mode: "titles")
        let second = LibraryBrowsePreferencesStore.address(accountID: "a", libraryID: "b:c", mode: "titles")
        XCTAssertNotEqual(first, second)
        let original = LibraryBrowsePreferences(sort: .init(field: .plays, direction: .descending),
                                                filters: .init(filter: .unwatched, genre: "Drama", year: 2024))
        let main = LibraryBrowsePreferencesStore(defaults: defaults)
        let other = LibraryBrowsePreferencesStore(namespace: "other-profile", defaults: defaults)
        main.save(original, at: first)
        XCTAssertEqual(main.preferences(at: first), original)
        XCTAssertNil(main.preferences(at: second))
        XCTAssertNil(other.preferences(at: first))
        other.save(.init(), at: first)
        XCTAssertEqual(main.preferences(at: first), original)
        XCTAssertEqual(other.preferences(at: first), .init())
    }

    func testOldCachedMediaDecodesWithoutNewFacts() throws {
        let data = Data(#"{"id":"old","title":"Old","kind":"movie"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: data).librarySortValues)
    }

    func testCompactProjectionKeepsLocalizedTitleIdentityWithoutArtwork() {
        let item = MediaItem(id: "a", title: "Localized", originalTitle: "Original", kind: .movie,
                             overview: String(repeating: "description", count: 100),
                             posterURL: URL(string: "https://art.test/poster"))
        let projection = LibraryQueryRecord(item).identityItem
        XCTAssertEqual(projection.originalTitle, "Original")
        XCTAssertNil(projection.overview)
        XCTAssertNil(projection.posterURL)
    }
}
