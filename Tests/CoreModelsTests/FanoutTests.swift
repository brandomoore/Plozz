import XCTest
@testable import CoreModels

/// The fan-out exists so a one-server install and a multi-server install go
/// through the same code. These tests pin the properties that divergence used to
/// break: publication count, merge order and completeness.
final class FanoutTests: XCTestCase {
    private func values(_ result: FanoutResult<[String]>) -> [String] { result.value }

    func testSingleSourcePublishesExactlyOnceWithoutMergingDelay() async {
        let recorder = PublicationRecorder()
        let result = await Fanout.run(
            sources: ["server-a"],
            fetch: { source in .success(source) },
            merge: { $0 }
        ) { snapshot in
            await recorder.record(snapshot)
        }

        let published = await recorder.snapshots
        XCTAssertEqual(published.count, 1, "a single source must not publish twice")
        XCTAssertEqual(values(result), ["server-a"])
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testNoSourcesPublishesAnEmptyCompleteResult() async {
        let recorder = PublicationRecorder()
        let result = await Fanout.run(
            sources: [],
            fetch: { _ in .success("") },
            merge: { $0 }
        ) { snapshot in
            await recorder.record(snapshot)
        }

        // Hoisted: XCTest assertion arguments are autoclosures, and an `await`
        // inside one does not compile.
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(values(result).isEmpty)
        XCTAssertTrue(result.isComplete)
    }

    func testProgressivePublishesAfterEachArrivalAndReportsCompleteness() async {
        let recorder = PublicationRecorder()
        let result = await Fanout.run(
            sources: ["a", "b"],
            fetch: { source in .success(source) },
            merge: { $0 }
        ) { snapshot in
            await recorder.record(snapshot)
        }

        let published = await recorder.snapshots
        XCTAssertEqual(published.count, 2, "one publication per arrival")
        XCTAssertEqual(published.last?.isComplete, true)
        XCTAssertTrue(result.isComplete)
        // Merge order follows `sources`, never arrival order.
        XCTAssertEqual(values(result), ["a", "b"])
    }

    func testCompleteOnlyWithholdsUntilEverySourceAnswered() async {
        let recorder = PublicationRecorder()
        _ = await Fanout.run(
            sources: ["a", "b"],
            publication: .completeOnly,
            fetch: { source in .success(source) },
            merge: { $0 }
        ) { snapshot in
            await recorder.record(snapshot)
        }

        let published = await recorder.snapshots
        XCTAssertEqual(published.count, 1, "only the complete aggregate may publish")
        XCTAssertEqual(published.first?.isComplete, true)
        XCTAssertEqual(values(published.first!), ["a", "b"])
    }

    func testFailedSourceIsReportedAndNotPending() async {
        let result = await Fanout.run(
            sources: ["ok", "broken"],
            fetch: { source in
                source == "ok" ? .success(source) : .failure(.notFound)
            },
            merge: { $0 }
        ) { _ in }

        XCTAssertEqual(result.failures["broken"], .notFound)
        XCTAssertFalse(result.pending.contains("broken"))
        XCTAssertEqual(result.value, ["ok"])
    }

    func testDuplicateSourcesAreFetchedOnce() async {
        let counter = CallCounter()
        let result = await Fanout.run(
            sources: ["a", "a"],
            fetch: { source in
                await counter.increment()
                return .success(source)
            },
            merge: { $0 }
        ) { _ in }

        // Await first: XCTest's assertion arguments are autoclosures, so an inline
        // `await` inside one does not compile.
        let calls = await counter.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.value, ["a"])
    }
}

private actor PublicationRecorder {
    private(set) var snapshots: [FanoutResult<[String]>] = []
    func record(_ snapshot: FanoutResult<[String]>) { snapshots.append(snapshot) }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
