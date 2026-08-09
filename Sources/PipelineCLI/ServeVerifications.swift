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

// MARK: - Address gate verifications

func addressGateAcceptsPrivateRanges() async throws {
    let allowed = [
        "127.0.0.1", "10.0.0.5", "10.255.255.254",
        "172.16.0.1", "172.31.255.254",
        "192.168.1.20", "169.254.10.1",
        "::1", "fe80::1c2b:3d4e", "fd00::42",
        // IPv4-mapped IPv6, the form a dual-stack listener presents an
        // IPv4 peer in (Darwin included) — Task 5 stands up exactly this.
        "::ffff:192.168.1.20", "::ffff:127.0.0.1",
        "::FFFF:10.0.0.1",   // mixed-case prefix must match too
    ]
    for host in allowed {
        try require(AddressGate.isPrivate(host), "\(host) should be treated as LAN-local")
    }
}

func addressGateRejectsPublicAddresses() async throws {
    let denied = [
        "8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.255.255",
        "192.169.0.1", "203.0.113.7", "2606:4700::1111",
        "", "not-an-address", "999.999.999.999",
        "::ffff:8.8.8.8", "::FFFF:1.1.1.1",  // mapped prefix must not launder public addresses
        "+127.0.0.1",                        // leading '+' is not a real octet
    ]
    for host in denied {
        try require(!AddressGate.isPrivate(host), "\(host) must be refused")
    }
}

// MARK: - SharedFolders verifications

func sharedFoldersResolveOnlyIssuedIDs() async throws {
    let root = URL(fileURLWithPath: "/Users/someone/Pictures/2024")
    let photos = [root.appendingPathComponent("a.jpg"), root.appendingPathComponent("b.jpg")]

    let shared = SharedFolders()
    let folderID = await shared.share(folder: root, photos: photos)

    let entries = await shared.photos(in: folderID)
    try require(entries.count == 2, "expected 2 entries, got \(entries.count)")

    let first = entries[0]
    let resolved = await shared.photoURL(forID: first.id)
    try require(resolved == photos[0], "issued ID resolved to \(String(describing: resolved))")

    // IDs are opaque: they must not contain the filename or any path text.
    try require(!first.id.contains("a.jpg") && !first.id.contains("/"),
                "photo ID leaks path information: \(first.id)")
}

func sharedFoldersRejectUnknownAndTraversalIDs() async throws {
    let root = URL(fileURLWithPath: "/Users/someone/Pictures/2024")
    let shared = SharedFolders()
    _ = await shared.share(folder: root, photos: [root.appendingPathComponent("a.jpg")])

    let hostile = [
        "../../../etc/passwd",
        "/etc/passwd",
        "a.jpg",
        "",
        UUID().uuidString,   // well-formed but never issued
    ]
    for id in hostile {
        let resolved = await shared.photoURL(forID: id)
        try require(resolved == nil, "id \(id.debugDescription) must not resolve, got \(String(describing: resolved))")
    }
}

func sharedFoldersUnshareInvalidatesIDs() async throws {
    let root = URL(fileURLWithPath: "/Users/someone/Pictures/2024")
    let photo = root.appendingPathComponent("a.jpg")
    let shared = SharedFolders()
    let folderID = await shared.share(folder: root, photos: [photo])
    let entries = await shared.photos(in: folderID)
    let id = entries[0].id

    let resolvedBeforeUnshare = await shared.photoURL(forID: id)
    try require(resolvedBeforeUnshare != nil, "id should resolve while shared")
    await shared.unshare(folderID)
    let resolvedAfterUnshare = await shared.photoURL(forID: id)
    try require(resolvedAfterUnshare == nil, "id must stop resolving after unshare")
    let remainingFolders = await shared.folders()
    try require(remainingFolders.isEmpty, "folder list should be empty after unshare")
}
