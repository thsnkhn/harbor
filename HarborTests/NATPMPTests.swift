import Foundation
import XCTest
@testable import Harbor

final class NATPMPTests: XCTestCase {
    func testMappingRequestAsksForTheConnectionPort() {
        XCTAssertEqual([UInt8](NATPMP.mappingRequest(.udp)), [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60])
        XCTAssertEqual([UInt8](NATPMP.mappingRequest(.tcp)), [0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60])
    }

    func testMappedPortReadsOnlySuccessfulMatchingResponses() {
        // Version 0, opcode 130 (TCP reply), result 0, epoch, internal 1, external 51234, lifetime 60.
        let response: [UInt8] = [0, 130, 0, 0, 0, 1, 171, 102, 0, 1, 0xC8, 0x22, 0, 0, 0, 60]
        XCTAssertEqual(NATPMP.mappedPort(from: Data(response), for: .tcp), 51_234)
        XCTAssertNil(NATPMP.mappedPort(from: Data(response), for: .udp))

        var refused = response
        refused[3] = 2 // Not authorized
        XCTAssertNil(NATPMP.mappedPort(from: Data(refused), for: .tcp))
        XCTAssertNil(NATPMP.mappedPort(from: Data(response.prefix(12)), for: .tcp))
    }

    func testGatewayIsTheFirstAddressOfTheTunnelSubnet() {
        XCTAssertEqual(NATPMP.gateway(forAddress: "10.2.0.2"), "10.2.0.1")
        XCTAssertNil(NATPMP.gateway(forAddress: "fe80::1"))
    }
}
