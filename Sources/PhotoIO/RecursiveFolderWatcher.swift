import Foundation
import CoreServices

/// One debounced batch of changes observed anywhere below a watched folder.
///
/// `requiresFullRescan` is true when FSEvents reports that events were dropped,
/// coalesced at directory granularity, or otherwise cannot be treated as a
/// complete file-by-file history. Latent currently rescans for every batch, but
/// retaining this signal keeps the wrapper safe for future incremental users.
public struct RecursiveFolderChangeBatch: Sendable, Equatable {
    public let changedURLs: [URL]
    public let requiresFullRescan: Bool

    public init(changedURLs: [URL], requiresFullRescan: Bool) {
        self.changedURLs = changedURLs
        self.requiresFullRescan = requiresFullRescan
    }
}

public enum RecursiveFolderWatcherError: Error, LocalizedError, Sendable {
    case couldNotCreateStream(URL)
    case couldNotStartStream(URL)

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateStream(let url):
            return "Could not create a recursive file watcher for \(url.lastPathComponent)."
        case .couldNotStartStream(let url):
            return "Could not start a recursive file watcher for \(url.lastPathComponent)."
        }
    }
}

/// Subtree-aware folder monitoring backed by macOS FSEvents.
///
/// A file-level stream is rooted at exactly one folder. Event paths from a
/// short burst are accumulated on a private serial queue and delivered once
/// the filesystem has been quiet for `debounceInterval`. `stop()` invalidates
/// the stream, cancels pending delivery, and drains callbacks before returning,
/// so an unretained FSEvents context can never outlive this object.
public final class RecursiveFolderWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (RecursiveFolderChangeBatch) -> Void

    private let rootURL: URL
    private let rootPath: String
    private let latency: CFTimeInterval
    private let debounceInterval: TimeInterval
    private let handler: Handler
    private let callbackQueue: DispatchQueue
    private let callbackQueueKey = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()

    private var stream: FSEventStreamRef?
    // The remaining mutable fields are confined to `callbackQueue`.
    private var pendingPaths: Set<String> = []
    private var pendingRequiresFullRescan = false
    private var pendingDelivery: DispatchWorkItem?
    private var deliveryGeneration: UInt64 = 0

    public init(
        rootURL: URL,
        latency: CFTimeInterval = 0.10,
        debounceInterval: TimeInterval = 0.20,
        handler: @escaping Handler
    ) {
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.rootURL = canonicalRoot
        self.rootPath = canonicalRoot.path
        self.latency = max(0.01, latency)
        self.debounceInterval = max(0, debounceInterval)
        self.handler = handler
        self.callbackQueue = DispatchQueue(
            label: "com.diamondplated.latent.folder-watcher",
            qos: .utility
        )
        callbackQueue.setSpecific(key: callbackQueueKey, value: 1)
    }

    deinit {
        stop()
    }

    /// Start monitoring. Calling `start()` again while already running is a
    /// no-op, which keeps AppState teardown/reload paths simple and idempotent.
    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            recursiveFolderEventCallback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw RecursiveFolderWatcherError.couldNotCreateStream(rootURL)
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, callbackQueue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamSetDispatchQueue(newStream, nil)
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            throw RecursiveFolderWatcherError.couldNotStartStream(rootURL)
        }
    }

    /// Stop monitoring and guarantee that no future handler invocation can be
    /// delivered by this watcher. Safe to call repeatedly.
    public func stop() {
        stateLock.lock()
        let oldStream = stream
        stream = nil
        if let oldStream {
            FSEventStreamStop(oldStream)
            FSEventStreamSetDispatchQueue(oldStream, nil)
            FSEventStreamInvalidate(oldStream)
            FSEventStreamRelease(oldStream)
        }
        stateLock.unlock()

        let cancelPending = { [self] in
            pendingDelivery?.cancel()
            pendingDelivery = nil
            deliveryGeneration &+= 1
            pendingPaths.removeAll(keepingCapacity: false)
            pendingRequiresFullRescan = false
        }
        if DispatchQueue.getSpecific(key: callbackQueueKey) != nil {
            cancelPending()
        } else {
            // The callback context is unretained. Draining the queue here is
            // what makes it safe for the watcher to be released after stop.
            callbackQueue.sync(execute: cancelPending)
        }
    }

    fileprivate func receive(
        paths: [String],
        flags: [FSEventStreamEventFlags]
    ) {
        // FSEvents invokes this method on callbackQueue, so no lock is needed
        // for the batch accumulator.
        pendingPaths.formUnion(paths)
        pendingRequiresFullRescan = pendingRequiresFullRescan || flags.contains {
            let recoveryFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs
                    | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
                    | kFSEventStreamEventFlagEventIdsWrapped
                    | kFSEventStreamEventFlagRootChanged
                    | kFSEventStreamEventFlagMount
                    | kFSEventStreamEventFlagUnmount
            )
            return $0 & recoveryFlags != 0
        }

        pendingDelivery?.cancel()
        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        let delivery = DispatchWorkItem { [weak self] in
            // `DispatchWorkItem.cancel()` is cooperative and does not promise
            // that an already-enqueued block will be skipped. The generation
            // gate is the hard guarantee that superseded/stop-cancelled work
            // cannot drain the new accumulator or call the handler.
            guard let self, self.deliveryGeneration == generation else { return }
            let urls = self.pendingPaths
                .sorted()
                .map { URL(fileURLWithPath: $0) }
            let batch = RecursiveFolderChangeBatch(
                changedURLs: urls,
                requiresFullRescan: self.pendingRequiresFullRescan
            )
            self.pendingPaths.removeAll(keepingCapacity: false)
            self.pendingRequiresFullRescan = false
            self.pendingDelivery = nil
            self.handler(batch)
        }
        pendingDelivery = delivery
        callbackQueue.asyncAfter(
            deadline: .now() + debounceInterval,
            execute: delivery
        )
    }
}

private func recursiveFolderEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    _ = stream
    _ = eventIDs
    guard eventCount > 0, let clientInfo else { return }

    let watcher = Unmanaged<RecursiveFolderWatcher>
        .fromOpaque(clientInfo)
        .takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>
        .fromOpaque(eventPaths)
        .takeUnretainedValue()

    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []
    paths.reserveCapacity(eventCount)
    flags.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, index) else { continue }
        let path = unsafeBitCast(rawPath, to: CFString.self) as String
        paths.append(path)
        flags.append(eventFlags[index])
    }
    watcher.receive(paths: paths, flags: flags)
}
