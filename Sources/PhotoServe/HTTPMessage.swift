import Foundation

/// The subset of HTTP/1.1 this server speaks. Deliberately small: it serves
/// a handful of JSON routes, some JPEGs, one HTML file and one SSE stream to
/// a browser on the same LAN. No chunked transfer, no pipelining, no range
/// requests (nothing served is big enough to seek into), no keep-alive
/// beyond what the browser gets by default.
public struct HTTPRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    /// Header names are lowercased at parse time so lookups are case-insensitive.
    public let headers: [String: String]
    public let body: Data

    /// Maximum bytes accepted for a request. The largest legitimate request
    /// is a pairing POST of a few hundred bytes; anything near this cap is
    /// either a bug or someone probing.
    public static let maxRequestBytes = 64 * 1024

    public var bearerToken: String? {
        guard let auth = headers["authorization"], auth.hasPrefix("Bearer ") else { return nil }
        return String(auth.dropFirst("Bearer ".count))
    }

    /// Total byte length of the complete request at the front of `buffer`, or
    /// `nil` if more bytes are still needed. The connection handler uses this
    /// to know when to stop reading.
    public static func expectedLength(of buffer: Data) -> Int? {
        guard let headerEnd = headerTerminator(in: buffer) else { return nil }
        let headerBytes = (headerEnd - buffer.startIndex) + 4
        let head = String(decoding: buffer[..<headerEnd], as: UTF8.self)
        let contentLength = head
            .split(separator: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
                else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        let total = headerBytes + contentLength
        return buffer.count >= total ? total : nil
    }

    public init?(parsing buffer: Data) {
        guard buffer.count <= Self.maxRequestBytes else { return nil }
        guard let headerEnd = Self.headerTerminator(in: buffer) else { return nil }

        let head = String(decoding: buffer[..<headerEnd], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { return nil }
        self.method = String(requestLine[0])

        let target = String(requestLine[1])
        if let q = target.firstIndex(of: "?") {
            self.path = String(target[..<q])
            self.query = Self.parseQuery(String(target[target.index(after: q)...]))
        } else {
            self.path = target
            self.query = [:]
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            headers[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                parts[1].trimmingCharacters(in: .whitespaces)
        }
        self.headers = headers

        let bodyStart = headerEnd + 4
        let declared = Int(headers["content-length"] ?? "") ?? 0
        let available = buffer.endIndex - bodyStart
        self.body = declared > 0 ? buffer[bodyStart..<(bodyStart + min(declared, available))] : Data()
    }

    /// Absolute `buffer` index of the `\r\n\r\n` that ends the header block.
    /// `[UInt8](buffer)` is always 0-based regardless of `buffer`'s own
    /// indices (a `Data` slice does not reindex from zero), so the match
    /// offset is converted back to `buffer`'s index space here — once, in
    /// the one place that finds it — rather than leaving every caller to
    /// remember the `+ buffer.startIndex` conversion itself.
    private static func headerTerminator(in buffer: Data) -> Int? {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == pattern {
            return buffer.startIndex + i
        }
        return nil
    }

    private static func parseQuery(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first?.removingPercentEncoding else { continue }
            out[key] = kv.count == 2 ? (kv[1].removingPercentEncoding ?? "") : ""
        }
        return out
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: data)
    }

    public static func data(_ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: ["Content-Type": contentType], body: data)
    }

    public static func status(_ code: Int) -> HTTPResponse {
        HTTPResponse(status: code)
    }

    public func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        // The client is served from this same origin, so no CORS. Deny
        // framing and sniffing rather than leaving the browser to guess.
        all["X-Content-Type-Options"] = "nosniff"
        all["X-Frame-Options"] = "DENY"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default:  return "Error"
        }
    }
}
