#if canImport(AVFoundation)
import Foundation
import XCTest
@testable import FeaturePlayback

@MainActor
final class NativeMediaSelectionReaderTests: XCTestCase {
    func testEmptySelectionIsDifferentFromUnavailableAndRunsOffMain() async {
        let reader = NativeMediaSelectionReader()
        let value = await reader.read(timeout: 2) {
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNil(withUnsafeCurrentTask { $0 })
            return .init(option: nil)
        }
        XCTAssertNotNil(value)
        XCTAssertNil(value?.option)
    }

    func testTimeoutsDoNotReleaseBlockedNativeLanes() async {
        let reader = NativeMediaSelectionReader()
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "both owned readers returned")
        finished.expectedFulfillmentCount = 2
        defer { release.signal(); release.signal() }
        for _ in 0..<2 {
            let result = await reader.read(timeout: 0.05) {
                release.wait()
                finished.fulfill()
                return .init(option: nil)
            }
            XCTAssertNil(result, "The UI waiter must return without the native getter completing.")
        }
        for _ in 0..<10 {
            let result = await reader.read(timeout: 2) {
                XCTFail("Timeout must not admit another blocked native reader.")
                return .init(option: nil)
            }
            XCTAssertNil(result)
        }
        release.signal()
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
    }

    func testCancellationDiscardsTheLateResult() async {
        let reader = NativeMediaSelectionReader()
        let release = DispatchSemaphore(value: 0)
        let entered = expectation(description: "native query entered")
        let finished = expectation(description: "native query returned")
        defer { release.signal() }
        let task = Task {
            await reader.read(timeout: 5) {
                entered.fulfill()
                release.wait()
                finished.fulfill()
                return .init(option: nil)
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        release.signal()
        await fulfillment(of: [finished], timeout: 3)
    }
}
#endif
