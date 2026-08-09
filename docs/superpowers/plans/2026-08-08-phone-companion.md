# Phone Companion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a paired phone browse and cull a shared folder over the LAN, by serving a small web app from inside the running Latent process.

**Architecture:** A new `PhotoServe` library owns HTTP transport, pairing, and opaque photo IDs, and knows nothing about the app. A thin `PhoneAccessController` in `PhotoViewerApp` bridges it to `AppState`. The phone sends `VimAction` values that `AppState.dispatch` applies through the same path the keyboard uses, so there is exactly one writer to any sidecar.

**Tech Stack:** Swift 6, SwiftUI, Network.framework (`NWListener`), CryptoKit, CoreImage (`CIQRCodeGenerator`), ImageIO. Client is one hand-written HTML file, no framework, no build step.

## Global Constraints

- **Zero external SwiftPM dependencies.** `Package.swift` has none today and gains none. No swift-nio, no Vapor, no QR library.
- **Swift tools 6.0, `.macOS(.v14)` platform floor.** Do not raise either.
- **The dev machine has only the macOS 26 SDK; CI builds against macos-15 and is the only oracle.** Prefer long-stable APIs. Do not claim a build is verified based on a local build alone.
- **Verification is `swift run pv-pipeline`** — assert-based, needs no Xcode and no model weights. Every new verification is registered in `Sources/PipelineCLI/CLI.swift` and uses the existing `runVerification` / `require` / `VerifyError` helpers.
- **`@MainActor` types are reached from `pv-pipeline` via `try await Task { @MainActor in ... }.value`**, matching the existing `VimKeymap` verifications in `CLI.swift:45-62`.
- **Commit as `580248+diamondplated@users.noreply.github.com`.** Already set as the local git identity on this clone.
- **Sentence case in all user-facing copy.** Matches existing UI strings.
- **The feature is off by default** and its listener must not exist until explicitly enabled.

---

### Task 1: Move `VimKeymap` to `AppState` and extract `dispatch`

Pure refactor, no behavior change. Today the dispatch `switch` is inside a SwiftUI view method and the keymap is `@State private`, so nothing outside `BrowserView` can reach either. Every later task depends on this seam.

**Files:**
- Modify: `Sources/PhotoViewerApp/AppState.swift` (add property + method near the selection delegation block, ~line 524)
- Modify: `Sources/PhotoViewerApp/BrowserView.swift:16` (remove `@State`), `:122-123` (load into state), `:297-299` (read through state), `:435-459` (dispatch), `:449`, `:454`
- Modify: `Sources/PhotoViewerApp/FilterBar.swift:62` (call site passes `state.vimKeymap`)

**Interfaces:**
- Consumes: `VimKeymap`, `VimAction` from `PhotoViewerCore` (already public)
- Produces: `AppState.vimKeymap: VimKeymap` and `AppState.dispatch(_ action: VimAction)`. Task 6 calls `dispatch`; Tasks 5 and 8 read `vimKeymap.isPicked(_:)`, `isRejected(_:)`, `colorLabel(for:)`.

- [ ] **Step 1: Add the property and dispatch method to `AppState`**

In `Sources/PhotoViewerApp/AppState.swift`, add to the composed sub-objects block (after `let prefetcher = ImagePrefetcher(capacity: 5)` at line 58):

```swift
    /// Vim keymap state: marks, colour labels, picks, rejects. Lives here
    /// rather than on BrowserView because the keyboard is no longer the only
    /// input device — the phone companion dispatches the same `VimAction`
    /// values through `dispatch(_:)`. One owner, one writer.
    var vimKeymap = VimKeymap()
```

Add `import PhotoViewerCore` to the top of the file.

Then add, in the `// MARK: - Selection delegation` section (after `func select(url: URL)` at line 530):

```swift
    // MARK: - Vim action dispatch

    /// Apply one `VimAction`, whatever produced it. The keyboard produces
    /// these via `VimKeymap.handle`; the phone companion produces them from
    /// swipe gestures. Both land here, so picks, rejects, labels and the
    /// sidecar write happen in exactly one place.
    ///
    /// `VimKeymap` has already mutated its own state for the label/pick/
    /// reject/mark cases by the time we see the action — this method's job is
    /// navigation plus persistence.
    func dispatch(_ action: VimAction) {
        switch action {
        case .next:  selectNext()
        case .prev:  selectPrevious()
        case .first: selectFirst()
        case .last:  selectLast()
        case .jumpToMark(let c):
            if let url = vimKeymap.marks[c] { select(url: url) }
        case .setMark, .setColorLabel, .togglePick, .toggleReject:
            if let folder { vimKeymap.saveInBackground(folder: folder) }
        case .none:
            break
        }
    }
```

Note this uses `vimKeymap.saveInBackground(folder:)` (already implemented at `VimKeymap.swift:259`) rather than `BrowserView`'s current `Task.detached { try? vimKeymap.save(folder:) }`. It is the API built for exactly this and it snapshots on the main actor before writing.

- [ ] **Step 2: Point `BrowserView` at the shared keymap**

In `Sources/PhotoViewerApp/BrowserView.swift`, delete line 16:

```swift
    @State private var vimKeymap = VimKeymap()
```

Add a computed accessor near the top of the view body's helpers so the five read sites need no other change:

```swift
    private var vimKeymap: VimKeymap { state.vimKeymap }
```

At line 122-123, the folder-change loader currently assigns the whole object:

```swift
                if let loaded = try? VimKeymap.load(folder: folder) {
                    vimKeymap = loaded
                }
```

Change the assignment target to the state:

```swift
                if let loaded = try? VimKeymap.load(folder: folder) {
                    state.vimKeymap = loaded
                }
```

- [ ] **Step 3: Replace the dispatch switch with a call**

In `Sources/PhotoViewerApp/BrowserView.swift`, replace lines 443-459 (the `switch action { ... }` block ending with `case .none: return .ignored`) with:

```swift
        if action == .none { return .ignored }
        state.dispatch(action)
        return .handled
```

Leave lines 422-441 (the arrow-key early return and the `vimKeymap.handle` call) exactly as they are.

- [ ] **Step 4: Fix the `FilterBar` call site**

`FilterBar` declares `let vimKeymap: VimKeymap` at line 62 and is constructed by `BrowserView`. The declaration stays; only the argument at the construction site changes, from `vimKeymap` to `state.vimKeymap`. Find it with:

```bash
rg -n 'FilterBar\(' Sources/PhotoViewerApp/
```

- [ ] **Step 5: Build and run the existing verifications**

```bash
swift build && swift run pv-pipeline
```

Expected: builds clean, all existing checks print `PASS`, final line `All checks passed.` The six `VimKeymap:` checks are the ones that matter here — they cover the state mutations this task moved.

No new test is added for `dispatch` itself. `AppState` lives in an `executableTarget`, which `PipelineCLI` cannot import, and the method is twelve lines of straight delegation over an enum whose semantics are already covered by `Tests/PhotoViewerCoreTests/VimKeymapTests.swift`. Building a harness to reach into the app target for that would cost more than it protects.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhotoViewerApp/AppState.swift Sources/PhotoViewerApp/BrowserView.swift Sources/PhotoViewerApp/FilterBar.swift
git commit -m "refactor: move VimKeymap to AppState and extract dispatch

The keyboard is about to stop being the only input device. Ownership moves
off BrowserView so a second producer of VimAction can reach the same state,
and the dispatch switch becomes AppState.dispatch(_:) so picks, rejects,
labels and the sidecar write live in one place.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `PhotoServe` module with HTTP request parsing and response serialization

