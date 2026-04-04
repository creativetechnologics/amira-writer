import Foundation
import simd
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class TemporalFilterTests: XCTestCase {

    func testStaticSignalConvergesToValue() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.007, dCutoff: 1.0)
        var result = SIMD3<Float>.zero
        for i in 0..<60 {
            let t = Double(i) / 60.0
            result = filter.filter(value: SIMD3<Float>(1.0, 2.0, 3.0), timestamp: t)
        }
        XCTAssertEqual(result.x, 1.0, accuracy: 0.05)
        XCTAssertEqual(result.y, 2.0, accuracy: 0.05)
        XCTAssertEqual(result.z, 3.0, accuracy: 0.05)
    }

    func testFirstValuePassesThrough() {
        var filter = OneEuroFilter(minCutoff: 1.0, beta: 0.007, dCutoff: 1.0)
        let result = filter.filter(value: SIMD3<Float>(5.0, 10.0, 15.0), timestamp: 0.0)
        XCTAssertEqual(result.x, 5.0, accuracy: 0.001)
        XCTAssertEqual(result.y, 10.0, accuracy: 0.001)
        XCTAssertEqual(result.z, 15.0, accuracy: 0.001)
    }

    func testHighBetaAllowsFastMovement() {
        var lowBeta = OneEuroFilter(minCutoff: 1.0, beta: 0.0, dCutoff: 1.0)
        var highBeta = OneEuroFilter(minCutoff: 1.0, beta: 1.0, dCutoff: 1.0)

        _ = lowBeta.filter(value: .zero, timestamp: 0.0)
        _ = highBeta.filter(value: .zero, timestamp: 0.0)

        let jump = SIMD3<Float>(10.0, 0.0, 0.0)
        let lowResult = lowBeta.filter(value: jump, timestamp: 1.0 / 60.0)
        let highResult = highBeta.filter(value: jump, timestamp: 1.0 / 60.0)

        XCTAssertGreaterThan(highResult.x, lowResult.x)
    }

    func testTemporalFilterManagerFiltersMultipleJoints() {
        var manager = TemporalFilterManager()
        let joints: [JointName: SIMD3<Float>] = [
            .head: SIMD3<Float>(0, 1, 0),
            .leftWrist: SIMD3<Float>(1, 0, 0),
        ]
        let result1 = manager.filter(joints: joints, timestamp: 0.0)
        let result2 = manager.filter(joints: joints, timestamp: 1.0 / 60.0)

        XCTAssertNotNil(result1[.head])
        XCTAssertNotNil(result2[.leftWrist])
    }
}