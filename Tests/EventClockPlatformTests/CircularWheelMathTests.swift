import XCTest
@testable import EventClockPlatform

final class CircularWheelMathTests: XCTestCase {
    func testBackwardWrapFromZero() {
        let zeroRow = CircularWheelMath.initialRow(forValue: 0, modulo: 60)
        XCTAssertEqual(
            CircularWheelMath.value(forRow: zeroRow - 1, modulo: 60),
            59
        )
    }

    func testForwardWrapFromFiftyNine() {
        let fiftyNineRow = CircularWheelMath.initialRow(forValue: 59, modulo: 60)
        XCTAssertEqual(
            CircularWheelMath.value(forRow: fiftyNineRow + 1, modulo: 60),
            0
        )
    }

    func testRepeatedScrollingInBothDirections() {
        var value = 0
        for _ in 0..<130 {
            value = (value + 1) % 60
        }
        XCTAssertEqual(value, 10)

        value = 0
        for _ in 0..<130 {
            value = (value - 1 + 60) % 60
        }
        XCTAssertEqual(value, 50)

        let initial = CircularWheelMath.initialRow(forValue: 0, modulo: 60)
        XCTAssertEqual(
            CircularWheelMath.value(forRow: initial + 130, modulo: 60),
            10
        )
        XCTAssertEqual(
            CircularWheelMath.value(forRow: initial - 130, modulo: 60),
            50
        )
    }

    func testRowsRemainInsideVirtualRange() {
        let total = CircularWheelMath.totalRows(modulo: 60)
        XCTAssertEqual(total, 60_000)

        for value in 0..<60 {
            let row = CircularWheelMath.initialRow(forValue: value, modulo: 60)
            XCTAssertGreaterThanOrEqual(row, 0)
            XCTAssertLessThan(row, total)
            XCTAssertEqual(
                CircularWheelMath.value(forRow: row, modulo: 60),
                value
            )
            XCTAssertFalse(
                CircularWheelMath.needsRecentering(row: row, modulo: 60)
            )
        }
    }

    func testEdgeRecenteringPreservesValue() {
        let topEdge = CircularWheelMath.edgeThreshold - 1
        let bottomEdge = CircularWheelMath.totalRows(modulo: 60)
            - CircularWheelMath.edgeThreshold

        XCTAssertTrue(
            CircularWheelMath.needsRecentering(row: topEdge, modulo: 60)
        )
        XCTAssertTrue(
            CircularWheelMath.needsRecentering(row: bottomEdge, modulo: 60)
        )

        for row in [topEdge, bottomEdge] {
            let value = CircularWheelMath.value(forRow: row, modulo: 60)
            let recentered = CircularWheelMath.recenteredRow(
                forValue: value,
                modulo: 60
            )
            XCTAssertEqual(
                CircularWheelMath.value(forRow: recentered, modulo: 60),
                value
            )
            XCTAssertFalse(
                CircularWheelMath.needsRecentering(
                    row: recentered,
                    modulo: 60
                )
            )
        }
    }

    func testNegativeAndNonSixtyModuloValues() {
        XCTAssertEqual(CircularWheelMath.value(forRow: -1, modulo: 60), 59)
        XCTAssertEqual(CircularWheelMath.value(forRow: -61, modulo: 60), 59)
        XCTAssertEqual(CircularWheelMath.value(forRow: 7, modulo: 1), 0)
        XCTAssertEqual(CircularWheelMath.value(forRow: 7, modulo: 0), 0)
    }

    func testZeroAtPhysicalEdgeRequiresRepositioning() {
        // Regression: seconds default to 00. If the picker starts at physical
        // row 0, that row represents 00 correctly but cannot scroll backward.
        XCTAssertEqual(
            CircularWheelMath.value(forRow: 0, modulo: 60),
            0
        )
        XCTAssertTrue(
            CircularWheelMath.shouldRepositionSelection(
                row: 0,
                value: 0,
                modulo: 60
            )
        )

        let middle = CircularWheelMath.initialRow(forValue: 0, modulo: 60)
        XCTAssertFalse(
            CircularWheelMath.shouldRepositionSelection(
                row: middle,
                value: 0,
                modulo: 60
            )
        )
    }

    func testMatchingValueAtEitherEdgeRequiresRepositioning() {
        let total = CircularWheelMath.totalRows(modulo: 60)
        XCTAssertTrue(
            CircularWheelMath.shouldRepositionSelection(
                row: total - 1,
                value: 59,
                modulo: 60
            )
        )
        XCTAssertTrue(
            CircularWheelMath.shouldRepositionSelection(
                row: -1,
                value: 0,
                modulo: 60
            )
        )
        XCTAssertFalse(
            CircularWheelMath.shouldRepositionSelection(
                row: CircularWheelMath.initialRow(forValue: 59, modulo: 60),
                value: 59,
                modulo: 60
            )
        )
    }
}
