import XCTest
@testable import CoreModels

/// Exercises the provider-agnostic alphabet fast-scroll offset math shared by
/// Jellyfin (`NameLessThan` cumulative offsets) and Plex (`firstCharacter`
/// per-letter counts). All the tricky ascending-vs-descending index arithmetic
/// lives here so it is verified without a network.
final class LibraryLetterIndexTests: XCTestCase {
    func testDeferredTargetsNeverInventOffsets() {
        let entries = LibraryLetterIndex.deferredEntries(direction: .descending)
        XCTAssertEqual(entries.first?.letter, "Z")
        XCTAssertEqual(entries.last?.letter, "#")
        XCTAssertEqual(entries.count, 27)
        XCTAssertTrue(entries.allSatisfy { $0.startIndex == nil })
    }

    func testNonLatinSuffixDoesNotBecomeAFictitiousZBucket() {
        let offsets = Dictionary(uniqueKeysWithValues: LibraryLetterIndex.railLetters.dropFirst().map { ($0, 0) })
        for direction in SortDirection.allCases {
            let entries = LibraryLetterIndex.entries(lessThanOffsetsByLetter: offsets, totalCount: 4,
                                                     lastLetterCount: 0, direction: direction)
            XCTAssertEqual(entries, [.init(letter: "#", startIndex: 0)])
        }
    }

    func testDisjointHashBucketsDoNotShiftInterveningLetters() {
        let buckets: [(String, Int)] = [("#", 2), ("A", 3), ("#", 4), ("Z", 5), ("#", 1)]
        let ascending = LibraryLetterIndex.entries(bucketCountsAscending: buckets, direction: .ascending)
        XCTAssertEqual(ascending, [.init(letter: "#", startIndex: 0),
                                  .init(letter: "A", startIndex: 2), .init(letter: "Z", startIndex: 9)])
        let descending = LibraryLetterIndex.entries(bucketCountsAscending: buckets, direction: .descending)
        XCTAssertEqual(descending, [.init(letter: "#", startIndex: 0),
                                   .init(letter: "Z", startIndex: 1), .init(letter: "A", startIndex: 10)])
    }

    func testDeferredScanStopsAtTargetWithoutFetchingWholeCatalog() async throws {
        let index = try await LibraryLetterIndex.findPosition(pageSize: 20, fetch: { offset, limit in
            XCTAssertLessThanOrEqual(offset, 40)
            XCTAssertEqual(limit, 20)
            return MediaPage(items: (offset..<(offset + limit)).map {
                MediaItem(id: "\($0)", title: "\($0)", kind: .movie)
            }, startIndex: offset, totalCount: 10_000)
        }, matches: { $0.id == "43" })
        XCTAssertEqual(index, 43)
    }