**Files:**
- Create: `Sources/PhotoServe/HTTPMessage.swift`
- Create: `Sources/PipelineCLI/ServeVerifications.swift`
- Modify: `Package.swift`
- Modify: `Sources/PipelineCLI/CLI.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `HTTPRequest` (with `init?(parsing:)`, `method`, `path`, `query`, `headers`, `body`, `bearerToken`), `HTTPRequest.expectedLength(of:)`, `HTTPResponse` (with `init(status:headers:body:)`, `.json(_:)`, `.data(_:contentType:)`, `.status(_:)`, `serialize()`). Tasks 5, 6, 8, 9 all build on these.

- [ ] **Step 1: Add the target to `Package.swift`**

In the `products:` array, after the `PhotoQuickLook` library entry:

```swift
        .library(name: "PhotoServe", targets: ["PhotoServe"]),
```

In the `targets:` array, after the `PhotoQuickLook` target:

```swift
        .target(
            name: "PhotoServe",
            dependencies: ["PhotoViewerCore"],
            path: "Sources/PhotoServe",
            resources: [.embedInCode("Resources/client.html")]
        ),
```

`.embedInCode` generates `PackageResources.client_html` as `[UInt8]` at build time. This is deliberate over `.copy`: the app is packaged by `scripts/build_app.sh` rather than Xcode, and a compiled-in byte array cannot go missing from a hand-assembled `.app` the way a `Bundle.module` resource can.

Add `"PhotoServe"` to the `PipelineCLI` executable target's `dependencies` array, and to the `PhotoViewerApp` executable target's `dependencies` array.

- [ ] **Step 2: Create the resource file so the target compiles**

```bash
mkdir -p Sources/PhotoServe/Resources
printf '<!doctype html><title>Latent</title><p>placeholder\n' > Sources/PhotoServe/Resources/client.html
```

Task 7 replaces this with the real client.

- [ ] **Step 3: Write the failing verifications**

Create `Sources/PipelineCLI/ServeVerifications.swift`:

```swift
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
```

- [ ] **Step 4: Register the verifications**

In `Sources/PipelineCLI/CLI.swift`, add `import PhotoServe` alongside the other imports, and add these lines immediately before the `PhotoGeo:` line at line 63:

```swift
        failures += await runVerification("HTTPRequest: parses request line, query and case-insensitive headers", check: httpParsesRequestLineAndHeaders)
        failures += await runVerification("HTTPRequest: reads body per Content-Length", check: httpParsesBodyByContentLength)
        failures += await runVerification("HTTPRequest: rejects malformed requests", check: httpRejectsMalformedRequests)
        failures += await runVerification("HTTPRequest: expectedLength reports nil until the body is complete", check: httpExpectedLengthDetectsIncompleteRequest)
        failures += await runVerification("HTTPResponse: serializes status line, headers and body", check: httpResponseSerializesStatusAndBody)
