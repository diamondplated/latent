import Foundation
import Network

/// The listener. Exists only while phone access is switched on.
///
/// Network.framework rather than swift-nio: the package has no external
/// dependencies and this feature is not the reason to acquire one. The port
/// is ephemeral because it is carried in the QR anyway, which sidesteps
/// collisions with whatever else the machine is running.
public actor LocalServer {
    /// How long a peer gets to finish sending a request. Without this, a peer
    /// that opens a socket and sends nothing keeps its `NWConnection` — and
    /// the receive handler that retains it — alive until the whole server
    /// stops. It deliberately covers the read phase only: once a complete
    /// request has been handed to the router the remaining delay is ours, and
    /// a human taking a minute over the pairing prompt is not a stalled peer.
    static let readDeadline: Duration = .seconds(30)

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var readDeadlines: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Which of `connections` are serving an event stream. Deliberately a set
    /// of keys into `connections` rather than a second dictionary: one store
    /// owns the connections, so `stop()` and `close(_:)` cannot cancel a
    /// stream in one place and leave it live in the other.
    private var sseStreams: Set<ObjectIdentifier> = []
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
        // No point accepting a connection that arrives over a cellular path —
        // this is a LAN feature.
        params.prohibitedInterfaceTypes = [.cellular]

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.claim() else { return }
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    // A `stop()` that lands before `.ready` does. Without this
                    // the continuation is never resumed and the caller hangs
                    // forever on a listener that no longer exists.
                    guard resumed.claim() else { return }
                    continuation.resume(throwing: CancellationError())
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
        // Every stream is a key into `connections`, so the loop above already
        // cancelled it. Clearing the set is what stops a later `broadcast`
        // from pushing state to a phone after access was switched off.
        sseStreams.removeAll()
        for (_, t) in readDeadlines { t.cancel() }
        readDeadlines.removeAll()
        router = nil
    }

    /// Push a frame to every live event stream. A connection whose send fails
    /// — a phone that walked out of wifi range — is dropped rather than kept
    /// and retried; the browser's `EventSource` reconnects on its own.
    public func broadcast(_ frame: Data) {
        for key in sseStreams {
            guard let connection = connections[key] else { continue }
            sendFrame(frame, on: connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.start(queue: .global(qos: .userInitiated))
        readRequest(on: connection, buffer: Data())
        readDeadlines[key] = Task { [weak self] in
            try? await Task.sleep(for: Self.readDeadline)
            guard !Task.isCancelled else { return }
            await self?.close(connection)
        }
    }

    /// The peer has sent everything it owes us. Any further delay is the
    /// app's — a human deciding on a pairing, a preview being rendered — and
    /// reaping the connection under it would drop a reply the app is about to
    /// produce. For pairing that is not merely a lost response: the device is
    /// registered but its token never arrives, leaving a paired phone that
    /// cannot authenticate.
    private func clearReadDeadline(for connection: NWConnection) {
        readDeadlines.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
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
                    // Header block or body still incomplete — keep reading,
                    // unless the peer has already half-closed. Re-arming
                    // `receive` on a completed stream returns immediately with
                    // the same non-empty buffer, which would spin forever.
                    if isComplete {
                        await self.close(connection)
                        return
                    }
                    await self.readRequest(on: connection, buffer: buffer)
                    return
                }
                guard let request = HTTPRequest(parsing: buffer) else {
                    await self.send(.status(400), on: connection)
                    return
                }
                await self.clearReadDeadline(for: connection)
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
        // An event stream is the one response that outlives its request: the
        // head and first frame go out now, the rest arrive via `broadcast`,
        // and the connection is not closed until the peer goes away or phone
        // access is switched off. The read deadline was already cleared before
        // the router ran, so nothing reaps it — and that hole stays shut,
        // because the deadline only clears once a complete request has been
        // parsed. A peer that connects and says nothing still never gets here.
        if response.headers["Content-Type"] == SSEFrame.contentType {
            sseStreams.insert(ObjectIdentifier(connection))
            watchForPeerClose(on: connection)
            sendFrame(response.serialize(), on: connection)
            return
        }
        connection.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(connection) }
        })
    }

    /// One frame on an open stream. Failure means the peer is gone, so the
    /// stream is dropped — never retried, never accumulated.
    private func sendFrame(_ bytes: Data, on connection: NWConnection) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { await self?.close(connection) }
        })
    }

    /// A client never writes on an event stream, so the only thing that can
    /// arrive is the peer hanging up. Without this a closed tab sits in
    /// CLOSE_WAIT until the next broadcast happens to fail, which for a phone
    /// that is simply idle could be never.
    private func watchForPeerClose(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            Task { await self?.close(connection) }
        }
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        sseStreams.remove(ObjectIdentifier(connection))
        clearReadDeadline(for: connection)
    }

    /// Peer address as a bare string, for `AddressGate`.
    nonisolated static func remoteHost(of connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let a): return "\(a)"
            case .ipv6(let a): return "\(a)"
            // A hostname is not an address; `AddressGate` would refuse it
            // anyway, so fail closed rather than hand it a string to parse.
            case .name:        return ""
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
            let text = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard AddressGate.isPrivate(text) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // Prefer the primary interface when several are up.
            if name == "en0" { return text }
            if best == nil { best = text }
        }
        return best
    }
}

/// One-shot latch for continuations resumed from a `@Sendable` state handler,
/// which cannot capture a mutable local.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
