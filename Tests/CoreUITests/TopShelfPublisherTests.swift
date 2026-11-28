import CoreModels
import Observation
@testable import TopShelfKit
import XCTest

final class TopShelfPublisherTests: XCTestCase {
    @MainActor @Observable
    fileprivate final class Inputs {
        var viewer: TopShelfPublication.Viewer? = .init(homeScope: "alice", accountIDs: ["plex"])
        var settings = TopShelfSettings.default
        var saved: TopShelfSnapshot?

        func publication() -> TopShelfPublication {
            let result = TopShelfPublication(
                viewer: { self.viewer }, settings: { self.settings },
                save: { self.saved = $0 }, revoke: { self.saved = nil }
            )
            result.start()
            return result
        }
    }

    func testDisabledSnapshotIsEmptyWithoutResolvingArtwork() async throws {
        let snapshot = await TopShelfPublisher.makeSnapshot(
            continueWatching: items("resume", count: 30), latest: items("latest", count: 30),
            settings: .init(isEnabled: false, continueWatchingItems: 20, recentlyAddedItems: 20),
            resolveArtwork: { _ in
                XCTFail("Disabled Top Shelf must not resolve artwork")
                return nil
            }
        )
        XCTAssertTrue(try XCTUnwrap(snapshot).sections.isEmpty)
    }

    @MainActor
    func testDisableOrPickerRevokesImmediatelyAndRejectsSuspendedAndLateHomeWork() async throws {
        for disable in [false, true] {
            let input = Inputs()
            let publication = input.publication()
            await publication.publish(for: "alice") { _, _ in TopShelfSnapshot(sections: []) }
            let previous = try XCTUnwrap(input.saved?.authorizationID)
            let started = expectation(description: "Old artwork suspended")
            var resume: CheckedContinuation<TopShelfSnapshot?, Never>?
            let old = Task {
                await publication.publish(for: "alice") { _, _ in
                    await withCheckedContinuation {
                        resume = $0
                        started.fulfill()
                    }
                }
            }
            await fulfillment(of: [started], timeout: 5)
            if disable { input.settings.isEnabled = false } else { input.viewer = nil }
            XCTAssertNil(input.saved, "Revocation must not wait for a view update or Home load")
            XCTAssertNil(publication.authorizationID)
            await publication.publish(for: "alice") { _, _ in XCTFail("Gate must precede artwork"); return nil }
            let nextViewer = disable ? "alice" : "bob"
            if disable {
                input.settings.isEnabled = true
            } else {
                input.viewer = .init(homeScope: nextViewer, accountIDs: ["plex"])
            }
            let ready = expectation(description: "New viewer authorized")
            withObservationTracking { _ = publication.authorizationID } onChange: { ready.fulfill() }
            await fulfillment(of: [ready], timeout: 5)
            resume?.resume(returning: TopShelfSnapshot(sections: [.init(id: "old", title: "Old", items: [])]))
            await old.value
            XCTAssertNil(input.saved, "Old work must fail even before a new publication supersedes it")
            if !disable {
                await publication.publish(for: "alice") { _, _ in XCTFail("Retired Home cannot publish"); return nil }
            }
            await publication.publish(for: nextViewer) { _, _ in
                TopShelfSnapshot(sections: [.init(id: "new", title: "New", items: [])])
            }
            XCTAssertEqual(input.saved?.sections.map(\.id), ["new"])
            XCTAssertNotEqual(input.saved?.authorizationID, previous)
        }
    }