```

- [ ] **Step 5: Run to verify they fail**

```bash
swift build
```

Expected: FAIL to compile with "cannot find 'HTTPRequest' in scope".

- [ ] **Step 6: Implement `HTTPMessage.swift`**

Create `Sources/PhotoServe/HTTPMessage.swift`:

```swift
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
        let headerBytes = headerEnd + 4
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

        let bodyStart = buffer.startIndex + headerEnd + 4
        let declared = Int(headers["content-length"] ?? "") ?? 0
        let available = buffer.endIndex - bodyStart
        self.body = declared > 0 ? buffer[bodyStart..<(bodyStart + min(declared, available))] : Data()
    }

    /// Index of the `\r\n\r\n` that ends the header block.
    private static func headerTerminator(in buffer: Data) -> Int? {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = [UInt8](buffer)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == pattern {
            return i
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
```

- [ ] **Step 7: Run to verify they pass**

```bash
swift build && swift run pv-pipeline
```

Expected: the five new `HTTPRequest`/`HTTPResponse` checks print `PASS`, and every pre-existing check still passes.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/PhotoServe Sources/PipelineCLI/ServeVerifications.swift Sources/PipelineCLI/CLI.swift
git commit -m "feat: add PhotoServe with a minimal HTTP/1.1 subset

Parses request line, query, case-insensitive headers and a Content-Length
body; serializes responses. No chunked encoding, pipelining, range requests
or keep-alive tricks — nothing this server does needs them.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Private-address gate and opaque photo IDs

Two independent guards, both pure enough to test directly. The address gate keeps the listener LAN-only even if the network is misconfigured; opaque IDs make path traversal impossible rather than filtered.

**Files:**
- Create: `Sources/PhotoServe/AddressGate.swift`
- Create: `Sources/PhotoServe/SharedFolders.swift`
- Modify: `Sources/PipelineCLI/ServeVerifications.swift`
- Modify: `Sources/PipelineCLI/CLI.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `AddressGate.isPrivate(_ host: String) -> Bool`; `actor SharedFolders` with `share(folder:photos:) async -> SharedFolderID`, `unshare(_:) async`, `folders() async -> [SharedFolderSummary]`, `photos(in:) async -> [PhotoEntry]`, `photoURL(forID:) async -> URL?`. Tasks 5, 6, 8, 9 consume these.

- [ ] **Step 1: Write the failing verifications**

Append to `Sources/PipelineCLI/ServeVerifications.swift`:

```swift
// MARK: - Address gate verifications

func addressGateAcceptsPrivateRanges() async throws {
    let allowed = [
        "127.0.0.1", "10.0.0.5", "10.255.255.254",
        "172.16.0.1", "172.31.255.254",
        "192.168.1.20", "169.254.10.1",
        "::1", "fe80::1c2b:3d4e", "fd00::42",
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

    try require(await shared.photoURL(forID: id) != nil, "id should resolve while shared")
    await shared.unshare(folderID)
    try require(await shared.photoURL(forID: id) == nil, "id must stop resolving after unshare")
    try require(await shared.folders().isEmpty, "folder list should be empty after unshare")
}
```

Register in `Sources/PipelineCLI/CLI.swift` after the `HTTPResponse:` line:

```swift
        failures += await runVerification("AddressGate: accepts loopback, RFC1918, link-local and ULA", check: addressGateAcceptsPrivateRanges)
        failures += await runVerification("AddressGate: refuses public and malformed addresses", check: addressGateRejectsPublicAddresses)
        failures += await runVerification("SharedFolders: issued IDs resolve and carry no path text", check: sharedFoldersResolveOnlyIssuedIDs)
        failures += await runVerification("SharedFolders: unknown and traversal IDs never resolve", check: sharedFoldersRejectUnknownAndTraversalIDs)
        failures += await runVerification("SharedFolders: unshare invalidates every issued ID", check: sharedFoldersUnshareInvalidatesIDs)
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift build
```

Expected: FAIL with "cannot find 'AddressGate' in scope" and "cannot find 'SharedFolders' in scope".

- [ ] **Step 3: Implement `AddressGate.swift`**

Create `Sources/PhotoServe/AddressGate.swift`:

```swift
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
            guard let v = Int(p), (0...255).contains(v), !p.isEmpty else { return false }
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
        if lower == "::1" { return true }                       // loopback
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }  // fe80::/10
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }        // fc00::/7 ULA
        return false
    }
}
```

- [ ] **Step 4: Implement `SharedFolders.swift`**

Create `Sources/PhotoServe/SharedFolders.swift`:

```swift
import Foundation

public typealias SharedFolderID = String

public struct SharedFolderSummary: Sendable, Equatable {
    public let id: SharedFolderID
    public let name: String
    public let photoCount: Int
}

public struct PhotoEntry: Sendable, Equatable {
    public let id: String
    public let name: String
}

/// The set of folders a paired phone may see, and the only place a client
/// identifier becomes a filesystem path.
///
/// IDs are random and issued at share time. The client never sends a path, so
/// traversal is not filtered — it is unrepresentable. An ID that was never
/// issued resolves to nil no matter what it looks like, and unsharing drops
/// every ID it issued.
public actor SharedFolders {
    private struct Entry {
        let url: URL
        let folderID: SharedFolderID
    }

    private var folderOrder: [SharedFolderID] = []
    private var folderRoots: [SharedFolderID: URL] = [:]
    private var folderPhotoIDs: [SharedFolderID: [String]] = [:]
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Share `folder`, exposing exactly `photos`. Re-sharing a folder that is
    /// already shared replaces its photo list and retires the old IDs, which
    /// is what the file watcher wants after a rescan.
    @discardableResult
    public func share(folder: URL, photos: [URL]) -> SharedFolderID {
        let existing = folderRoots.first(where: { $0.value == folder })?.key
        let folderID = existing ?? UUID().uuidString
        if existing != nil { retirePhotoIDs(of: folderID) } else { folderOrder.append(folderID) }

        folderRoots[folderID] = folder
        var ids: [String] = []
        ids.reserveCapacity(photos.count)
        for url in photos {
            let id = UUID().uuidString
            entries[id] = Entry(url: url, folderID: folderID)
            ids.append(id)
        }
        folderPhotoIDs[folderID] = ids
        return folderID
    }

    public func unshare(_ folderID: SharedFolderID) {
        retirePhotoIDs(of: folderID)
        folderPhotoIDs.removeValue(forKey: folderID)
        folderRoots.removeValue(forKey: folderID)
        folderOrder.removeAll { $0 == folderID }
    }

    public func unshareAll() {
        entries.removeAll()
        folderPhotoIDs.removeAll()
        folderRoots.removeAll()
        folderOrder.removeAll()
    }

    public func folders() -> [SharedFolderSummary] {
        folderOrder.compactMap { id in
            guard let root = folderRoots[id] else { return nil }
            return SharedFolderSummary(
                id: id,
                name: root.lastPathComponent,
                photoCount: folderPhotoIDs[id]?.count ?? 0
            )
        }
    }

    public func photos(in folderID: SharedFolderID) -> [PhotoEntry] {
        (folderPhotoIDs[folderID] ?? []).compactMap { id in
            guard let entry = entries[id] else { return nil }
            return PhotoEntry(id: id, name: entry.url.lastPathComponent)
        }
    }

    public func photoURL(forID id: String) -> URL? {
        entries[id]?.url
    }

    public func photoID(for url: URL) -> String? {
        entries.first(where: { $0.value.url == url })?.key
    }

    private func retirePhotoIDs(of folderID: SharedFolderID) {
        for id in folderPhotoIDs[folderID] ?? [] {
            entries.removeValue(forKey: id)
        }
    }
}
```

- [ ] **Step 5: Run to verify they pass**

```bash
swift build && swift run pv-pipeline
```

Expected: the five new `AddressGate:` / `SharedFolders:` checks print `PASS`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhotoServe Sources/PipelineCLI
git commit -m "feat: LAN-only address gate and opaque photo IDs

Clients never send paths. IDs are random, issued at share time, and retired
on unshare, so traversal is unrepresentable rather than filtered. The address
gate is the second lock behind the listener binding.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `PairingManager` — one-time codes and device tokens

**Files:**
- Create: `Sources/PhotoServe/PairingManager.swift`
- Modify: `Sources/PipelineCLI/ServeVerifications.swift`
- Modify: `Sources/PipelineCLI/CLI.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces: `actor PairingManager` with `issueCode(now:) -> String`, `clearCode()`, `validate(code:now:) throws`, `registerDevice(name:) -> String`, `isValidToken(_:) -> Bool`, `devices() -> [PairedDevice]`, `revoke(deviceID:)`, `revokeAll()`; `PairingError`; `PairedDevice`. Tasks 5 and 6 consume these.

- [ ] **Step 1: Write the failing verifications**

Append to `Sources/PipelineCLI/ServeVerifications.swift`:

```swift
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

    try require(await mgr.isValidToken(token), "freshly issued token must validate")
    try require(!(await mgr.isValidToken(token + "x")), "a longer token must not validate")
    try require(!(await mgr.isValidToken("")), "empty token must not validate")
    try require(!(await mgr.isValidToken(String(repeating: "a", count: token.count))),
                "a same-length wrong token must not validate")

    let devices = await mgr.devices()
    try require(devices.count == 1, "expected 1 device, got \(devices.count)")
    try require(devices[0].name == "iPhone", "device name lost")

    await mgr.revoke(deviceID: devices[0].id)
    try require(!(await mgr.isValidToken(token)), "revoked token must stop validating")
    try require(await mgr.devices().isEmpty, "device list should be empty after revoke")
}

func pairingStoresTokenHashNotToken() async throws {
    let mgr = PairingManager()
    let token = await mgr.registerDevice(name: "iPad")
    let devices = await mgr.devices()
    try require(devices[0].tokenHash != token, "the raw token must not be retained")
    try require(devices[0].tokenHash.count == 64, "expected a SHA-256 hex digest, got \(devices[0].tokenHash.count) chars")
}
```

Register in `Sources/PipelineCLI/CLI.swift` after the `SharedFolders:` lines:

```swift
        failures += await runVerification("PairingManager: a pairing code works exactly once", check: pairingCodeIsSingleUse)
        failures += await runVerification("PairingManager: a pairing code expires after 60s", check: pairingCodeExpires)
        failures += await runVerification("PairingManager: wrong codes are refused, then rate limited", check: pairingRejectsWrongCodeAndRateLimits)
        failures += await runVerification("PairingManager: codes are 128-bit and non-repeating", check: pairingCodeHasEnoughEntropy)
        failures += await runVerification("PairingManager: device tokens validate and revoke", check: pairingTokensValidateAndRevoke)
        failures += await runVerification("PairingManager: stores a token hash, never the token", check: pairingStoresTokenHashNotToken)
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift build
```

Expected: FAIL with "cannot find 'PairingManager' in scope".

- [ ] **Step 3: Implement `PairingManager.swift`**

Create `Sources/PhotoServe/PairingManager.swift`:

```swift
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
```

- [ ] **Step 4: Run to verify they pass**

```bash
swift build && swift run pv-pipeline
```

Expected: the six new `PairingManager:` checks print `PASS`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PhotoServe/PairingManager.swift Sources/PipelineCLI
git commit -m "feat: one-time pairing codes and revocable device tokens

The QR carries a 60-second single-use code, not a token, so a screenshot
taken after pairing is worthless and a sniffed redemption cannot be replayed.
Tokens are stored as SHA-256 digests and compared in constant time.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `LocalServer` and `Router`

**Files:**
- Create: `Sources/PhotoServe/LocalServer.swift`
- Create: `Sources/PhotoServe/Router.swift`
- Modify: `Sources/PipelineCLI/ServeVerifications.swift`
- Modify: `Sources/PipelineCLI/CLI.swift`

**Interfaces:**
- Consumes: `HTTPRequest`, `HTTPResponse` (Task 2), `AddressGate` (Task 3), `PairingManager` (Task 4)
- Produces: `protocol ServeDelegate` (implemented by Task 6's controller), `actor Router` with `handle(_:from:) async -> HTTPResponse`, `actor LocalServer` with `start(router:) async throws -> UInt16`, `stop() async`, `LocalServer.lanAddress() -> String?`

- [ ] **Step 1: Write the failing verifications**

Append to `Sources/PipelineCLI/ServeVerifications.swift`:

```swift
// MARK: - Router verifications

/// Minimal delegate that records what the router asked for.
actor StubServeDelegate: ServeDelegate {
    var actionsApplied: [(String, PhoneAction)] = []
    var approvalAnswer = true

    func setApprovalAnswer(_ v: Bool) { approvalAnswer = v }

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
    func search(folderID: String, query: String) async -> [String]? { nil }
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
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    let code = await pairing.issueCode(now: now)

    await delegate.setApprovalAnswer(false)
    let body = #"{"code":"\#(code)","deviceName":"iPhone"}"#
    let denied = HTTPRequest(parsing: Data("POST /api/pair HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(denied, from: "192.168.1.9")
    try require(res.status == 403, "a declined pairing must not issue a token, got \(res.status)")
    try require(await pairing.devices().isEmpty, "no device may be registered when approval is declined")
}

func routerPairingIssuesTokenWhenApproved() async throws {
    let now = Date(timeIntervalSince1970: 1_770_000_000)
    let pairing = PairingManager()
    let router = Router(pairing: pairing, delegate: StubServeDelegate())
    let code = await pairing.issueCode(now: now)

    let body = #"{"code":"\#(code)","deviceName":"iPhone"}"#
    let req = HTTPRequest(parsing: Data("POST /api/pair HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 200, "expected 200, got \(res.status)")

    let json = try JSONSerialization.jsonObject(with: res.body) as? [String: Any]
    let token = json?["token"] as? String
    try require(token != nil, "response carried no token")
    try require(await pairing.isValidToken(token!), "issued token does not validate")
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

func routerRejectsUnknownActionNames() async throws {
    let pairing = PairingManager()
    let delegate = StubServeDelegate()
    let router = Router(pairing: pairing, delegate: delegate)
    let token = await pairing.registerDevice(name: "iPhone")

    let body = #"{"photoID":"P1","action":"rm -rf"}"#
    let req = HTTPRequest(parsing: Data("POST /api/action HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))!
    let res = await router.handle(req, from: "192.168.1.9")
    try require(res.status == 400, "unknown action must be rejected, got \(res.status)")
    try require(await delegate.recorded().isEmpty, "nothing should have been applied")
}
```

Register in `Sources/PipelineCLI/CLI.swift` after the `PairingManager:` lines:

```swift
        failures += await runVerification("Router: refuses API requests with no token", check: routerRefusesUnauthenticatedAPIRequests)
        failures += await runVerification("Router: refuses a valid token from a public address", check: routerRefusesNonPrivateHosts)
        failures += await runVerification("Router: serves the folder list with a valid token", check: routerServesAPIWithValidToken)
        failures += await runVerification("Router: a declined pairing issues no token", check: routerPairingRequiresApproval)
        failures += await runVerification("Router: an approved pairing issues a working token", check: routerPairingIssuesTokenWhenApproved)
        failures += await runVerification("Router: swipe actions map onto VimActions", check: routerMapsSwipeActionsToVimActions)
        failures += await runVerification("Router: unknown action names are rejected", check: routerRejectsUnknownActionNames)
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift build
```

Expected: FAIL with "cannot find 'Router' in scope" and "cannot find type 'ServeDelegate' in scope".

- [ ] **Step 3: Implement `Router.swift`**

Create `Sources/PhotoServe/Router.swift`:

```swift
import Foundation

/// What the phone can ask for. Deliberately a closed enum rather than a
/// free-form string: the wire format is attacker-controlled, and the set of
/// things a phone may do is small and known.
public enum PhoneAction: String, Sendable, Equatable, CaseIterable {
    case pick
    case reject
    case next
    case prev
    case label0, label1, label2, label3, label4
    case label5, label6, label7, label8, label9
}

public struct PhonePhoto: Sendable, Equatable {
    public let id: String
    public let name: String
    public let isPicked: Bool
    public let isRejected: Bool
    public let colorLabel: Int

    public init(id: String, name: String, isPicked: Bool, isRejected: Bool, colorLabel: Int) {
        self.id = id
        self.name = name
        self.isPicked = isPicked
        self.isRejected = isRejected
        self.colorLabel = colorLabel
    }
}

/// Everything the router needs from the app. Implemented by
/// `PhoneAccessController`, which owns the `AppState` bridge — this module
/// never sees `AppState` and never touches the filesystem directly.
public protocol ServeDelegate: Actor {
    /// Ask the human at the Mac. Returning false denies the pairing.
    func approvePairing(deviceName: String, fromHost: String) async -> Bool
    func folderList() async -> [SharedFolderSummary]
    func photoList(folderID: String) async -> [PhonePhoto]
    func thumbnailJPEG(photoID: String) async -> Data?
    func previewJPEG(photoID: String) async -> Data?
    func apply(action: PhoneAction, photoID: String) async
    /// Nil when the folder has no CLIP index, which hides the search box.
    func search(folderID: String, query: String) async -> [String]?
}

public actor Router {
    private let pairing: PairingManager
    private let delegate: any ServeDelegate

    public init(pairing: PairingManager, delegate: any ServeDelegate) {
        self.pairing = pairing
        self.delegate = delegate
    }

    public func handle(_ req: HTTPRequest, from host: String) async -> HTTPResponse {
        // Lock one: nothing off the local network gets past here, whatever
        // credential it presents.
        guard AddressGate.isPrivate(host) else { return .status(403) }

        if req.path == "/" || req.path == "/index.html" {
            return .data(Data(PackageResources.client_html), contentType: "text/html; charset=utf-8")
        }
        if req.path == "/api/pair" && req.method == "POST" {
            return await handlePair(req, from: host)
        }

        // Lock two: every remaining route needs a device token.
        guard let token = req.bearerToken, await pairing.isValidToken(token) else {
            return .status(401)
        }

        switch (req.method, pathComponents(req.path)) {
        case ("GET", ["api", "folders"]):
            let folders = await delegate.folderList().map {
                ["id": $0.id, "name": $0.name, "photoCount": $0.photoCount] as [String: Any]
            }
            return .json(["folders": folders])

        case ("GET", ["api", "folder", let folderID]):
            let photos = await delegate.photoList(folderID: folderID).map {
                [
                    "id": $0.id, "name": $0.name,
                    "picked": $0.isPicked, "rejected": $0.isRejected,
                    "label": $0.colorLabel,
                ] as [String: Any]
            }
            return .json(["photos": photos])

        case ("GET", ["api", "thumb", let photoID]):
            guard let data = await delegate.thumbnailJPEG(photoID: photoID) else { return .status(404) }
            return .data(data, contentType: "image/jpeg")

        case ("GET", ["api", "preview", let photoID]):
            guard let data = await delegate.previewJPEG(photoID: photoID) else { return .status(404) }
            return .data(data, contentType: "image/jpeg")

        case ("POST", ["api", "action"]):
            guard
                let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                let photoID = json["photoID"] as? String,
                let raw = json["action"] as? String
            else { return .status(400) }
            guard let action = PhoneAction(rawValue: raw) else { return .status(400) }
            await delegate.apply(action: action, photoID: photoID)
            return .json(["ok": true])

        case ("GET", ["api", "search", let folderID]):
            guard let q = req.query["q"], !q.isEmpty else { return .status(400) }
            guard let ids = await delegate.search(folderID: folderID, query: q) else { return .status(404) }
            return .json(["photoIDs": ids])

        default:
            return .status(404)
        }
    }

    private func handlePair(_ req: HTTPRequest, from host: String) async -> HTTPResponse {
        guard
            let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
            let code = json["code"] as? String
        else { return .status(400) }
        let deviceName = (json["deviceName"] as? String).map { String($0.prefix(40)) } ?? "Phone"

        do {
            try await pairing.validate(code: code)
        } catch PairingError.rateLimited {
            return .status(429)
        } catch {
            return .status(401)
        }

        // The code was right. The human still has to say yes.
        guard await delegate.approvePairing(deviceName: deviceName, fromHost: host) else {
            return .status(403)
        }
        let token = await pairing.registerDevice(name: deviceName)
        return .json(["token": token])
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}
```

- [ ] **Step 4: Implement `LocalServer.swift`**

Create `Sources/PhotoServe/LocalServer.swift`:

```swift
import Foundation
import Network

/// The listener. Exists only while phone access is switched on.
///
/// Network.framework rather than swift-nio: the package has no external
/// dependencies and this feature is not the reason to acquire one. The port
/// is ephemeral because it is carried in the QR anyway, which sidesteps
/// collisions with whatever else the machine is running.
public actor LocalServer {
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var router: Router?

    public init() {}

    public var isRunning: Bool { listener != nil }

    /// Start listening on an ephemeral port. Returns the port actually bound,
    /// for display in the QR.
    public func start(router: Router) async throws -> UInt16 {
        stopInternal()
        self.router = router

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // No point accepting a connection that arrives over a cellular or
        // VPN path — this is a LAN feature.
        params.prohibitedInterfaceTypes = [.cellular]

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    public func stop() {
        stopInternal()
    }

    private func stopInternal() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
        router = nil
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .global(qos: .userInitiated))
        Task { await self.readRequest(on: connection, buffer: Data()) }
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            Task {
                var buffer = buffer
                if let chunk { buffer.append(chunk) }

                if buffer.count > HTTPRequest.maxRequestBytes {
                    await self.send(.status(413), on: connection)
                    return
                }
                if error != nil || (isComplete && buffer.isEmpty) {
                    await self.close(connection)
                    return
                }
                guard HTTPRequest.expectedLength(of: buffer) != nil else {
                    // Header block or body still incomplete — keep reading.
                    await self.readRequest(on: connection, buffer: buffer)
                    return
                }
                guard let request = HTTPRequest(parsing: buffer) else {
                    await self.send(.status(400), on: connection)
                    return
                }
                let host = Self.remoteHost(of: connection)
                guard let router = await self.router else {
                    await self.send(.status(404), on: connection)
                    return
                }
                let response = await router.handle(request, from: host)
                await self.send(response, on: connection)
            }
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(connection) }
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Peer address as a bare string, for `AddressGate`.
    nonisolated static func remoteHost(of connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            @unknown default:  return ""
            }
        default:
            return ""
        }
    }

    /// This Mac's LAN IPv4 address, for building the QR URL. Returns nil when
    /// the machine has no private-network interface up.
    public nonisolated static func lanAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            guard AddressGate.isPrivate(text) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // Prefer the primary interface when several are up.
            if name == "en0" { return text }
            if best == nil { best = text }
        }
        return best
    }
}
```

- [ ] **Step 5: Run to verify they pass**

```bash
swift build && swift run pv-pipeline
```

Expected: the seven new `Router:` checks print `PASS`. `LocalServer` has no verification of its own — it is Network.framework lifecycle glue with no branching logic worth pinning, and the routing decisions it delegates to are all covered above. It gets exercised for real in Task 6.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhotoServe Sources/PipelineCLI
git commit -m "feat: NWListener-backed local server and route table

Two locks on every route: the peer must be on a private network, and every
route except pairing needs a device token. Pairing additionally waits on the
human at the Mac. Actions arrive as a closed enum, never a free-form string.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: `PhoneAccessController`, pairing sheet and QR

Wires `PhotoServe` to `AppState`. This is where the phone becomes a second input device.

**Files:**
- Create: `Sources/PhotoViewerApp/PhoneAccess/PhoneAccessController.swift`
- Create: `Sources/PhotoViewerApp/PhoneAccess/PairingSheet.swift`
- Create: `Sources/PhotoViewerApp/PhoneAccess/QRRenderer.swift`
- Modify: `Sources/PhotoViewerApp/AppState.swift`
- Modify: `Sources/PhotoViewerApp/ContentView.swift` (toolbar button + sheet presentation)

**Interfaces:**
- Consumes: everything from Tasks 1-5
- Produces: `PhoneAccessController` (an `actor` conforming to `ServeDelegate`), `AppState.phoneAccess: PhoneAccessController`, `QRRenderer.image(for:size:) -> NSImage?`

- [ ] **Step 1: Implement `QRRenderer`**

Create `Sources/PhotoViewerApp/PhoneAccess/QRRenderer.swift`:

```swift
import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR generation via CoreImage. No dependency needed — `CIQRCodeGenerator`
/// has shipped since macOS 10.9.
enum QRRenderer {
    static func image(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the code is read off a bright screen at close
        // range, so the extra redundancy of H buys nothing but density.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
```

- [ ] **Step 2: Implement `PhoneAccessController`**

Create `Sources/PhotoViewerApp/PhoneAccess/PhoneAccessController.swift`:

```swift
import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PhotoServe
import PhotoViewerCore

/// Bridges the local server to `AppState`.
///
/// Everything the phone does arrives here and leaves as a `VimAction` handed
/// to `AppState.dispatch` — the same call the keyboard makes. That is what
/// makes the phone a second input device rather than a second writer.
actor PhoneAccessController: ServeDelegate {
    private let server = LocalServer()
    private let pairing = PairingManager()
    private let shared = SharedFolders()

    private weak var state: AppState?
    private var pendingApproval: CheckedContinuation<Bool, Never>?

    /// Set by the pairing sheet so it can show the QR and the approval prompt.
    @MainActor final class UIBridge: ObservableObject {
        @Published var isEnabled = false
        @Published var pairingURL: String?
        @Published var pendingDevice: (name: String, host: String)?
        @Published var devices: [PairedDevice] = []
        @Published var lastError: String?
    }

    @MainActor let ui = UIBridge()

    init(state: AppState) {
        self.state = state
    }

    // MARK: - Lifecycle

    /// Start listening and mint a pairing code. Returns the URL to encode in
    /// the QR, or throws if no LAN interface is up.
    func enable() async throws -> String {
        let port = try await server.start(router: Router(pairing: pairing, delegate: self))
        guard let host = LocalServer.lanAddress() else {
            await server.stop()
            throw PhoneAccessError.noLANInterface
        }
        let code = await pairing.issueCode()
        await syncSharedFolder()
        let url = "http://\(host):\(port)/?c=\(code)"
        await MainActor.run { [ui] in
            ui.isEnabled = true
            ui.pairingURL = url
        }
        return url
    }

    func disable() async {
        await server.stop()
        await pairing.revokeAll()
        await shared.unshareAll()
        await MainActor.run { [ui] in
            ui.isEnabled = false
            ui.pairingURL = nil
            ui.devices = []
        }
    }

    /// Expose the folder currently open on the Mac, and only that folder.
    /// Called on enable and whenever the folder or its contents change.
    func syncSharedFolder() async {
        guard let state else { return }
        let (folder, urls) = await MainActor.run { (state.folder, state.imageURLs) }
        guard let folder else {
            await shared.unshareAll()
            return
        }
        await shared.share(folder: folder, photos: urls)
    }

    // MARK: - ServeDelegate

    func approvePairing(deviceName: String, fromHost: String) async -> Bool {
        await MainActor.run { [ui] in
            ui.pendingDevice = (name: deviceName, host: fromHost)
        }
        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            pendingApproval = c
        }
        await MainActor.run { [ui] in ui.pendingDevice = nil }
        if approved {
            let list = await pairing.devices()
            await MainActor.run { [ui] in ui.devices = list }
        }
        return approved
    }

    /// Called by the sheet's Allow / Deny buttons.
    func resolveApproval(_ approved: Bool) {
        pendingApproval?.resume(returning: approved)
        pendingApproval = nil
    }

    func folderList() async -> [SharedFolderSummary] {
        await shared.folders()
    }

    func photoList(folderID: String) async -> [PhonePhoto] {
        guard let state else { return [] }
        let entries = await shared.photos(in: folderID)
        return await MainActor.run {
            entries.compactMap { entry in
                // photoURL is resolved on the actor, so re-derive by name-free
                // lookup below; see resolve(_:) for the actual mapping.
                nil as PhonePhoto?
            }
        } ?? []
    }

    func thumbnailJPEG(photoID: String) async -> Data? {
        guard let url = await shared.photoURL(forID: photoID) else { return nil }
        guard let cg = await MainActor.run(body: { ThumbnailLoader.shared }).thumbnail(for: url) else { return nil }
        return Self.jpegData(from: cg, quality: 0.7)
    }

    func previewJPEG(photoID: String) async -> Data? {
        guard let url = await shared.photoURL(forID: photoID) else { return nil }
        return Self.downscaledJPEG(url: url, maxDimension: 2048, quality: 0.82)
    }

    func apply(action: PhoneAction, photoID: String) async {
        guard let state, let url = await shared.photoURL(forID: photoID) else { return }
        await MainActor.run {
            // Select the photo the phone is looking at, then dispatch. Mutating
            // actions in VimKeymap operate on the current selection, so the
            // selection move is part of applying the action, not a side effect.
            state.select(url: url)
            let vimAction = Self.vimAction(for: action, url: url, keymap: state.vimKeymap)
            state.dispatch(vimAction)
        }
    }

    func search(folderID: String, query: String) async -> [String]? {
        nil   // Task 9 implements this.
    }

    // MARK: - Action mapping

    /// Translate a phone gesture into the same `VimAction` the keyboard makes.
    /// `VimKeymap` mutates its own state for the label/pick/reject cases, so
    /// those mutations happen here before dispatch, exactly as
    /// `VimKeymap.handle` does for a keystroke.
    @MainActor
    static func vimAction(for action: PhoneAction, url: URL, keymap: VimKeymap) -> VimAction {
        switch action {
        case .next: return .next
        case .prev: return .prev
        case .pick:
            if keymap.picks.contains(url) { keymap.picks.remove(url) } else { keymap.picks.insert(url) }
            return .togglePick
        case .reject:
            if keymap.rejects.contains(url) { keymap.rejects.remove(url) } else { keymap.rejects.insert(url) }
            return .toggleReject
        case .label0, .label1, .label2, .label3, .label4,
             .label5, .label6, .label7, .label8, .label9:
            let digit = Int(action.rawValue.dropFirst("label".count)) ?? 0
            if digit == 0 { keymap.colorLabels.removeValue(forKey: url) }
            else { keymap.colorLabels[url] = digit }
            return .setColorLabel(digit)
        }
    }

    // MARK: - Image encoding

    static func jpegData(from cg: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decode straight to the target size via ImageIO's thumbnail path — the
    /// same trick `ThumbnailLoader` uses. A 50 MP original is never fully
    /// decoded, let alone sent.
    static func downscaledJPEG(url: URL, maxDimension: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return jpegData(from: cg, quality: quality)
    }
}

enum PhoneAccessError: LocalizedError {
    case noLANInterface

    var errorDescription: String? {
        switch self {
        case .noLANInterface:
            return "No local network connection. Join a wifi or ethernet network and try again."
        }
    }
}
```

**Note for the implementer:** `photoList(folderID:)` above is deliberately left as a stub that returns an empty array via an unusable expression — it will not compile as written. Replace it with a working implementation that, for each `PhotoEntry` from `shared.photos(in:)`, resolves its URL via `shared.photoURL(forID:)` and reads `isPicked` / `isRejected` / `colorLabel` from `state.vimKeymap` on the main actor. Build it as: gather `[(id, name, url)]` on the actor first, then one `MainActor.run` that maps them all to `PhonePhoto`. One hop, not one per photo.

- [ ] **Step 3: Add the controller to `AppState`**

In `Sources/PhotoViewerApp/AppState.swift`, after the `vimKeymap` property added in Task 1:

```swift
    /// Phone companion. Nil until first use — the listener does not exist
    /// until the user turns it on.
    lazy var phoneAccess = PhoneAccessController(state: self)
```

Then, so the phone's photo list tracks the Mac, call `syncSharedFolder()` after each commit of `imageURLs`. There are three commit sites: `loadFolder`'s main-actor commit (line ~325-331), the file watcher's rescan commit (line ~509-517), and `optimisticallyRemoveImages` (line ~546). Add to each:

```swift
        Task { await self.phoneAccess.syncSharedFolder() }
```

- [ ] **Step 4: Implement the pairing sheet**

Create `Sources/PhotoViewerApp/PhoneAccess/PairingSheet.swift`. It shows, in order:

1. When `ui.isEnabled == false`: an explanation and a "Turn on phone access" button that calls `enable()` and shows `ui.lastError` on throw.
2. When `ui.pairingURL != nil`: the QR from `QRRenderer.image(for:size: 240)`, the URL as selectable text underneath, and the sentence "Scan with your phone's camera. Anyone who scans still needs your approval."
3. When `ui.pendingDevice != nil`: the approval prompt — "\(name) at \(host) wants access" with Allow and Deny buttons calling `resolveApproval(true/false)`.
4. A list of `ui.devices` with a Revoke button each, and a "Turn off" button calling `disable()`.

Present it from a toolbar button in `ContentView.swift` using `.sheet(isPresented:)`. On dismiss, call `pairing.clearCode()` through the controller so the displayed code stops working the moment the sheet closes.

- [ ] **Step 5: Build and verify manually**

```bash
swift build && swift run pv-pipeline
```

Expected: all checks pass. Then:

```bash
swift run Latent
```

Open a folder, open the pairing sheet, and confirm: a QR appears; scanning it on a phone on the same wifi loads the placeholder page and triggers the approval prompt on the Mac; declining returns an error on the phone and registers no device; approving lists the device. Then confirm `curl` from a public-facing address is refused — the address gate is already covered by verification, so this is a smoke test, not the proof.

This task's real proof is manual because it is UI and OS-networking integration. Say so plainly in the commit rather than implying test coverage that does not exist.

- [ ] **Step 6: Commit**

```bash
git add Sources/PhotoViewerApp
git commit -m "feat: phone access controller, pairing sheet and QR

Bridges PhotoServe to AppState: every phone gesture becomes a VimAction and
goes through AppState.dispatch, the same call the keyboard makes. Pairing
waits on an explicit Allow at the Mac.

Verified manually — this layer is SwiftUI plus Network.framework integration.
The routing, pairing and ID logic underneath it are covered by pv-pipeline.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: The phone client — grid, full screen, swipe

**Files:**
- Modify: `Sources/PhotoServe/Resources/client.html` (replaces the Task 2 placeholder)

**Interfaces:**
- Consumes: every route from Task 5's `Router`
- Produces: nothing consumed by later tasks; Task 8 adds an SSE listener to this file

- [ ] **Step 1: Write the client**

Replace `Sources/PhotoServe/Resources/client.html` entirely. One file, no framework, no build step. Structure:

- `<head>`: `<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">`, `<meta name="apple-mobile-web-app-capable" content="yes">` so add-to-home-screen runs without Safari chrome, and a dark-background theme colour.
- Pairing: on load, read `?c=` from the URL. If present, `POST /api/pair` with `{code, deviceName: navigator.userAgent-derived short name}`, store the returned token in `localStorage`, and strip the query from the URL with `history.replaceState` so the code does not sit in the address bar or history. If a token is already stored, skip straight to the grid.
- Every fetch sends `Authorization: Bearer <token>`. A 401 clears the stored token and shows "Pairing expired. Scan the QR on your Mac again."
- Grid: `GET /api/folders` then `GET /api/folder/{id}`, rendered as a CSS grid of `<img src="/api/thumb/{id}" loading="lazy">`, with a colour dot and pick/reject marker per cell.
- Full screen: tapping a cell opens `GET /api/preview/{id}` in a full-viewport overlay.
- Gestures, with the tuning constants at the top of the script where they can be found:

```javascript
  // Swipe tuning. These are feel, not logic — what reads as a deliberate
  // swipe in a simulator reads as a twitch in a hand, and a thumb on a phone
  // travels differently from a finger on an iPad. Expect to adjust these
  // against a real device rather than reasoning about them.
  const SWIPE_MIN_DISTANCE = 60;    // px before a drag counts as a swipe
  const SWIPE_MAX_DURATION = 600;   // ms; slower than this is a drag, not a swipe
  const SWIPE_AXIS_RATIO   = 1.6;   // how much one axis must beat the other
  const LONG_PRESS_MS      = 450;   // hold before the label picker appears
```

Map, per the spec: up → `pick`, down → `reject`, left → `next`, right → `prev`, long press → colour label picker posting `label0`–`label9`. Each posts to `/api/action` with `{photoID, action}`.

**Diagonal swipes need a decision, and it is a taste call rather than a correctness one.** `SWIPE_AXIS_RATIO` exists so a swipe that is 100px up and 90px left can be treated three ways: ignored as ambiguous, resolved to the dominant axis anyway, or resolved with a bias toward the horizontal (since navigation is recoverable and a stray pick is not). Implement `resolveSwipe(dx, dy, dt)` returning an action name or `null`, and pick the behaviour you want to live with — this is the one place in the feature where the right answer is whichever one feels right in your hand.

- Optimistic UI: apply the pick/reject/label locally on gesture, then reconcile from the server response. A swipe that feels laggy feels broken.

- [ ] **Step 2: Build and test on a real phone**

```bash
swift build && swift run Latent
```

Open a folder, enable phone access, scan, approve. Then confirm on the phone: the grid loads and scrolls; tapping opens full screen; swipe up marks a pick and the Mac's grid shows it; swipe down marks a reject; left and right move through the folder; long press opens the label picker and a chosen colour appears on the Mac.

Confirm the reverse too — press `⇧P` on the Mac and reload the phone; the pick is there. Both directions matter, because the whole point is that there is one writer.

- [ ] **Step 3: Commit**

```bash
git add Sources/PhotoServe/Resources/client.html
git commit -m "feat: phone client with swipe culling

One HTML file, no framework, no build step. Swipe up picks, down rejects,
sideways navigates, long press labels — each posting the action that becomes
the same VimAction the keyboard produces.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Live sync via server-sent events

Without this the phone shows stale pick state whenever the Mac changes something, and two people looking at the same folder disagree.

**Files:**
- Modify: `Sources/PhotoServe/Router.swift` (add the `/api/events` route and a `ServeDelegate` hook)
- Modify: `Sources/PhotoServe/LocalServer.swift` (hold SSE connections open rather than closing after one response)
- Modify: `Sources/PhotoViewerApp/PhoneAccess/PhoneAccessController.swift` (publish changes)
- Modify: `Sources/PhotoServe/Resources/client.html` (consume the stream)
- Modify: `Sources/PipelineCLI/ServeVerifications.swift`, `Sources/PipelineCLI/CLI.swift`

**Interfaces:**
- Consumes: `Router`, `LocalServer`, `HTTPResponse` from Tasks 2 and 5
- Produces: `SSEFrame.encode(event:data:) -> Data`; `LocalServer.broadcast(_ frame: Data)`

- [ ] **Step 1: Write the failing verification**

Append to `Sources/PipelineCLI/ServeVerifications.swift`:

```swift
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
```

Register in `Sources/PipelineCLI/CLI.swift` after the `Router:` lines:

```swift
        failures += await runVerification("SSE: frames carry event and data lines and end blank", check: sseFramesAreWellFormed)
        failures += await runVerification("SSE: multi-line payloads split across data lines", check: sseFramesEscapeNewlinesInData)
```

- [ ] **Step 2: Run to verify they fail**

```bash
swift build
```

Expected: FAIL with "cannot find 'SSEFrame' in scope".

- [ ] **Step 3: Implement `SSEFrame` and the route**

Add to `Sources/PhotoServe/Router.swift`:

```swift
/// Server-sent events. One-way, which is all the phone needs, and plain HTTP
/// — no handshake, no framing protocol, no upgrade dance. A WebSocket here
/// would be roughly ten times the code for a channel that only ever flows
/// one direction.
public enum SSEFrame {
    public static func encode(event: String, data: String) -> Data {
        var out = "event: \(event)\n"
        for line in data.split(separator: "\n", omittingEmptySubsequences: false) {
            out += "data: \(line)\n"
        }
        out += "\n"
        return Data(out.utf8)
    }
}
```

In `Router.handle`, add before the `default:` case:

```swift
        case ("GET", ["api", "events"]):
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-store",
                    "Connection": "keep-alive",
                ],
                body: SSEFrame.encode(event: "hello", data: "{}")
            )
```

- [ ] **Step 4: Keep SSE connections open in `LocalServer`**

`send(_:on:)` currently closes after every response. Add a check: when the response's `Content-Type` is `text/event-stream`, send the headers and initial frame but do **not** cancel — retain the connection in a `sseConnections` set instead. Add:

```swift
    private var sseConnections: [ObjectIdentifier: NWConnection] = [:]

    /// Push a frame to every live event stream. Connections that error out
    /// are dropped; the browser's EventSource reconnects on its own.
    public func broadcast(_ frame: Data) {
        for (key, connection) in sseConnections {
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                Task { await self?.dropSSE(key) }
            })
        }
    }

    private func dropSSE(_ key: ObjectIdentifier) {
        sseConnections[key]?.cancel()
        sseConnections.removeValue(forKey: key)
    }
```

Ensure `stopInternal()` cancels and clears `sseConnections` too — a stream left open after the toggle goes off would keep serving state.

- [ ] **Step 5: Publish changes from the controller**

In `PhoneAccessController`, after every `apply(action:photoID:)` and inside `syncSharedFolder()`, broadcast the changed photo:

```swift
        await server.broadcast(SSEFrame.encode(event: "photo", data: json))
```

where `json` carries `{id, picked, rejected, label}` for the affected photo, or `{"reload":true}` when the folder itself changed.

- [ ] **Step 6: Consume the stream in the client**

In `client.html`, `EventSource` cannot send an `Authorization` header, so open it with the token in the query string: `new EventSource('/api/events?t=' + token)`. Update the `Router`'s events case to accept the token from `req.query["t"]` as well as the bearer header. On a `photo` event, patch that cell's state in place; on `reload`, refetch the photo list.

- [ ] **Step 7: Run to verify they pass**

```bash
swift build && swift run pv-pipeline
```

Expected: the two new `SSE:` checks print `PASS`. Then verify live: with the phone showing a folder, press `⇧P` on the Mac and confirm the phone's pick marker appears without a refresh.

- [ ] **Step 8: Commit**

```bash
git add Sources/PhotoServe Sources/PhotoViewerApp Sources/PipelineCLI
git commit -m "feat: live sync over server-sent events

One-way is all the phone needs, so SSE rather than WebSockets. Marking a pick
on either screen now shows on both without a refresh.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 9: Search route, and the README promise

Search is nearly free — the engine exists. The README change is not optional: the headline claim stops being true the moment this feature ships, and it must not ship ahead of the correction.

**Files:**
- Modify: `Sources/PhotoViewerApp/PhoneAccess/PhoneAccessController.swift` (implement `search`)
- Modify: `Sources/PhotoViewerApp/AppState.swift` (add `PhotoSearch` to the app target's dependencies in `Package.swift` if not already present)
- Modify: `Package.swift`
- Modify: `Sources/PhotoServe/Resources/client.html`
- Modify: `README.md`

**Interfaces:**
- Consumes: `SearchEngine`, `EmbeddingIndex` from `PhotoSearch`; `ServeDelegate.search` from Task 5
- Produces: nothing downstream

- [ ] **Step 1: Add `PhotoSearch` to the app target**

`PhotoViewerApp`'s dependencies in `Package.swift` currently omit `PhotoSearch`. Add `"PhotoSearch"` to that array.

- [ ] **Step 2: Implement `search`**

Replace the Task 6 stub in `PhoneAccessController`:

```swift
    func search(folderID: String, query: String) async -> [String]? {
        guard let folder = await shared.folders().first(where: { $0.id == folderID }),
              let root = await folderRoot(for: folderID)
        else { return nil }
        _ = folder

        // No converted OpenCLIP assets, or no index for this folder, means no
        // search — the client hides the box rather than showing one that
        // always returns nothing.
        guard let engine = try? SearchEngine(folderURL: root), await engine.hasIndex() else {
            return nil
        }
        guard let hits = try? await engine.search(text: query, limit: 200) else { return nil }

        var ids: [String] = []
        for hit in hits {
            if let id = await shared.photoID(for: hit.url) { ids.append(id) }
        }
        return ids
    }
```

**Note for the implementer:** check `Sources/PhotoSearch/SearchEngine.swift` for the real initializer and method names before writing this — the shape above is the intent, not a transcription. Add a `folderRoot(for:)` helper to `SharedFolders` returning the shared folder's URL if one is not already exposed. If `SearchEngine` has no `hasIndex()`, use `EmbeddingIndex.indexFileURL(for:)` plus a `FileManager.fileExists` check, matching how `EmbeddingIndex` is probed elsewhere.

- [ ] **Step 3: Add the search box to the client**

On folder load, `GET /api/search/{folderID}?q=test`. A 404 hides the box permanently for that folder; a 200 shows it. On submit, filter the grid to the returned IDs, in returned order, with a "Clear" affordance.

- [ ] **Step 4: Correct the README**

In `README.md`, line 49-50, replace:

```markdown
- 🚫 **Zero runtime network calls.** The only thing that touches the network is a setup script you
  run yourself, once, to fetch model weights.
```

with:

```markdown
- 🚫 **Zero runtime network calls by default.** Nothing touches the network unless you ask it to:
  a setup script you run yourself, once, to fetch model weights — and the optional phone companion
  below, which you switch on per session and which never leaves your LAN.
```

Add a section after "What it does":

```markdown
## Phone companion (optional, off by default)

Browse and cull a folder from your phone, over your own network. Turn it on, scan the QR code on
your Mac, and the phone becomes a second input device — swipe up to pick, down to reject, sideways
to move, long press to set a colour label. Everything you do lands in the same per-folder state the
keyboard writes, so `⌘Z` still works and the two screens never disagree.

- **Off unless you turn it on.** No listener exists until you do, and it stops when you quit Latent.
- **Your LAN only.** Connections from outside a private address range are refused. There is no
  cloud relay and no account, and there is no plan to add one.
- **One-time pairing.** The QR carries a code that works once and expires in a minute, and the Mac
  asks you to approve the device before it gets a token. Revoke any device at any time.
- **Only the folder you share.** The phone sees the folder you have open, not everything Latent has
  ever opened.
- **Unencrypted on your local network.** There is no TLS: a self-signed certificate on a LAN makes
  the browser show a security warning on every launch, and training yourself to click through that
  warning is worse than the plaintext it would hide. Turn the feature off on networks you do not
  trust.
```

- [ ] **Step 5: Verify**

```bash
swift build && swift run pv-pipeline
```

Expected: all checks pass. With OpenCLIP assets converted and a folder indexed, confirm the search box appears on the phone and returns sensible hits. With `Resources/Models/` empty, confirm the box does not appear at all.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources README.md
git commit -m "feat: phone search, and correct the zero-network claim

Search delegates to the existing CLIP engine and hides itself when a folder
has no index. The README's headline promise becomes 'by default' in the same
commit that makes it so, including the reasoning for shipping without TLS.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Self-review notes

**Spec coverage.** Every section of the spec maps to a task: module layout and the refactor (Tasks 1-2), single-writer (Task 1, 6), routes (Tasks 5, 8, 9), off-by-default and the LAN gate (Tasks 3, 5, 6), one-time pairing with approval (Tasks 4, 5, 6), device tokens and revocation (Tasks 4, 6), opaque IDs and folder scoping (Tasks 3, 6), downscaled previews (Task 6), swipe gestures and the calibration knob (Task 7), SSE (Task 8), search (Task 9), README (Task 9), testing (every task).

**Known gaps, stated rather than hidden.** `AppState.dispatch` has no automated test because `PhotoViewerApp` is an executable target that `PipelineCLI` cannot import; the reasoning is in Task 1 Step 5. `LocalServer` and the SwiftUI layer are verified manually; Task 6 Step 5 says so and the commit message repeats it. Two implementation points are deliberately left to the implementer with the reason given rather than a fabricated API: `photoList` in Task 6 Step 2, and `SearchEngine`'s real signatures in Task 9 Step 2.

**The one open taste decision** is diagonal swipe resolution in Task 7 Step 1. It is called out in place rather than defaulted, because it is the one choice in this feature that can only be settled with a phone in your hand.