    func testDeferredScanRejectsIncompleteEmptyPage() async {
        do {
            _ = try await LibraryLetterIndex.findPosition(fetch: { offset, _ in
                MediaPage(items: [], startIndex: offset, totalCount: 100)
            }, matches: { _ in false })
            XCTFail("A failed/short source is not an absent letter")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
    }

    func testDeferredScanHonorsCancellation() async {
        let started = expectation(description: "Page requested")
        let task = Task {
            try await LibraryLetterIndex.findPosition(fetch: { offset, _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(5))
                return MediaPage(items: [], startIndex: offset, totalCount: 0)
            }, matches: { _ in false })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled scan returned a result")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    // MARK: bucket(forPrefix:)

    func testBucketMapsLettersCaseInsensitively() {
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "apple"), "A")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "Zoo"), "Z")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "m"), "M")
    }

    func testBucketFoldsDigitsSymbolsAndNonLatinIntoHash() {
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "3 Days"), "#")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "$$$"), "#")
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: ""), "#")
        // A non-Latin first character has no A–Z rail bucket, so it folds to "#".
        XCTAssertEqual(LibraryLetterIndex.bucket(forPrefix: "économie"), "#")
    }

    func testRailLettersAreHashThenAToZ() {
        XCTAssertEqual(LibraryLetterIndex.railLetters.first, "#")
        XCTAssertEqual(LibraryLetterIndex.railLetters.count, 27)
        XCTAssertEqual(LibraryLetterIndex.railLetters.last, "Z")
        XCTAssertEqual(LibraryLetterIndex.railLetters[1], "A")
    }

    // MARK: entries(bucketCountsAscending:direction:)

    func testAscendingBucketsProduceCumulativeOffsetsAndDropEmpties() {
        let buckets: [(letter: String, count: Int)] =
            [("#", 2), ("A", 3), ("B", 0), ("C", 5)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .ascending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "#", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 2),
            LibraryLetterIndexEntry(letter: "C", startIndex: 5)
        ])
    }

    func testDescendingBucketsMirrorOffsets() {
        let buckets: [(letter: String, count: Int)] =
            [("#", 2), ("A", 3), ("B", 0), ("C", 5)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .descending
        )
        // Descending name sort shows C…A…# top-to-bottom; each letter's first
        // item is at total - (itemsUpToAndIncludingIt).
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "C", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 5),
            LibraryLetterIndexEntry(letter: "#", startIndex: 8)
        ])
    }

    func testAllEmptyBucketsProduceNoEntries() {
        let buckets: [(letter: String, count: Int)] = [("#", 0), ("A", 0)]
        XCTAssertTrue(
            LibraryLetterIndex.entries(bucketCountsAscending: buckets, direction: .ascending).isEmpty
        )
    }

    func testNegativeCountsAreClampedToEmpty() {
        let buckets: [(letter: String, count: Int)] = [("A", -5), ("B", 4)]
        let entries = LibraryLetterIndex.entries(
            bucketCountsAscending: buckets, direction: .ascending
        )
        XCTAssertEqual(entries, [LibraryLetterIndexEntry(letter: "B", startIndex: 0)])
    }

    // MARK: entries(lessThanOffsetsByLetter:totalCount:direction:)

    /// `NameLessThan` offsets that describe the same library as the bucket tests
    /// above: 2 items before "A" (the "#" bucket), 3 A's, 0 B's, 5 C's = 10 total.
    private func sampleLessThanOffsets() -> [String: Int] {
        var offsets: [String: Int] = [:]
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            offsets[String(UnicodeScalar(scalar)!)] = 10
        }
        offsets["A"] = 2   // 2 items sort before "A" → "#" bucket size 2
        offsets["B"] = 5   // 3 items in "A"
        offsets["C"] = 5   // 0 items in "B"
        return offsets     // 5 items in "C" (10 - 5), rest empty
    }

    func testLessThanOffsetsAscendingMatchBucketMath() {
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: sampleLessThanOffsets(),
            totalCount: 10, direction: .ascending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "#", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 2),
            LibraryLetterIndexEntry(letter: "C", startIndex: 5)
        ])
    }

    func testLessThanOffsetsDescendingMatchBucketMath() {
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: sampleLessThanOffsets(),
            totalCount: 10, direction: .descending
        )
        XCTAssertEqual(entries, [
            LibraryLetterIndexEntry(letter: "C", startIndex: 0),
            LibraryLetterIndexEntry(letter: "A", startIndex: 5),
            LibraryLetterIndexEntry(letter: "#", startIndex: 8)
        ])
    }

    func testZeroTotalProducesNoEntries() {
        XCTAssertTrue(
            LibraryLetterIndex.entries(
                lessThanOffsetsByLetter: [:], totalCount: 0, direction: .ascending
            ).isEmpty
        )
    }

    func testAllItemsAfterZFallIntoZBucket() {
        // Every item sorts >= "Z" (nothing before any letter): all land in "Z".
        var offsets: [String: Int] = [:]
        for scalar in UnicodeScalar("A").value...UnicodeScalar("Z").value {
            offsets[String(UnicodeScalar(scalar)!)] = 0
        }
        let entries = LibraryLetterIndex.entries(
            lessThanOffsetsByLetter: offsets, totalCount: 4, direction: .ascending
        )
        XCTAssertEqual(entries, [LibraryLetterIndexEntry(letter: "Z", startIndex: 0)])
    }
}