    @MainActor
    func testNewerPublicationWinsAndCancelledPublicationCannotSave() async {
        let input = Inputs()
        let publication = input.publication()
        let started = expectation(description: "Old artwork suspended")
        var resume: CheckedContinuation<TopShelfSnapshot?, Never>?
        let old = Task {
            await publication.publish(for: "alice") { _, _ in
                await withCheckedContinuation {
                    resume = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 5)
        await publication.publish(for: "alice") { _, _ in
            TopShelfSnapshot(sections: [.init(id: "new", title: "New", items: [])])
        }
        resume?.resume(returning: TopShelfSnapshot(sections: [.init(id: "old", title: "Old", items: [])]))
        await old.value
        let cancelled = Task {
            await publication.publish(for: "alice") { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return TopShelfSnapshot(sections: [])
            }
        }
        await cancelled.value
        XCTAssertEqual(input.saved?.sections.map(\.id), ["new"])
    }

    @MainActor
    func testOnlyResolvedAccountItemsReachSnapshotAndResolvers() async {
        let input = Inputs()
        let publication = input.publication()
        let items: [MediaItem] = ["other", nil, "plex"].map {
            .init(id: "1", title: $0 ?? "unknown", kind: .movie, sourceAccountID: $0)
        }
        await TopShelfPublisher.publish(
            for: "alice", publication: publication, continueWatching: [], latest: items,
            resolveArtwork: { item in XCTAssertEqual(item.sourceAccountID, "plex"); return nil }
        )
        XCTAssertEqual(input.saved?.sections.first?.items.map(\.title), ["plex"])
    }

    func testDefaultSnapshotHasFourItemsInEachSection() async throws {
        let snapshot = await TopShelfPublisher.makeSnapshot(
            continueWatching: items("resume", count: 30),
            latest: items("latest", count: 30),
            locale: Locale(identifier: "en_US")
        )
        let sections = try XCTUnwrap(snapshot).sections
        XCTAssertEqual(sections.map(\.id), ["continue", "latest"])
        XCTAssertEqual(sections.map(\.title), ["Continue Watching", "Recently Added"])
        XCTAssertEqual(sections.map { $0.items.count }, [4, 4])
    }

    func testIndependentLimitsPreserveOrderAndAccountIdentity() async throws {
        for (resumeCount, recentCount) in [(1, 20), (20, 1), (7, 12)] {
            let resume = items("resume", count: 30)
            let latest = items("latest", count: 30)
            let snapshot = await TopShelfPublisher.makeSnapshot(
                continueWatching: resume, latest: latest,
                settings: .init(continueWatchingItems: resumeCount, recentlyAddedItems: recentCount)
            )
            let sections = try XCTUnwrap(snapshot).sections
            XCTAssertEqual(sections[0].items.map(\.id), Array(resume.prefix(resumeCount)).map(\.id))
            XCTAssertEqual(sections[1].items.map(\.id), Array(latest.prefix(recentCount)).map(\.id))
            for item in sections.flatMap(\.items) {
                XCTAssertEqual(item.accountID, "account-\(item.id)")
                XCTAssertEqual(item.shelfIdentifier, "account-\(item.id):\(item.id)")
            }
        }
    }

    func testShortFeedsAreNotPaddedAndEmptySectionsAreOmitted() async throws {
        let short = await TopShelfPublisher.makeSnapshot(
            continueWatching: [], latest: items("latest", count: 2),
            settings: .init(continueWatchingItems: 20, recentlyAddedItems: 20)
        )
        XCTAssertEqual(try XCTUnwrap(short).sections.map(\.id), ["latest"])
        XCTAssertEqual(short?.sections.first?.items.count, 2)
        let empty = await TopShelfPublisher.makeSnapshot(continueWatching: [], latest: [])
        XCTAssertTrue(try XCTUnwrap(empty).sections.isEmpty)
    }

    func testCancelledPublishDoesNotProduceAPartialSnapshot() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TopShelfPublisher.makeSnapshot(
                continueWatching: self.items("resume", count: 30),
                latest: self.items("latest", count: 30)
            )
        }
        let snapshot = await task.value
        XCTAssertNil(snapshot)
    }

    private func items(_ prefix: String, count: Int) -> [MediaItem] {
        (0..<count).map { index in
            let id = "\(prefix)-\(index)"
            return MediaItem(
                id: id, title: id, kind: .movie,
                posterURL: URL(string: "https://example.com/\(id).jpg"),
                sourceAccountID: "account-\(id)"
            )
        }
    }
}
