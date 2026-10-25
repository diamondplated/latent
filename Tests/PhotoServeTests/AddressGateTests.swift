import XCTest
import PhotoServe

/// Lock one of the phone companion: nothing off the local network gets in.
/// Mirrors the AddressGate scenarios in `pv-pipeline`.
final class AddressGateTests: XCTestCase {
    func testAcceptsLoopbackRFC1918LinkLocalAndULA() {
        let allowed = [
            "127.0.0.1", "10.0.0.5", "10.255.255.254",
            "172.16.0.1", "172.31.255.254",
            "192.168.1.20", "169.254.10.1",
            "::1", "fe80::1c2b:3d4e", "fe80::1%en0", "fd00::42",
            "::ffff:192.168.1.20", "::ffff:127.0.0.1", "::FFFF:10.0.0.1",
        ]
        for host in allowed {
            XCTAssertTrue(AddressGate.isPrivate(host), "\(host) should be treated as LAN-local")
        }
    }

    func testRefusesPublicAndMalformedAddresses() {
        let denied = [
            "8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.255.255",
            "192.169.0.1", "203.0.113.7", "2606:4700::1111",
            "", "not-an-address", "999.999.999.999", "10.0.0", "10.0.0.1.2",
            // The mapped prefix must not launder a public address.
            "::ffff:8.8.8.8", "::FFFF:1.1.1.1",
            // Int("+127") parses, but it is not a real octet.
            "+127.0.0.1",
        ]
        for host in denied {
            XCTAssertFalse(AddressGate.isPrivate(host), "\(host) must be refused")
        }
    }
}
