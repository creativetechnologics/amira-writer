import Foundation
import XCTest
@testable import NovotroProjectKit

final class NovotroProjectTransportSecurityTests: XCTestCase {
    func testEnvelopeRoundTripsWithMatchingToken() throws {
        let payload = Data("transport payload".utf8)
        let envelope = try NovotroProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        let opened = try NovotroProjectTransportSecurity.open(envelope, authToken: "shared-secret")
        XCTAssertEqual(opened, payload)
    }

    func testEnvelopeRejectsWrongToken() throws {
        let payload = Data("transport payload".utf8)
        let envelope = try NovotroProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        XCTAssertThrowsError(try NovotroProjectTransportSecurity.open(envelope, authToken: "wrong-secret"))
    }

    func testEnvelopeRejectsTampering() throws {
        let payload = Data("transport payload".utf8)
        var envelope = try NovotroProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        envelope.sealedPayload[0] ^= 0xFF
        XCTAssertThrowsError(try NovotroProjectTransportSecurity.open(envelope, authToken: "shared-secret"))
    }
}
