import XCTest
@testable import CoreUI

@MainActor
final class SetupProgressNumberTests: XCTestCase {
    func testInterpolationAdvancesWithoutExceedingConfirmedWork() {
        var number = SetupProgressNumber(count: 500)
        var previous = 0
        for value in stride(from: 0.0, through: 600.0, by: 7.5) {
            number.animatableData = value
            XCTAssertGreaterThanOrEqual(number.displayedCount, previous)
            XCTAssertLessThanOrEqual(number.displayedCount, 500)
            previous = number.displayedCount
        }
        XCTAssertEqual(number.displayedCount, 500)
    }

    func testResetCannotCarryThePreviousStagesCountIntoTheNewOne() {
        var number = SetupProgressNumber(count: 0)
        number.animatableData = 382_324
        XCTAssertEqual(number.displayedCount, 0)
        number = SetupProgressNumber(count: 500)
        number.animatableData = 382_324
        XCTAssertEqual(number.displayedCount, 500)
    }

    func testInitialAndExtremeValuesRemainRepresentable() {
        XCTAssertEqual(SetupProgressNumber(count: 382_324).displayedCount, 382_324)
        XCTAssertEqual(SetupProgressNumber(count: Int.max).displayedCount, Int.max)
        var number = SetupProgressNumber(count: 500)
        number.animatableData = -10
        XCTAssertEqual(number.displayedCount, 0)
        for value in [Double.infinity, Double.nan] {
            number.animatableData = value
            XCTAssertEqual(number.displayedCount, 500)
        }
    }
}
