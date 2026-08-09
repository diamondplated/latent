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

func httpRefusesHostileContentLength() async throws {
    // Content-Length arrives from an unauthenticated peer and feeds both the
    // `headerBytes + contentLength` arithmetic in expectedLength(of:) and the
    // body slicing in init(parsing:). A 64-byte request must be refused, not
    // trap the process — an arithmetic overflow here takes the whole app down.
    let hostile = [
        "9223372036854775807",   // Int.max: header bytes + this overflows
        "-1",                    // negative
        "99999999",              // far past maxRequestBytes
        "abc",                   // not a number at all
    ]
    for value in hostile {
        let raw = Data("POST /api/pair HTTP/1.1\r\nContent-Length: \(value)\r\n\r\n".utf8)
        try require(HTTPRequest.expectedLength(of: raw) == nil,
                    "expectedLength must refuse Content-Length: \(value)")
        try require(HTTPRequest(parsing: raw) == nil,
                    "init(parsing:) must refuse Content-Length: \(value)")
    }

    // Conflicting duplicates are a smuggling primitive: the two functions
    // must never disagree about which value wins.
    let conflicting = Data("POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc".utf8)
    try require(HTTPRequest.expectedLength(of: conflicting) == nil,
                "expectedLength must refuse conflicting Content-Length headers")
    try require(HTTPRequest(parsing: conflicting) == nil,
                "init(parsing:) must refuse conflicting Content-Length headers")
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

// MARK: - Pairing verifications

func pairingCodeIsSingleUse() async throws {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let mgr = PairingManager()
    let code = await mgr.issueCode(now: now)

    try await mgr.validate(code: code, now: now.addingTimeInterval(5))

    do {
        try await mgr.validate(code: code, now: now.addingTimeInterval(6))
        throw VerifyError(message: "second redemption of the same code must fail")
    } catch let e as PairingError {
        try require(e == .noActiveCode, "expected .noActiveCode on replay, got \(e)")
    }
}

func pairingCodeExpires() async throws {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let mgr = PairingManager()
    let code = await mgr.issueCode(now: now)

    do {
        try await mgr.validate(code: code, now: now.addingTimeInterval(61))
        throw VerifyError(message: "a code older than 60s must not validate")
    } catch let e as PairingError {
        try require(e == .codeExpired, "expected .codeExpired, got \(e)")
    }
}

func pairingRejectsWrongCodeAndRateLimits() async throws {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let mgr = PairingManager()
    _ = await mgr.issueCode(now: now)

    // Five wrong guesses are refused as wrong; the sixth is rate limited.
    for attempt in 1...5 {
        do {
            try await mgr.validate(code: "0000", now: now.addingTimeInterval(Double(attempt)))
            throw VerifyError(message: "wrong code accepted on attempt \(attempt)")
        } catch let e as PairingError {
            try require(e == .wrongCode, "attempt \(attempt): expected .wrongCode, got \(e)")
        }
    }
    do {
        try await mgr.validate(code: "0000", now: now.addingTimeInterval(6))
        throw VerifyError(message: "sixth attempt in a minute must be rate limited")
    } catch let e as PairingError {
        try require(e == .rateLimited, "expected .rateLimited, got \(e)")
    }
}

func pairingCodeHasEnoughEntropy() async throws {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    var seen = Set<String>()
    for _ in 0..<200 {
        let mgr = PairingManager()
        let code = await mgr.issueCode(now: now)
        try require(code.count == 32, "expected 32 hex chars (128 bits), got \(code.count)")
        try require(code.allSatisfy { $0.isHexDigit }, "code is not hex: \(code)")
        seen.insert(code)
    }
    try require(seen.count == 200, "codes repeated across 200 draws — not random")
}

func pairingTokensValidateAndRevoke() async throws {
    let mgr = PairingManager()
    let token = await mgr.registerDevice(name: "iPhone")

    // `require` takes a non-async @autoclosure, so awaited values are bound
    // to a local `let` first and asserted on afterward.
    let validFreshToken = await mgr.isValidToken(token)
    try require(validFreshToken, "freshly issued token must validate")
    let validLongerToken = await mgr.isValidToken(token + "x")
    try require(!validLongerToken, "a longer token must not validate")
    let validEmptyToken = await mgr.isValidToken("")
    try require(!validEmptyToken, "empty token must not validate")
    let validSameLengthWrongToken = await mgr.isValidToken(String(repeating: "a", count: token.count))
    try require(!validSameLengthWrongToken, "a same-length wrong token must not validate")

    let devices = await mgr.devices()
    try require(devices.count == 1, "expected 1 device, got \(devices.count)")
    try require(devices[0].name == "iPhone", "device name lost")

    await mgr.revoke(deviceID: devices[0].id)
    let validAfterRevoke = await mgr.isValidToken(token)
    try require(!validAfterRevoke, "revoked token must stop validating")
    let devicesAfterRevoke = await mgr.devices()
    try require(devicesAfterRevoke.isEmpty, "device list should be empty after revoke")
}

func pairingStoresTokenHashNotToken() async throws {
    let mgr = PairingManager()
    let token = await mgr.registerDevice(name: "iPad")
    let devices = await mgr.devices()
    try require(devices[0].tokenHash != token, "the raw token must not be retained")
    try require(devices[0].tokenHash.count == 64, "expected a SHA-256 hex digest, got \(devices[0].tokenHash.count) chars")
}

// MARK: - Router verifications

/// Minimal delegate that records what the router asked for.
actor StubServeDelegate: ServeDelegate {
    var actionsApplied: [(String, PhoneAction)] = []
    var approvalAnswer = true
    /// Nil is the shipped default: no model weights, so no index, so no search.
    var searchAnswer: [String]?

    func setApprovalAnswer(_ v: Bool) { approvalAnswer = v }
    func setSearchAnswer(_ v: [String]?) { searchAnswer = v }

    func approvePairing(deviceName: String, fromHost: String) async -> Bool { approvalAnswer }
    func folderList() async -> [SharedFolderSummary] {
        [SharedFolderSummary(id: "F1", name: "2024", photoCount: 1)]
    }
    func photoList(folderID: String) async -> [PhonePhoto] {
        [PhonePhoto(id: "P1", name: "a.jpg", isPicked: false, isRejected: false, colorLabel: 0)]
    }
    func thumbnailJPEG(photoID: String) async -> Data? {
        photoID == "P1" ? Data([0xFF, 0xD8, 0xFF]) : nil
    }
    func previewJPEG(photoID: String) async -> Data? {
        photoID == "P1" ? Data([0xFF, 0xD8, 0xFF, 0xE0]) : nil
    }
    func apply(action: PhoneAction, photoID: String) async {
        actionsApplied.append((photoID, action))
    }
    func search(folderID: String, query: String) async -> [String]? { searchAnswer }
    func recorded() -> [(String, PhoneAction)] { actionsApplied }
}

func routerRefusesUnauthenticatedAPIRequests() async throws {
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())

    let req = HTTPRequest(parsing: Data("GET /api/folders HTTP/1.1\r\n\r\n".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 401, "expected 401 without a token, got \(res.status)")
}

func routerRefusesNonPrivateHosts() async throws {
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())
    let token = await pairing.registerDevice(name: "iPhone")

    let req = HTTPRequest(parsing: Data("GET /api/folders HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8))!
    let res = await router.handle(req, from: "8.8.8.8")
    try require(res.status == 403, "a valid token from a public address must still be refused, got \(res.status)")
}

func routerServesAPIWithValidToken() async throws {
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())
    let token = await pairing.registerDevice(name: "iPhone")

    let req = HTTPRequest(parsing: Data("GET /api/folders HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 200, "expected 200, got \(res.status)")

    let json = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
    let folders = json?["folders"] as? [[String: Any]]
    try require(folders?.count == 1, "expected 1 folder in the payload")
    try require(folders?[0]["name"] as? String == "2024", "folder name missing")
}

func routerPairingRequiresApproval() async throws {
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    // The router validates against the wall clock, so the code has to be
    // issued on it too — a fixed epoch would read as expired.
    let code = await pairing.issueCode()

    await delegate.setApprovalAnswer(false)
    let body = #"{"code":"\#(code)","deviceName":"iPhone"}"#
    let denied = HTTPRequest(parsing: Data("POST /api/pair HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(denied, from: "192.168.1.9")
    try require(res.status == 403, "a declined pairing must not issue a token, got \(res.status)")
    let devices = await pairing.devices()
    try require(devices.isEmpty, "no device may be registered when approval is declined")
}

func routerPairingIssuesTokenWhenApproved() async throws {
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())
    let code = await pairing.issueCode()

    let body = #"{"code":"\#(code)","deviceName":"iPhone"}"#
    let req = HTTPRequest(parsing: Data("POST /api/pair HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 200, "expected 200, got \(res.status)")

    let json = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
    let token = json?["token"] as? String
    try require(token != nil, "response carried no token")
    let tokenValidates = await pairing.isValidToken(token!)
    try require(tokenValidates, "issued token does not validate")
}

func routerMapsSwipeActionsToVimActions() async throws {
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    let token = await pairing.registerDevice(name: "iPhone")

    let body = #"{"photoID":"P1","action":"pick"}"#
    let req = HTTPRequest(parsing: Data("POST /api/action HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 200, "expected 200, got \(res.status)")

    let recorded = await delegate.recorded()
    try require(recorded.count == 1, "expected 1 applied action, got \(recorded.count)")
    try require(recorded[0].0 == "P1", "wrong photo ID")
    try require(recorded[0].1 == .pick, "wrong action: \(recorded[0].1)")
}

func sseFramesAreWellFormed() async throws {
    let frame = String(decoding: SSEFrame.encode(event: "photo", data: #"{"id":"P1","picked":true}"#), as: UTF8.self)
    try require(frame.hasPrefix("event: photo\n"), "missing event line: \(frame.debugDescription)")
    try require(frame.contains("data: {\"id\":\"P1\",\"picked\":true}\n"), "missing data line")
    try require(frame.hasSuffix("\n\n"), "an SSE frame must end with a blank line")
}

func sseFramesEscapeNewlinesInData() async throws {
    let frame = String(decoding: SSEFrame.encode(event: "note", data: "line one\nline two"), as: UTF8.self)
    // A raw newline inside data would terminate the frame early; each line
    // must carry its own `data:` prefix.
    try require(frame.contains("data: line one\ndata: line two\n"),
                "multi-line payload not split across data lines: \(frame.debugDescription)")
    try require(frame.hasSuffix("\n\n"), "frame must still end with a blank line")
}

func routerRejectsUnknownActionNames() async throws {
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    let token = await pairing.registerDevice(name: "iPhone")

    let body = #"{"photoID":"P1","action":"rm -rf"}"#
    let req = HTTPRequest(parsing: Data("POST /api/action HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 400, "unknown action must be rejected, got \(res.status)")
    let recorded = await delegate.recorded()
    try require(recorded.isEmpty, "nothing should have been applied")
}

func routerHidesSearchWhenTheFolderHasNoIndex() async throws {
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())
    let token = await pairing.registerDevice(name: "iPhone")

    // The delegate says nil when there are no CLIP assets or no index, which is
    // the shipped default. The phone reads the 404 as "hide the search box" —
    // not as an error — so this status is load-bearing, not cosmetic.
    let req = HTTPRequest(parsing: Data("GET /api/search/F1?q=dog HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 404, "an unsearchable folder must 404, got \(res.status)")

    let empty = HTTPRequest(parsing: Data("GET /api/search/F1?q= HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8))!
    let emptyRes = await router.handle(empty, from: "192.168.1.9")
    try require(emptyRes.status == 400, "an empty query must be rejected, got \(emptyRes.status)")
}

func routerPreservesSearchRankOrder() async throws {
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    let token = await pairing.registerDevice(name: "iPhone")

    // Deliberately not sorted: the ranking by similarity is the answer, and the
    // phone renders the array in the order it arrives.
    let ranked = ["P9", "P2", "P7"]
    await delegate.setSearchAnswer(ranked)

    let req = HTTPRequest(parsing: Data("GET /api/search/F1?q=dog HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 200, "expected 200, got \(res.status)")

    let json = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
    let ids = json?["photoIDs"] as? [String]
    try require(ids == ranked, "rank order lost on the wire: \(ids ?? [])")
}
