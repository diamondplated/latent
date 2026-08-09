import Foundation

/// Refuses any peer that is not on a local network.
///
/// The listener is already bound to a LAN interface, so this is the second
/// of two locks rather than the only one. It exists because the cost of
/// being wrong — a photo folder reachable from off-network — is high enough
/// that one misconfigured router should not be sufficient to cause it.
public enum AddressGate {
    public static func isPrivate(_ host: String) -> Bool {
        // Strip an IPv6 zone index (fe80::1%en0) before parsing.
        let bare = host.split(separator: "%").first.map(String.init) ?? host
        if bare.contains(":") { return isPrivateIPv6(bare) }
        return isPrivateIPv4(bare)
    }

    static func isPrivateIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for p in parts {
            // Int("+1") parses fine but "+127.0.0.1" is not a real octet string;
            // require plain digits before converting.
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(p), (0...255).contains(v) else { return false }
            octets.append(v)
        }
        switch (octets[0], octets[1]) {
        case (127, _):                       return true   // loopback
        case (10, _):                        return true   // RFC1918 /8
        case (172, 16...31):                 return true   // RFC1918 /12
        case (192, 168):                     return true   // RFC1918 /16
        case (169, 254):                     return true   // link-local
        default:                             return false
        }
    }

    static func isPrivateIPv6(_ s: String) -> Bool {
        let lower = s.lowercased()
        // Dual-stack listeners (Darwin included) present IPv4 peers as
        // ::ffff:a.b.c.d. Strip the mapped prefix and re-dispatch to the
        // IPv4 check rather than duplicating the range logic here.
        if lower.hasPrefix("::ffff:") {
            return isPrivateIPv4(String(lower.dropFirst("::ffff:".count)))
        }
        if lower == "::1" { return true }                       // loopback
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }  // fe80::/10
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }        // fc00::/7 ULA
        return false
    }
}
