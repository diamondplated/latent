import XCTest
import PhotoServe

/// Records what the router asked the app to do.
private actor RecordingDelegate: ServeDelegate {
    private(set) var applied: [(photoID: String, action: PhoneAction)] = []
    private var approve = true

    func setApprove(_ value: Bool) { approve = value }

    func approvePairing(deviceName: String, fromHost: String) async -> Bool { approve }
    func folderList() async -> [SharedFolderSummary] {
        [SharedFolderSummary(id: "F1", name: "2024", photoCount: 1)]
    }
    func photoList(folderID: String) async -> [PhonePhoto] {
        [PhonePhoto(id: "P1", name: "a.jpg", isPicked: false, isRejected: false, colorLabel: 0)]
    }
    func thumbnailJPEG(photoID: String) async -> Data? { photoID == "P1" ? Data([0xFF, 0xD8, 0xFF]) : nil }
    func previewJPEG(photoID: String) async -> Data? { photoID == "P1" ? Data([0xFF, 0xD8, 0xFF, 0xE0]) : nil }
    func apply(action: PhoneAction, photoID: String) async { applied.append((photoID, action)) }
    func search(folderID: String, query: String) async -> [String]? { nil }
}

/// Lock two of the phone companion, plus its vocabulary. Mirrors the Router
/// scenarios in `pv-pipeline` and adds the query-token scope and no-delete
/// checks it does not have.
final class RouterTests: XCTestCase {
    private let lan = "192.168.1.9"

    private func request(
        _ method: String,
        _ target: String,
        token: String? = nil,
        body: String = ""
    ) throws -> HTTPRequest {
        var raw = "\(method) \(target) HTTP/1.1\r\n"
        if let token { raw += "Authorization: Bearer \(token)\r\n" }
        if !body.isEmpty { raw += "Content-Length: \(body.utf8.count)\r\n" }
        raw += "\r\n" + body
        return try XCTUnwrap(HTTPRequest(parsing: Data(raw.utf8)), "fixture failed to parse: \(raw)")
    }

    private func makeRouter() async -> (Router, PairingManager, RecordingDelegate, String) {
        let pairing = PairingManager()
        let delegate = RecordingDelegate()
        let token = await pairing.registerDevice(name: "iPhone")
        return (Router(pairing: pairing, delegate: delegate), pairing, delegate, token)
    }

    func testRefusesEveryRouteFromAPublicAddress() async throws {
        let (router, _, _, token) = await makeRouter()
        for target in ["/", "/index.html", "/api/folders", "/api/pair"] {
            let res = try await router.handle(request("GET", target, token: token), from: "8.8.8.8")
            XCTAssertEqual(res.status, 403, "\(target) from a public address")
        }
    }

    func testRefusesAPIWithoutAValidToken() async throws {
        let (router, _, _, _) = await makeRouter()
        let none = try await router.handle(request("GET", "/api/folders"), from: lan)
        let wrong = try await router.handle(request("GET", "/api/folders", token: "deadbeef"), from: lan)
        XCTAssertEqual(none.status, 401)
        XCTAssertEqual(wrong.status, 401)
    }

    func testRevokedTokenIsRefused() async throws {
        let (router, pairing, _, token) = await makeRouter()
        let device = await pairing.devices()[0]
        await pairing.revoke(deviceID: device.id)
        let res = try await router.handle(request("GET", "/api/folders", token: token), from: lan)
        XCTAssertEqual(res.status, 401)
    }

    func testServesFolderListWithAValidToken() async throws {
        let (router, _, _, token) = await makeRouter()
        let res = try await router.handle(request("GET", "/api/folders", token: token), from: lan)
        XCTAssertEqual(res.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: res.body) as? [String: Any])
        let folders = try XCTUnwrap(json["folders"] as? [[String: Any]])
        XCTAssertEqual(folders.first?["name"] as? String, "2024")
    }

    func testQueryTokenIsAcceptedOnlyForTheEventStream() async throws {
        let (router, _, _, token) = await makeRouter()
        let events = try await router.handle(request("GET", "/api/events?t=\(token)"), from: lan)
        XCTAssertEqual(events.status, 200)
        XCTAssertEqual(events.headers["Content-Type"], SSEFrame.contentType)

        // EventSource can't send headers; nothing else gets that exemption.
        let folders = try await router.handle(request("GET", "/api/folders?t=\(token)"), from: lan)
        XCTAssertEqual(folders.status, 401)
    }

    func testDeclinedPairingIssuesNoToken() async throws {
        let (router, pairing, delegate, _) = await makeRouter()
        await delegate.setApprove(false)
        let code = await pairing.issueCode()
        let body = #"{"code":"\#(code)","deviceName":"Stranger"}"#
        let res = try await router.handle(request("POST", "/api/pair", body: body), from: lan)
        XCTAssertEqual(res.status, 403)
        let names = await pairing.devices().map(\.name)
        XCTAssertFalse(names.contains("Stranger"))
    }

    func testApprovedPairingIssuesAWorkingTokenAndConsumesTheCode() async throws {
        let (router, pairing, _, _) = await makeRouter()
        let code = await pairing.issueCode()
        let body = #"{"code":"\#(code)","deviceName":"iPad"}"#

        let first = try await router.handle(request("POST", "/api/pair", body: body), from: lan)
        XCTAssertEqual(first.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        let token = try XCTUnwrap(json["token"] as? String)
        let valid = await pairing.isValidToken(token)
        XCTAssertTrue(valid)

        let replay = try await router.handle(request("POST", "/api/pair", body: body), from: lan)
        XCTAssertEqual(replay.status, 401, "a redeemed code must not pair a second device")
    }

    func testAppliesKnownActionsAndRejectsUnknownOnes() async throws {
        let (router, _, delegate, token) = await makeRouter()
        let pick = try await router.handle(
            request("POST", "/api/action", token: token, body: #"{"photoID":"P1","action":"pick"}"#), from: lan)
        XCTAssertEqual(pick.status, 200)

        let bogus = try await router.handle(
            request("POST", "/api/action", token: token, body: #"{"photoID":"P1","action":"rm -rf"}"#), from: lan)
        XCTAssertEqual(bogus.status, 400)

        let applied = await delegate.applied
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied.first?.photoID, "P1")
        XCTAssertEqual(applied.first?.action, .pick)
    }

    /// The companion can never delete. Its vocabulary is the closed
    /// `PhoneAction` enum, and no route answers a destructive method.
    func testNothingTheRouterAcceptsCanDelete() async throws {
        let destructive = ["delete", "trash", "remove", "rm", "erase", "move"]
        for action in PhoneAction.allCases {
            XCTAssertFalse(destructive.contains { action.rawValue.lowercased().contains($0) },
                           "PhoneAction.\(action) reads as destructive")
        }

        let (router, _, delegate, token) = await makeRouter()
        for raw in destructive {
            let res = try await router.handle(
                request("POST", "/api/action", token: token, body: #"{"photoID":"P1","action":"\#(raw)"}"#), from: lan)
            XCTAssertEqual(res.status, 400, "action \(raw) must be rejected")
        }
        for (method, target) in [
            ("DELETE", "/api/photo/P1"), ("DELETE", "/api/action"),
            ("POST", "/api/trash/P1"), ("POST", "/api/delete/P1"), ("PUT", "/api/folder/F1"),
        ] {
            let res = try await router.handle(request(method, target, token: token), from: lan)
            XCTAssertEqual(res.status, 404, "\(method) \(target)")
        }
        let applied = await delegate.applied
        XCTAssertTrue(applied.isEmpty, "nothing destructive may reach the app")
    }
}
