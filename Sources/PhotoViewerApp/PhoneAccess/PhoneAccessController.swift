import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PhotoServe
import PhotoViewerCore

/// What the pairing sheet renders. The controller is an actor and SwiftUI is
/// main-actor, so the two need somewhere to meet: the controller pushes into
/// this object, the sheet only reads it.
///
/// `init` is `nonisolated` so the controller — which is not main-actor — can
/// create one. Every stored value here is `Sendable`, so there is nothing for
/// the initializer to race on.
@MainActor
@Observable
final class PhoneAccessUI {
    struct PendingDevice: Equatable, Sendable {
        let name: String
        let host: String
    }

    var isEnabled = false
    var pairingURL: String?
    var pendingDevice: PendingDevice?
    var devices: [PairedDevice] = []
    var lastError: String?

    nonisolated init() {}
}

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

    /// `host:port` of the running listener, or nil when it is not running.
    /// Doubles as "is the server up", which is what `syncSharedFolder` gates
    /// on so a 100k-photo folder load does no ID minting for a feature that
    /// is switched off.
    private var endpoint: String?

    /// The folder currently published to the phone. Only ever one, and only
    /// ever the one open on the Mac.
    private var sharedFolder: URL?

    /// The pairing request currently waiting on a human. `awaitingApproval`
    /// is set before the first suspension point so two concurrent requests
    /// cannot both reach the continuation and orphan one of them.
    ///
    /// `earlyAnswer` covers the window between "prompt shown" and "continuation
    /// installed" — there is a main-actor hop in there, and a resolve landing
    /// inside it finds no continuation to resume. Without it that request parks
    /// forever, `awaitingApproval` never clears (the `defer` never runs), and
    /// every later pairing attempt is refused until the user turns the feature
    /// off. It holds a full answer rather than a cancel flag because the prompt
    /// is on screen for the whole window: an Allow can land there too.
    private var pendingApproval: CheckedContinuation<Bool, Never>?
    private var awaitingApproval = false
    private var earlyAnswer: Bool?

    /// Read by the pairing sheet. Safe to touch from the main actor without
    /// hopping: it is a `let` holding a main-actor-isolated (hence Sendable)
    /// object.
    let ui = PhoneAccessUI()

    init(state: AppState) {
        self.state = state
    }

    // MARK: - Lifecycle

    /// Start listening if it is not already, and mint a fresh pairing code.
    /// Returns the URL to encode in the QR, or throws if no LAN interface is
    /// up. Calling it again while enabled just rotates the code, which is what
    /// re-opening the sheet wants.
    @discardableResult
    func enable() async throws -> String {
        if endpoint == nil {
            let port = try await server.start(router: Router(pairing: pairing, delegate: self))
            guard let host = LocalServer.lanAddress() else {
                await server.stop()
                throw PhoneAccessError.noLANInterface
            }
            endpoint = "\(host):\(port)"
        }
        guard let endpoint else { throw PhoneAccessError.noLANInterface }

        let code = await pairing.issueCode()
        await syncSharedFolder()
        let url = "http://\(endpoint)/?c=\(code)"
        let devices = await pairing.devices()
        await MainActor.run { [ui] in
            ui.isEnabled = true
            ui.pairingURL = url
            ui.devices = devices
            ui.lastError = nil
        }
        return url
    }

    func disable() async {
        // Deny anything mid-flight first: the phone's request is parked on
        // that continuation, and stopping the listener under it would leave
        // the continuation — and the request — hanging forever.
        resolveApproval(false)
        await server.stop()
        await pairing.revokeAll()
        await shared.unshareAll()
        endpoint = nil
        sharedFolder = nil
        await MainActor.run { [ui] in
            ui.isEnabled = false
            ui.pairingURL = nil
            ui.pendingDevice = nil
            ui.devices = []
        }
    }

    /// The pairing sheet closed. The displayed code stops working immediately;
    /// already-paired devices keep theirs. An approval the user walked away
    /// from is a denial, not a hang.
    func closePairingSheet() async {
        resolveApproval(false)
        await pairing.clearCode()
        await MainActor.run { [ui] in
            ui.pairingURL = nil
            ui.pendingDevice = nil
        }
    }

    func revoke(deviceID: UUID) async {
        await pairing.revoke(deviceID: deviceID)
        let devices = await pairing.devices()
        await MainActor.run { [ui] in ui.devices = devices }
    }

    /// Expose the folder currently open on the Mac, and only that folder.
    /// Called on enable and whenever the folder or its contents change.
    func syncSharedFolder() async {
        guard endpoint != nil, let state else { return }
        let (folder, urls) = await MainActor.run { (state.folder, state.imageURLs) }
        // Re-check after the hop: a `disable()` that landed while we were on
        // the main actor has already unshared, and re-populating now would
        // resurrect a folder for a listener that is gone.
        guard endpoint != nil else { return }

        // `SharedFolders.share` *appends* when the folder is not already
        // registered — it replaces a folder's photo list, never the folder
        // set. So the folder the user left has to be dropped explicitly, or
        // it stays listed and every photo ID it issued stays resolvable.
        if sharedFolder != folder {
            await shared.unshareAll()
            sharedFolder = folder
        }
        guard let folder else { return }
        await shared.share(folder: folder, photos: urls)
    }

    // MARK: - ServeDelegate

    func approvePairing(deviceName: String, fromHost: String) async -> Bool {
        // One prompt at a time. Without this, a second request would overwrite
        // `pendingApproval` and the first phone would wait forever.
        guard !awaitingApproval else { return false }
        awaitingApproval = true
        earlyAnswer = nil
        defer { awaitingApproval = false }

        await MainActor.run { [ui] in
            ui.pendingDevice = PhoneAccessUI.PendingDevice(name: deviceName, host: fromHost)
        }
        let approved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            // A resolve that landed during the hop above set the flag instead
            // of finding a continuation. Honour it here rather than parking on
            // one nobody will ever resume.
            if let earlyAnswer {
                c.resume(returning: earlyAnswer)
            } else {
                pendingApproval = c
            }
        }
        pendingApproval = nil
        await MainActor.run { [ui] in ui.pendingDevice = nil }
        if approved {
            let list = await pairing.devices()
            await MainActor.run { [ui] in ui.devices = list }
        }
        return approved
    }

    /// Called by the sheet's Allow / Deny buttons, and by anything that ends
    /// the pairing session. Safe to call with nothing pending.
    func resolveApproval(_ approved: Bool) {
        if let pendingApproval {
            self.pendingApproval = nil
            pendingApproval.resume(returning: approved)
            return
        }
        // A request is prompting but has not reached its continuation yet.
        // Leave the answer where `approvePairing` will pick it up.
        if awaitingApproval { earlyAnswer = approved }
    }

    func folderList() async -> [SharedFolderSummary] {
        await shared.folders()
    }

    func photoList(folderID: String) async -> [PhonePhoto] {
        guard let state else { return [] }
        // Resolve IDs to URLs here, on this actor, then read the keymap for
        // all of them in a single main-actor hop. One hop per photo would put
        // 5,000 round-trips through the UI thread for a big folder.
        var resolved: [(id: String, name: String, url: URL)] = []
        for entry in await shared.photos(in: folderID) {
            guard let url = await shared.photoURL(forID: entry.id) else { continue }
            resolved.append((id: entry.id, name: entry.name, url: url))
        }
        let items = resolved
        return await MainActor.run {
            let keymap = state.vimKeymap
            return items.map { item in
                PhonePhoto(
                    id: item.id,
                    name: item.name,
                    isPicked: keymap.isPicked(item.url),
                    isRejected: keymap.isRejected(item.url),
                    colorLabel: keymap.colorLabel(for: item.url)
                )
            }
        }
    }

    func thumbnailJPEG(photoID: String) async -> Data? {
        guard let url = await shared.photoURL(forID: photoID) else { return nil }
        // Goes through the app's own cache, so a photo the grid already drew
        // costs nothing to send.
        guard let cg = await ThumbnailLoader.shared.thumbnail(for: url) else { return nil }
        return Self.jpegData(from: cg, quality: 0.7)
    }

    func previewJPEG(photoID: String) async -> Data? {
        guard let url = await shared.photoURL(forID: photoID) else { return nil }
        return Self.downscaledJPEG(url: url, maxDimension: 2048, quality: 0.82)
    }

    func apply(action: PhoneAction, photoID: String) async {
        guard let state, let url = await shared.photoURL(forID: photoID) else { return }
        await MainActor.run {
            // A resolved ID is not proof the photo is still in scope. If the
            // Mac has moved on, `select(url:)` silently no-ops but the keymap
            // mutation would still land — writing a foreign absolute path into
            // the *current* folder's sidecar, which rehydrates as garbage on
            // the next load. This layer owns that contract, so it checks.
            //
            // The folder check is the load-bearing one, because it is the same
            // question `VimKeymap.save` asks when it relativises the path.
            // `imageURLs` alone is not enough: `loadFolder` sets `folder` to
            // the new folder and only commits `imageURLs` after the walk, so
            // mid-scan the list still belongs to the folder the user left.
            guard let folder = state.folder else { return }
            let root = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            guard url.path.hasPrefix(root), state.imageURLs.contains(url) else { return }
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
