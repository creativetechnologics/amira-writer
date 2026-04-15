import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class ImagineModelsTests: XCTestCase {
    func testLegacyZImageValueDecodesToFluxKlein9B() throws {
        let data = Data(#""z_image_turbo""#.utf8)
        let decoded = try JSONDecoder().decode(ImagineDrawThingsModel.self, from: data)

        XCTAssertEqual(decoded, .fluxKlein9B)
    }

    func testLegacyFlux4BValueDecodesToFluxKlein9B() throws {
        let data = Data(#""flux2_klein_4b""#.utf8)
        let decoded = try JSONDecoder().decode(ImagineDrawThingsModel.self, from: data)

        XCTAssertEqual(decoded, .fluxKlein9B)
    }

    func testBulkRunDefaultsToFluxKlein9B() {
        XCTAssertEqual(ImagineBulkRunConfig().model, .fluxKlein9B)
    }
}
