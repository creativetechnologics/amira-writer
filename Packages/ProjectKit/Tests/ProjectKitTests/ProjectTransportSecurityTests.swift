import Foundation
import XCTest
@testable import ProjectKit

final class ProjectTransportSecurityTests: XCTestCase {
    func testEnvelopeRoundTripsWithMatchingToken() throws {
        let payload = Data("transport payload".utf8)
        let envelope = try ProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        let opened = try ProjectTransportSecurity.open(envelope, authToken: "shared-secret")
        XCTAssertEqual(opened, payload)
    }

    func testEnvelopeRejectsWrongToken() throws {
        let payload = Data("transport payload".utf8)
        let envelope = try ProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        XCTAssertThrowsError(try ProjectTransportSecurity.open(envelope, authToken: "wrong-secret"))
    }

    func testEnvelopeRejectsTampering() throws {
        let payload = Data("transport payload".utf8)
        var envelope = try ProjectTransportSecurity.seal(payload, authToken: "shared-secret")
        envelope.sealedPayload[0] ^= 0xFF
        XCTAssertThrowsError(try ProjectTransportSecurity.open(envelope, authToken: "shared-secret"))
    }
}
