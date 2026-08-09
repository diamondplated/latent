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

        // Every API route is `/api/<name>` or `/api/<name>/<argument>`.
        // Splitting it out here keeps the arity part of the match, so
        // `/api/folders/anything` stays a 404 rather than aliasing a route.
        let parts = pathComponents(req.path)
        guard parts.count == 2 || parts.count == 3, parts[0] == "api" else { return .status(404) }
        let route = parts[1]
        let argument: String? = parts.count == 3 ? parts[2] : nil

        switch (req.method, route, argument) {
        case ("GET", "folders", nil):
            let folders = await delegate.folderList().map {
                ["id": $0.id, "name": $0.name, "photoCount": $0.photoCount] as [String: Any]
            }
            return .json(["folders": folders])

        case ("GET", "folder", .some(let folderID)):
            let photos = await delegate.photoList(folderID: folderID).map {
                [
                    "id": $0.id, "name": $0.name,
                    "picked": $0.isPicked, "rejected": $0.isRejected,
                    "label": $0.colorLabel,
                ] as [String: Any]
            }
            return .json(["photos": photos])

        case ("GET", "thumb", .some(let photoID)):
            guard let data = await delegate.thumbnailJPEG(photoID: photoID) else { return .status(404) }
            return .data(data, contentType: "image/jpeg")

        case ("GET", "preview", .some(let photoID)):
            guard let data = await delegate.previewJPEG(photoID: photoID) else { return .status(404) }
            return .data(data, contentType: "image/jpeg")

        case ("POST", "action", nil):
            guard
                let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                let photoID = json["photoID"] as? String,
                let raw = json["action"] as? String
            else { return .status(400) }
            guard let action = PhoneAction(rawValue: raw) else { return .status(400) }
            await delegate.apply(action: action, photoID: photoID)
            return .json(["ok": true])

        case ("GET", "search", .some(let folderID)):
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
            // `validate` consumes the code before returning, inside the
            // PairingManager actor. That is what makes the `await` below safe
            // to be reentrant on: a second request that arrives while the
            // human is deciding finds no active code and is refused, so it
            // cannot ride on this request's approval.
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
