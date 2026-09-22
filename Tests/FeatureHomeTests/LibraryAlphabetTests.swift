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

    func testUnloadedViewportRetainsLayoutButNotAStalePositionLetter() async {
        let source = provider()
        source.allItems = (0..<100).map {
            MediaItem(id: "\($0)", title: "\($0 < 70 ? "Alpha" : "Zulu") \($0)", kind: .movie)
        }
        source.alphabetEntries = LibraryLetterIndex.deferredEntries(direction: .ascending)
        let started = expectation(description: "Unloaded viewport requested")
        source.pageHooks[70] = {
            started.fulfill()
            try await Task.sleep(for: .milliseconds(100))
        }
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        XCTAssertEqual(vm.alphabet.positionLetter, "A")
        let paging = Task { await vm.itemAppeared(at: 70) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(vm.letter(forIndex: 70))
        XCTAssertNil(vm.alphabet.positionLetter)
        XCTAssertEqual(vm.alphabet.lastKnownPositionLetter, "A")
        XCTAssertTrue(vm.alphabet.isPositionLoading)
        await paging.value
        XCTAssertEqual(vm.alphabet.positionLetter, "Z")
        XCTAssertFalse(vm.alphabet.isPositionLoading)
        await vm.setSort(.init(field: .dateAdded, direction: .descending))
        XCTAssertNil(vm.alphabet.positionLetter)
        XCTAssertNil(vm.alphabet.lastKnownPositionLetter)
        XCTAssertFalse(vm.alphabet.isPositionLoading)
    }

    func testRailJumpDoesNotRequestFocusButExplicitSelectionDoes() async {
        let source = provider()
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        _ = await vm.jumpToLetter("M", focusesItem: false)
        XCTAssertEqual(vm.alphabet.destination?.focusesItem, false)
        _ = await vm.jumpToLetter("M")
        XCTAssertEqual(vm.alphabet.destination?.focusesItem, true)
    }

    func testNativeViewportOverridesOffscreenFocusedCellUntilItsPageLoads() async {
        let source = provider()
        source.alphabetEntries = LibraryLetterIndex.deferredEntries(direction: .ascending)
        let vm = model(source)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        await vm.itemAppeared(at: 0)
        vm.reportViewport(firstIndex: 70, generation: vm.contentGeneration)
        XCTAssertEqual(vm.topVisibleIndex, 70)
        XCTAssertNil(vm.alphabet.positionLetter)
        XCTAssertTrue(vm.alphabet.isPositionLoading)
        await vm.itemAppeared(at: 0)
        XCTAssertEqual(vm.topVisibleIndex, 70, "Retained off-screen cell callbacks cannot replace the viewport")
        await vm.itemAppeared(at: 70)
        XCTAssertEqual(vm.alphabet.positionLetter, "M")
        XCTAssertFalse(vm.alphabet.isPositionLoading)
        let oldGeneration = vm.contentGeneration
        await vm.loadFirstPage()
        vm.reportViewport(firstIndex: 70, generation: oldGeneration)
        XCTAssertNotEqual(vm.topVisibleIndex, 70, "Old-layout callbacks cannot affect a new browse generation")
    }

    func testCombinedSiloManualScrollNeverLabelsUnloadedZRowsAsT() async {
        func items(parity: Int, kind: MediaItemKind) -> [MediaItem] {
            stride(from: parity, to: 600, by: 2).map { index in
                let letter = index < 380 ? "A" : index < 480 ? "T" : "Z"
                return MediaItem(id: "\(index)", title: "\(letter) \(index)", kind: kind)
            }
        }
        let movies = FakeMediaProvider(allItems: items(parity: 0, kind: .movie), kind: .silo)
        let shows = FakeMediaProvider(allItems: items(parity: 1, kind: .series), kind: .silo)
        let gate = AlphabetPageGate()
        let started = expectation(description: "Library page beyond T is pending")
        movies.pageHooks[260] = {
            started.fulfill()
            await gate.wait()
        }
        let provider = AggregatedLibraryProvider(sources: [
            .init(accountID: "silo", containerID: "movies", provider: movies, kind: .movie),
            .init(accountID: "silo", containerID: "shows", provider: shows, kind: .series)
        ])
        let vm = LibraryBrowseViewModel(
            provider: provider, containerID: "all", containerKind: .unknown, pageSize: 20,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await vm.loadFirstPage()
        await waitForIndex(vm)
        await vm.itemAppeared(at: 400)
        XCTAssertEqual(vm.alphabet.positionLetter, "T")
        vm.itemDisappeared(at: 400)
        let paging = Task { await vm.itemAppeared(at: 540) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(vm.totalCount, 600)
        XCTAssertEqual(vm.topVisibleIndex, 540)
        XCTAssertNil(vm.item(at: 540))
        XCTAssertTrue(vm.alphabet.isPositionLoading)
        XCTAssertNil(vm.alphabet.positionLetter, "T is old content, not the current unloaded viewport")
        XCTAssertNil(vm.alphabet.destination, "Manual scrolling must not publish an alphabet jump")
        await gate.release()
        await paging.value
        XCTAssertEqual(vm.totalCount, 600, "No total correction or deduplication is needed to reproduce this")
        XCTAssertEqual(vm.topVisibleIndex, 540, "Loading must keep the user's slot rather than seek elsewhere")
        XCTAssertEqual(vm.item(at: 540)?.title, "Z 540")
        XCTAssertEqual(vm.alphabet.positionLetter, "Z")
        XCTAssertNil(vm.alphabet.destination)
        vm.itemDisappeared(at: 540)
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

private actor AlphabetPageGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
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
