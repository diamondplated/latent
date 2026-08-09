import Foundation
import CryptoKit

public enum PairingError: Error, Equatable, Sendable {
    case noActiveCode
    case codeExpired
    case wrongCode
    case rateLimited
}

public struct PairedDevice: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    /// SHA-256 hex of the issued token. The token itself is shown once, to
    /// the phone, and never retained here.
    public let tokenHash: String
    public let pairedAt: Date
}

/// Pairing codes and device tokens.
///
/// The QR carries a one-time code, not a token. A photograph of the screen
/// taken after redemption is worthless, and a sniffed redemption cannot be
/// replayed. Approval of a redemption is deliberately *not* here — that is a
/// UI decision owned by the app, which keeps this type pure and testable.
public actor PairingManager {
    /// How long a displayed code stays redeemable. Long enough to walk to
    /// the Mac and scan; short enough that a stale screenshot is useless.
    public static let codeLifetime: TimeInterval = 60
    /// Failed redemption attempts allowed per rolling minute.
    public static let maxAttemptsPerMinute = 5

    private struct ActiveCode {
        let value: String
        let issuedAt: Date
    }

    private var activeCode: ActiveCode?
    private var recentFailures: [Date] = []
    private var pairedDevices: [PairedDevice] = []

    public init() {}

    // MARK: - Codes

    /// Mint a fresh 128-bit code, replacing any code already on screen.
    public func issueCode(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let code = bytes.map { String(format: "%02x", $0) }.joined()
        activeCode = ActiveCode(value: code, issuedAt: now)
        return code
    }

    /// Stop accepting the current code — called when the pairing sheet closes.
    public func clearCode() {
        activeCode = nil
    }

    /// Check a submitted code. On success the code is consumed, so a replay
    /// sees `.noActiveCode`. On failure the attempt counts toward the limit.
    public func validate(code: String, now: Date = Date()) throws {
        recentFailures.removeAll { now.timeIntervalSince($0) > 60 }
        guard recentFailures.count < Self.maxAttemptsPerMinute else {
            throw PairingError.rateLimited
        }
        guard let active = activeCode else {
            recentFailures.append(now)
            throw PairingError.noActiveCode
        }
        guard now.timeIntervalSince(active.issuedAt) <= Self.codeLifetime else {
            activeCode = nil
            recentFailures.append(now)
            throw PairingError.codeExpired
        }
        guard Self.constantTimeEquals(code, active.value) else {
            recentFailures.append(now)
            throw PairingError.wrongCode
        }
        activeCode = nil
    }

    // MARK: - Devices

    /// Issue a 256-bit token for a newly approved device. The raw token is
    /// returned once, for the phone; only its digest is kept.
    public func registerDevice(name: String, now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        pairedDevices.append(
            PairedDevice(id: UUID(), name: name, tokenHash: Self.hash(token), pairedAt: now)
        )
        return token
    }

    public func isValidToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let candidate = Self.hash(token)
        // Compare against every device rather than short-circuiting, so the
        // time taken does not depend on which device matched.
        var matched = false
        for device in pairedDevices where Self.constantTimeEquals(candidate, device.tokenHash) {
            matched = true
        }
        return matched
    }

    public func devices() -> [PairedDevice] { pairedDevices }

    public func revoke(deviceID: UUID) {
        pairedDevices.removeAll { $0.id == deviceID }
    }

    public func revokeAll() {
        pairedDevices.removeAll()
        activeCode = nil
    }

    // MARK: - Helpers

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Length is not secret here — codes and digests are fixed-width — but
    /// the contents are, so the comparison must not stop at the first
    /// differing byte.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
