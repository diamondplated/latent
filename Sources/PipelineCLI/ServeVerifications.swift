import Foundation
import PhotoServe

// MARK: - HTTP message verifications

func httpParsesRequestLineAndHeaders() async throws {
    let raw = Data("GET /api/folder/abc?limit=20 HTTP/1.1\r\nHost: 192.168.1.5:8080\r\nAuthorization: Bearer deadbeef\r\n\r\n".utf8)
    guard let req = HTTPRequest(parsing: raw) else {
        throw VerifyError(message: "parse returned nil for a well-formed request")
    }
    try require(req.method == "GET", "method = \(req.method)")
    try require(req.path == "/api/folder/abc", "path = \(req.path)")
    try require(req.query["limit"] == "20", "query limit = \(String(describing: req.query["limit"]))")
    try require(req.headers["host"] == "192.168.1.5:8080", "header lookup should be case-insensitive")
    try require(req.bearerToken == "deadbeef", "bearerToken = \(String(describing: req.bearerToken))")
}

func httpParsesBodyByContentLength() async throws {
    let body = #"{"action":"pick"}"#
    let raw = Data("POST /api/action HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    guard let req = HTTPRequest(parsing: raw) else {
        throw VerifyError(message: "parse returned nil")
    }
    try require(req.method == "POST", "method = \(req.method)")
    try require(String(decoding: req.body, as: UTF8.self) == body, "body round-trip failed")
}

func httpRejectsMalformedRequests() async throws {
    let cases: [String] = [
        "",                                    // empty
        "GET\r\n\r\n",                         // request line missing path + version
        "GET /x HTTP/1.1\r\n",                 // headers never terminated
        "GET /x HTTP/1.1\r\nBad-Header\r\n\r\n" // header with no colon
    ]
    for c in cases {
        let parsed = HTTPRequest(parsing: Data(c.utf8))
        try require(parsed == nil, "expected nil for malformed input: \(c.debugDescription)")
    }
}

func httpExpectedLengthDetectsIncompleteRequest() async throws {
    let partial = Data("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)
    try require(HTTPRequest.expectedLength(of: partial) == nil,
                "an incomplete body must report nil so the connection keeps reading")

    let complete = Data("POST /x HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc".utf8)
    try require(HTTPRequest.expectedLength(of: complete) == complete.count,
                "a complete request must report its own byte count")
}

func httpParsesFromNonZeroStartIndexSlice() async throws {
    // `headerTerminator` matches against `[UInt8](buffer)`, which is always
    // 0-based, while `buffer` itself may not be (a `Data` slice keeps its
    // parent's indices). Pin every read that depends on that offset —
    // method, path, a header, and the Content-Length body — against a slice
    // whose startIndex is nonzero, plus expectedLength(of:) on the same slice.
    let body = #"{"action":"pick"}"#
    let requestBytes = Data(
        "POST /api/action?limit=5 HTTP/1.1\r\nHost: 192.168.1.5:8080\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8
    )
    let combined = Data([0xFF, 0xFF]) + requestBytes
    let sliced = combined.dropFirst(2)
    try require(sliced.startIndex != 0, "test fixture must have a non-zero startIndex, got \(sliced.startIndex)")

    guard let req = HTTPRequest(parsing: sliced) else {
        throw VerifyError(message: "parse returned nil for a non-zero-startIndex slice")
    }
    try require(req.method == "POST", "method = \(req.method)")
    try require(req.path == "/api/action", "path = \(req.path)")
    try require(req.headers["host"] == "192.168.1.5:8080", "header lookup failed on a sliced buffer")
    try require(String(decoding: req.body, as: UTF8.self) == body, "body round-trip failed on a sliced buffer")

    try require(HTTPRequest.expectedLength(of: sliced) == sliced.count,
                "expectedLength(of:) on a sliced buffer = \(String(describing: HTTPRequest.expectedLength(of: sliced))), expected \(sliced.count)")
}

func httpResponseSerializesStatusAndBody() async throws {
    let res = HTTPResponse.json(["ok": true])
    let text = String(decoding: res.serialize(), as: UTF8.self)
    try require(text.hasPrefix("HTTP/1.1 200 OK\r\n"), "status line wrong: \(text.prefix(40))")
    try require(text.contains("Content-Type: application/json"), "missing content type")
    try require(text.contains("Content-Length: \(res.body.count)"), "content length missing or wrong")
    try require(text.contains("\r\n\r\n"), "missing header/body separator")

    let notFound = HTTPResponse.status(404)
    try require(String(decoding: notFound.serialize(), as: UTF8.self).hasPrefix("HTTP/1.1 404 Not Found\r\n"),
                "404 status line wrong")
}
