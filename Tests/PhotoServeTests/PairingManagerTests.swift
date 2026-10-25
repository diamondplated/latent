import XCTest
import PhotoServe

/// One-time pairing codes and revocable device tokens.
/// Mirrors the PairingManager scenarios in `pv-pipeline`.
final class PairingManagerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func assertThrows(
        _ expected: PairingError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
        } catch let error as PairingError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testCodeWorksExactlyOnce() async throws {
        let mgr = PairingManager()
        let code = await mgr.issueCode(now: epoch)
        try await mgr.validate(code: code, now: epoch.addingTimeInterval(5))
        await assertThrows(.noActiveCode) {
            try await mgr.validate(code: code, now: self.epoch.addingTimeInterval(6))
        }
    }

    func testCodeExpiresAfterItsLifetime() async {
        let mgr = PairingManager()
        let code = await mgr.issueCode(now: epoch)
        await assertThrows(.codeExpired) {
            try await mgr.validate(code: code, now: self.epoch.addingTimeInterval(PairingManager.codeLifetime + 1))
        }
    }

    func testClearedCodeNoLongerValidates() async {
        let mgr = PairingManager()
        let code = await mgr.issueCode(now: epoch)
        await mgr.clearCode()
        await assertThrows(.noActiveCode) {
            try await mgr.validate(code: code, now: self.epoch.addingTimeInterval(1))
        }
    }

    func testWrongCodesAreRefusedThenRateLimited() async {
        let mgr = PairingManager()
        let code = await mgr.issueCode(now: epoch)
        for attempt in 1...PairingManager.maxAttemptsPerMinute {
            await assertThrows(.wrongCode) {
                try await mgr.validate(code: "0000", now: self.epoch.addingTimeInterval(Double(attempt)))
            }
        }
        // Once limited, even the right code is refused until the window rolls.
        await assertThrows(.rateLimited) {
            try await mgr.validate(code: code, now: self.epoch.addingTimeInterval(10))
        }
    }

    func testCodesAre128BitHexAndDoNotRepeat() async {
        var seen = Set<String>()
        for _ in 0..<200 {
            let code = await PairingManager().issueCode(now: epoch)
            XCTAssertEqual(code.count, 32)
            XCTAssertTrue(code.allSatisfy(\.isHexDigit), "code is not hex: \(code)")
            seen.insert(code)
        }
        XCTAssertEqual(seen.count, 200, "codes repeated across 200 draws")
    }

    func testTokensValidateAndRevoke() async {
        let mgr = PairingManager()
        let token = await mgr.registerDevice(name: "iPhone")

        let fresh = await mgr.isValidToken(token)
        let longer = await mgr.isValidToken(token + "x")
        let empty = await mgr.isValidToken("")
        let sameLengthWrong = await mgr.isValidToken(String(repeating: "a", count: token.count))
        XCTAssertTrue(fresh)
        XCTAssertFalse(longer)
        XCTAssertFalse(empty)
        XCTAssertFalse(sameLengthWrong)

        let devices = await mgr.devices()
        XCTAssertEqual(devices.map(\.name), ["iPhone"])
        await mgr.revoke(deviceID: devices[0].id)
        let afterRevoke = await mgr.isValidToken(token)
        XCTAssertFalse(afterRevoke, "a revoked token must stop validating")
    }

    func testRevokeAllDropsEveryTokenAndTheActiveCode() async {
        let mgr = PairingManager()
        let a = await mgr.registerDevice(name: "iPhone")
        let b = await mgr.registerDevice(name: "iPad")
        let code = await mgr.issueCode(now: epoch)
        await mgr.revokeAll()

        let aValid = await mgr.isValidToken(a)
        let bValid = await mgr.isValidToken(b)
        XCTAssertFalse(aValid)
        XCTAssertFalse(bValid)
        await assertThrows(.noActiveCode) {
            try await mgr.validate(code: code, now: self.epoch.addingTimeInterval(1))
        }
    }

    func testStoresTokenDigestNotToken() async {
        let mgr = PairingManager()
        let token = await mgr.registerDevice(name: "iPad")
        let device = await mgr.devices()[0]
        XCTAssertNotEqual(device.tokenHash, token, "the raw token must not be retained")
        XCTAssertEqual(device.tokenHash.count, 64, "expected a SHA-256 hex digest")
    }
}
