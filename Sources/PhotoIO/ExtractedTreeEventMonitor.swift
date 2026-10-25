import Darwin
import CoreServices
import Foundation

/// File-level FSEvents monitoring makes extraction validation proportional to
/// changed paths instead of `entryCount * pollCount`. A dropped/coalesced event
/// batch requests a full ledger rebuild, which is the documented safe recovery
/// path and not the steady-state behavior.
final class ExtractedTreeEventMonitor: @unchecked Sendable {
    private let ledger: ExtractedTreeLedger
    private let archiveURL: URL
    private let latency: CFTimeInterval
    private let callbackQueue = DispatchQueue(label: "com.diamondplated.latent.archive-monitor", qos: .utility)
    private let stateLock = NSLock()
    private var failure: Error?
    private var stream: FSEventStreamRef?

    init(root: URL, archiveURL: URL, limits: ArchiveExtractionLimits) {
        self.ledger = ExtractedTreeLedger(root: root, archiveURL: archiveURL, limits: limits)
        self.archiveURL = archiveURL
        self.latency = max(0.05, min(limits.pollInterval, 0.25))
    }

    func start() throws {
        try ledger.replaceWithFullScan(strict: false)

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
            archiveTreeEventCallback,
            &context,
            [ledger.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not start extraction safety monitoring"
            )
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, callbackQueue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamSetDispatchQueue(newStream, nil)
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not start extraction safety monitoring"
            )
        }
    }

    func checkForFailure() throws {
        stateLock.lock()
        let currentFailure = failure
        stateLock.unlock()
        if let currentFailure { throw currentFailure }
    }

    func stop(flushPendingEvents: Bool) {
        guard let stream else { return }
        if flushPendingEvents {
            FSEventStreamFlushSync(stream)
        }
        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil

        // The context pointer is unretained, so ensure every callback that was
        // already submitted has returned before this monitor can be released.
        callbackQueue.sync {}
    }

    fileprivate func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        do {
            if flags.contains(where: {
                $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    || $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0
                    || $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0
            }) {
                throw ArchiveError.unsafeArchive(
                    archiveURL,
                    "the extraction directory changed while it was being monitored"
                )
            }

            if flags.contains(where: {
                $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            }) {
                try ledger.replaceWithFullScan(strict: false)
                return
            }

            // Parents first: if a whole new hierarchy arrives in one batch,
            // its first subtree scan records descendants before their events.
            let orderedPaths = Set(paths).sorted {
                let lhsDepth = $0.utf8.reduce(into: 0) { if $1 == 47 { $0 += 1 } }
                let rhsDepth = $1.utf8.reduce(into: 0) { if $1 == 47 { $0 += 1 } }
                return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
            }
            for path in orderedPaths {
                if try ledger.reconcile(path: path) {
                    try ledger.addInitialContents(ofDirectoryAt: path)
                }
            }
            // Validate aggregate limits after the entire batch is reconciled.
            // Rename events can arrive new-path-first; checking each mutation
            // would briefly double-count the same file and reject safe archives.
            try ledger.validateCurrentTotals()
        } catch {
            recordFailure(error)
        }
    }

    private func recordFailure(_ error: Error) {
        stateLock.lock()
        if failure == nil { failure = error }
        stateLock.unlock()
    }
}

func archiveTreeEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    _ = stream
    _ = eventIDs
    guard let clientInfo else { return }
    let monitor = Unmanaged<ExtractedTreeEventMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
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
    monitor.receive(paths: paths, flags: flags)
}
