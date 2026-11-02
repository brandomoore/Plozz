import AetherEngine
import MediaTransportCore
import XCTest
@testable import EnginePlozzigen

final class PlozzigenSourcePreparationOutcomeTests: XCTestCase {
    func testCompletedNativeCoverageIsAccepted() {
        XCTAssertNoThrow(try PlozzigenNetworkFileStreamProber.requireCompletePreparation(.complete))
    }

    func testExpectedNativeIncompletionHasExplicitTypedDisposition() {
        let cases: [(SourcePreparationOutcome, MediaTransportPreparationIncomplete)] = [
            (.endOfSource, .endOfSource),
            (.seekFailed, .seekUnavailable),
            (.budgetExhausted(.inputLimit), .inputBudget),
            (.budgetExhausted(.packetLimit), .packetBudget),
            (.budgetExhausted(.packetSizeLimit), .packetSizeBudget),
            (.budgetExhausted(.timedOut), .timeBudget),
        ]
        for (outcome, expected) in cases {
            XCTAssertThrowsError(try PlozzigenNetworkFileStreamProber.requireCompletePreparation(outcome)) {
                XCTAssertEqual($0 as? MediaTransportPreparationIncomplete, expected)
            }
        }
    }

    func testNonBudgetProbeErrorsCannotBeDowngradedByBudgetReport() {
        for failure: ProbeError in [.invalidLimits, .invalidReaderResult, .unsupportedURL, .sourceBusy] {
            XCTAssertThrowsError(
                try PlozzigenNetworkFileStreamProber.requireCompletePreparation(.budgetExhausted(failure))
            ) {
                XCTAssertEqual($0 as? ProbeError, failure)
                XCTAssertFalse($0 is MediaTransportPreparationIncomplete)
            }
        }
    }

    func testObservedIncompleteOutcomeWinsOverRacingHandoffCancellation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(
                try PlozzigenNetworkFileStreamProber.requireCompletePreparation(.budgetExhausted(.packetLimit))
            ) {
                XCTAssertEqual($0 as? MediaTransportPreparationIncomplete, .packetBudget)
            }
            XCTAssertThrowsError(try PlozzigenNetworkFileStreamProber.requireCompletePreparation(.complete)) {
                XCTAssertTrue($0 is CancellationError)
            }
        }
        try await task.value
    }
}
