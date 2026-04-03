import Foundation
import CoreGraphics
import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class DepthEstimationTests: XCTestCase {

    // MARK: - linearFallback dimensions

    /// The fallback depth map should have exactly the requested width and height.
    func testLinearFallbackDimensions() async throws {
        let image = makeSolidCGImage(width: 100, height: 50)!
        let map = try await DepthEstimationService.estimateDepth(cgImage: image)
        XCTAssertEqual(map.width, 100)
        XCTAssertEqual(map.height, 50)
        XCTAssertEqual(map.values.count, 100 * 50)
    }

    /// In the linear fallback the bottom row (y near 1.0) should be nearer (lower depth value)
    /// than the top row (y near 0.0, which is farthest).
    func testLinearFallbackBottomIsNear() async throws {
        let image = makeSolidCGImage(width: 80, height: 60)!
        let map = try await DepthEstimationService.estimateDepth(cgImage: image)

        // Top row: y = 0  → invDepth = 1.0 (far)
        let topDepth = map.depth(atX: 0.5, y: 0.0)
        // Bottom row: y = 1  → invDepth = 0.0 (near)
        let bottomDepth = map.depth(atX: 0.5, y: 1.0)

        XCTAssertGreaterThan(topDepth, bottomDepth,
            "Top of frame (far) should have higher depth value than bottom (near)")
    }

    // MARK: - DepthMap.depth(atX:y:)

    /// Manually construct a DepthMap and verify pixel lookups return expected values.
    func testDepthAtSampling() {
        // 4×2 map: top row all 0.8, bottom row all 0.2
        let values: [Float] = [
            0.8, 0.8, 0.8, 0.8,   // row 0 (y=0, top)
            0.2, 0.2, 0.2, 0.2    // row 1 (y=1, bottom)
        ]
        let map = DepthEstimationService.DepthMap(
            width: 4,
            height: 2,
            values: values,
            source: .linearFallback
        )

        // Top-left corner (x=0, y=0) → row 0, col 0 → 0.8
        XCTAssertEqual(map.depth(atX: 0.0, y: 0.0), 0.8, accuracy: 1e-4)

        // Bottom-right corner (x=1, y=1) → row 1, col 3 → 0.2
        XCTAssertEqual(map.depth(atX: 1.0, y: 1.0), 0.2, accuracy: 1e-4)

        // Center pixel: x=0.5 → col 2, y=0.0 → row 0 → 0.8
        XCTAssertEqual(map.depth(atX: 0.5, y: 0.0), 0.8, accuracy: 1e-4)
    }

    // MARK: - estimateDepth falls back to linear when no CoreML model is bundled

    /// In the test bundle there is no compiled DepthAnythingV2 model, so the service
    /// must fall back to the linear gradient and report `.linearFallback` as source.
    func testEstimateDepthFallsBackToLinear() async throws {
        let image = makeSolidCGImage(width: 32, height: 32)!
        let map = try await DepthEstimationService.estimateDepth(cgImage: image)
        XCTAssertEqual(map.source, .linearFallback,
            "Without a bundled CoreML model the service should return a linearFallback map")
    }

    // MARK: - Helpers

    /// Create a trivial 1×1-colour CGImage for use as a test input.
    private func makeSolidCGImage(width: Int, height: Int) -> CGImage? {
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixels = [UInt8](repeating: 128, count: width * height * bytesPerPixel)
        guard let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        return image
    }
}
