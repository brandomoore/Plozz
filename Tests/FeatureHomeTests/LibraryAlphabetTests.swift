import CoreModels
import XCTest
@testable import FeatureHome

@MainActor
final class LibraryAlphabetTests: XCTestCase {
    private func model(_ provider: FakeMediaProvider) -> LibraryBrowseViewModel {
        LibraryBrowseViewModel(provider: provider, containerID: "movies", containerKind: .movie,
                               pageSize: 10, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func provider(count: Int = 100) -> FakeMediaProvider {
        let provider = FakeMediaProvider(allItems: (0..<count).map {
            MediaItem(id: "\($0)", title: "Movie \($0)", kind: .movie)
        })
        provider.alphabetEntries = [.init(letter: "A", startIndex: 0), .init(letter: "M", startIndex: 75)]
        return provider
    }

    private func waitForIndex(_ vm: LibraryBrowseViewModel) async {
        for _ in 0..<100 {
            if !vm.alphabet.isLoading { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Alphabet index did not finish")
    }

    func testNativeJumpLoadsLandingPageAndCanRepeatSameDestination() async {
        let source = provider()
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        XCTAssertEqual(source.requestedPages.count, 1)
        let index = await vm.jumpToLetter("M")
        XCTAssertEqual(index, 75)
        XCTAssertNotNil(vm.item(at: 75))
        let first = vm.alphabet.destination
        let repeated = await vm.jumpToLetter("M")
        XCTAssertEqual(repeated, 75)
        XCTAssertNotEqual(first?.id, vm.alphabet.destination?.id)
        XCTAssertNil(vm.alphabet.jumpingTo)
    }

    func testSmallLibraryStillExposesItsAlphabet() async {
        let source = provider(count: 2)
        source.alphabetEntries = [.init(letter: "A", startIndex: 0), .init(letter: "B", startIndex: 1)]
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        XCTAssertTrue(vm.alphabet.isVisible)
        XCTAssertTrue(vm.showsLetterRail)
    }

    func testViewportCallbacksDoNotPruneThePendingLandingPage() async {
        let source = provider()
        let started = expectation(description: "Landing page requested")
        source.pageHooks[70] = {
            started.fulfill()
            try await Task.sleep(for: .milliseconds(100))
        }
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        let jump = Task { await vm.jumpToLetter("M") }
        await fulfillment(of: [started], timeout: 1)
        await vm.itemAppeared(at: 0)
        let result = await jump.value
        XCTAssertEqual(result, 75)
        XCTAssertFalse(source.cancelledPageStartIndices.contains(70))
    }

    func testDeferredJumpCancellationAndSortChangeRejectLatePosition() async {
        let source = provider()
        source.alphabetEntries = [.init(letter: "M")]
        let started = expectation(description: "Deferred resolver started")
        source.alphabetJump = { _ in
            started.fulfill()
            try? await Task.sleep(for: .milliseconds(100))
            return 75 // Simulates a provider that returns after cancellation.
        }
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        let jump = Task { await vm.jumpToLetter("M") }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(vm.alphabet.jumpingTo, "M")
        vm.cancelLetterJump()
        XCTAssertNil(vm.alphabet.jumpingTo)
        await vm.setSort(.init(field: .dateAdded, direction: .descending))
        let result = await jump.value
        XCTAssertNil(result)
        XCTAssertNil(vm.alphabet.destination)
        XCTAssertTrue(vm.letterEntries.isEmpty)
        XCTAssertFalse(source.requestedPages.contains { $0.startIndex == 70 })
    }

    func testNoMatchAndFailuresPreserveViewportAndOfferFeedback() async {
        let source = provider()
        source.alphabetEntries = [.init(letter: "Q"), .init(letter: "Z")]
        source.alphabetJump = { letter in
            if letter == "Z" { throw AppError.serverUnreachable }
            return nil
        }
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        let missing = await vm.jumpToLetter("Q")
        XCTAssertNil(missing)
        XCTAssertNotNil(vm.alphabet.message)
        XCTAssertNil(vm.alphabet.destination)
        let failed = await vm.jumpToLetter("Z")
        XCTAssertNil(failed)
        XCTAssertNotNil(vm.alphabet.message)
        XCTAssertEqual(vm.loadedCount, 10)
        XCTAssertEqual(source.requestedPages.count, 1)
    }

    func testIndexFailureIsVisibleAndRetryable() async {
        let source = provider()
        source.alphabetError = .serverUnreachable
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        XCTAssertNotNil(vm.alphabet.message)
        XCTAssertTrue(vm.alphabet.isVisible)
        source.alphabetError = nil
        vm.retryLetterIndex()
        await waitForIndex(vm)
        XCTAssertNil(vm.alphabet.message)
        XCTAssertEqual(vm.letterEntries.count, 2)
    }

    func testFailedLandingPageNeverPublishesScrollDestination() async {
        let source = provider()
        source.failAtStartIndex = 70
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        let result = await vm.jumpToLetter("M")
        XCTAssertNil(result)
        XCTAssertNil(vm.alphabet.destination)
        XCTAssertNotNil(vm.alphabet.message)
    }

    func testDeferredLandingRefreshFailureDoesNotScrollToStaleSlot() async {
        let source = provider()
        source.alphabetEntries = [.init(letter: "M")]
        source.alphabetJump = { _ in 75 }
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        let first = await vm.jumpToLetter("M")
        XCTAssertEqual(first, 75)
        let destination = vm.alphabet.destination
        source.failAtStartIndex = 70
        let retry = await vm.jumpToLetter("M")
        XCTAssertNil(retry)
        XCTAssertEqual(vm.alphabet.destination, destination)
        XCTAssertNotNil(vm.alphabet.message)
    }
}

final class AggregatedLibraryAlphabetTests: XCTestCase {
    func testDeepJumpUsesDeduplicatedPositionsAndReusesCache() async throws {
        let movies = (0..<400).map {
            MediaItem(id: "p\($0)", title: "\($0 < 300 ? "Alpha" : "Zulu") \($0)",
                      kind: .movie, providerIDs: ["Tmdb": "\($0)"])
        }
        let plex = FakeMediaProvider(allItems: movies, kind: .plex)
        let duplicates = movies.map {
            MediaItem(id: "j\($0.id)", title: $0.title, kind: .movie, providerIDs: $0.providerIDs)
        }
        let jelly = FakeMediaProvider(allItems: duplicates, kind: .jellyfin)
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "plex", containerID: "movies-p", provider: plex, kind: .movie),
            .init(accountID: "jelly", containerID: "shows-j", provider: jelly, kind: .series)
        ])
        let sort = CoreModels.SortDescriptor(field: .name, direction: .ascending)
        _ = try await provider.items(in: "all", kind: .movie, page: .init(limit: 10, sort: sort))
        let before = plex.requestedPages.count + jelly.requestedPages.count
        let entries = try await provider.letterIndex(in: "all", kind: .movie, sort: sort)
        XCTAssertTrue(entries.allSatisfy { $0.startIndex == nil })
        XCTAssertEqual(plex.requestedPages.count + jelly.requestedPages.count, before)
        let position = try await provider.letterPosition(in: "all", kind: .movie, letter: "Z", sort: sort)
        XCTAssertEqual(position, 300, "Duplicate copies must not inflate the offset to 600")
        let landing = try await provider.items(in: "all", kind: .movie, page: .init(startIndex: 300, limit: 1))
        XCTAssertEqual(landing.items.first?.title, "Zulu 300")
        let after = plex.requestedPages.count + jelly.requestedPages.count
        let repeated = try await provider.letterPosition(in: "all", kind: .movie, letter: "Z", sort: sort)
        XCTAssertEqual(repeated, 300)
        XCTAssertEqual(plex.requestedPages.count + jelly.requestedPages.count, after)
        XCTAssertTrue(plex.requestedKinds.allSatisfy { $0 == .movie })
        XCTAssertTrue(jelly.requestedKinds.allSatisfy { $0 == .series })
    }

    func testDescendingMissingAndNonLatinTargetsUseActualOrder() async throws {
        let source = FakeMediaProvider(allItems: [
            .init(id: "1", title: "123", kind: .movie),
            .init(id: "a", title: "The Alien", kind: .movie),
            .init(id: "z", title: "Zulu", kind: .movie),
            .init(id: "jp", title: "映画", kind: .movie)
        ])
        let provider = AggregatedLibraryProvider(sources: [.init(accountID: "one", containerID: "lib", provider: source)])
        let sort = CoreModels.SortDescriptor(field: .name, direction: .descending)
        let page = try await provider.items(in: "lib", kind: .movie, page: .init(limit: 20, sort: sort))
        for letter in ["#", "A", "Z", "Q"] {
            let actual = try await provider.letterPosition(in: "lib", kind: .movie, letter: letter, sort: sort)
            XCTAssertEqual(actual, page.items.firstIndex { MediaItemSortOrder.alphabetBucket(for: $0) == letter })
        }
    }

    func testUnavailableSourceIsNotReportedAsMissingLetter() async throws {
        let source = FakeMediaProvider(allItems: [])
        source.alwaysFail = true
        let provider = AggregatedLibraryProvider(sources: [.init(accountID: "offline", containerID: "lib", provider: source)])
        do {
            _ = try await provider.letterPosition(in: "lib", kind: .movie, letter: "Z", sort: .default)
            XCTFail("An unavailable source must produce retryable feedback")
        } catch { XCTAssertEqual(error as? AppError, .serverUnreachable) }
        source.alwaysFail = false
        let position = try await provider.letterPosition(in: "lib", kind: .movie, letter: "Z", sort: .default)
        XCTAssertNil(position, "The failed fill must release its gate for retry")
    }
}
