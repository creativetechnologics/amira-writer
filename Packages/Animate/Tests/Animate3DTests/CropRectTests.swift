import Foundation
import CoreGraphics
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class CropRectTests: XCTestCase {

    // MARK: - CropRect.from(CGRect)

    /// CropRect.from(_:) should preserve the origin and size of the source CGRect.
    func testCropRectFromCGRect() {
        let source = CGRect(x: 10.5, y: 20.25, width: 320.0, height: 240.0)
        let crop = CropRect.from(source)

        XCTAssertEqual(crop.x, source.origin.x, accuracy: 1e-6)
        XCTAssertEqual(crop.y, source.origin.y, accuracy: 1e-6)
        XCTAssertEqual(crop.width, source.size.width, accuracy: 1e-6)
        XCTAssertEqual(crop.height, source.size.height, accuracy: 1e-6)
    }

    // MARK: - CropRect.cgRect

    /// The .cgRect computed property should reconstruct an equivalent CGRect.
    func testCropRectCGRectProperty() {
        let crop = CropRect(x: 5.0, y: 15.0, width: 100.0, height: 200.0)
        let rect = crop.cgRect

        XCTAssertEqual(rect.origin.x, crop.x, accuracy: 1e-6)
        XCTAssertEqual(rect.origin.y, crop.y, accuracy: 1e-6)
        XCTAssertEqual(rect.size.width, crop.width, accuracy: 1e-6)
        XCTAssertEqual(rect.size.height, crop.height, accuracy: 1e-6)
    }

    // MARK: - Codable round-trip

    /// Encoding a CropRect to JSON and decoding it should preserve all four fields.
    func testCropRectCodable() throws {
        let original = CropRect(x: 12.3, y: 45.6, width: 78.9, height: 0.1)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CropRect.self, from: data)

        XCTAssertEqual(decoded.x, original.x, accuracy: 1e-6)
        XCTAssertEqual(decoded.y, original.y, accuracy: 1e-6)
        XCTAssertEqual(decoded.width, original.width, accuracy: 1e-6)
        XCTAssertEqual(decoded.height, original.height, accuracy: 1e-6)
    }
}
