import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

enum FullBufferReadOutcome: @unchecked Sendable {
    case success(ImageBuffer, ImageMetadata)
    case failure(any Error)
    case cancelled
}

/// One-shot result shared when more than one UI action asks for the same full
/// buffer. The operation resolves this from a worker thread while the editor
/// awaits it on the main actor.
final class FullBufferReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: FullBufferReadOutcome?
    private var waiters: [CheckedContinuation<FullBufferReadOutcome, Never>] = []

    func value() async -> FullBufferReadOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ outcome: FullBufferReadOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in pending {
            continuation.resume(returning: outcome)
        }
    }
}

/// A full-resolution read holds its physical queue permit until the complete
/// ImageIO + working-buffer conversion returns. Queued reads can be cancelled;
/// already-running reads remain reusable if their URL quickly becomes current
/// again.
final class FullBufferReadOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let reader: ImageReader
    private let result: FullBufferReadResult
    private let stateLock = NSLock()
    private var startedRead = false

    init(url: URL, reader: ImageReader, result: FullBufferReadResult) {
        self.url = url
        self.reader = reader
        self.result = result
        super.init()
    }

    override func main() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            result.resolve(.cancelled)
            return
        }
        startedRead = true
        stateLock.unlock()

        do {
            let (buffer, metadata) = try reader.read(url: url)
            result.resolve(.success(buffer, metadata))
        } catch {
            result.resolve(.failure(error))
        }
    }

    func cancelIfQueued() -> Bool {
        stateLock.lock()
        guard !startedRead else {
            stateLock.unlock()
            return false
        }
        super.cancel()
        stateLock.unlock()
        result.resolve(.cancelled)
        return true
    }
}

/// Keeps only the newest queued full-buffer request while sharing any existing
/// job for the same URL. Running synchronous reads cannot be interrupted, so
/// they remain registered and continue occupying the process-wide decode gate
/// until return instead of disappearing from concurrency accounting.
@MainActor
final class FullBufferReadCoordinator {
    private struct Job {
        let id: UUID
        let operation: FullBufferReadOperation
        let resultTask: Task<FullBufferReadOutcome, Never>
    }

    private let reader = ImageReader()
    private var jobs: [URL: Job] = [:]
    private var requestedURL: URL?

    func read(_ url: URL) -> Task<FullBufferReadOutcome, Never> {
        requestedURL = url
        cancelQueuedJobs(except: url)

        if let existing = jobs[url] {
            existing.operation.queuePriority = .veryHigh
            existing.operation.qualityOfService = .userInitiated
            return existing.resultTask
        }

        let id = UUID()
        let result = FullBufferReadResult()
        let operation = FullBufferReadOperation(url: url, reader: reader, result: result)
        operation.queuePriority = .veryHigh
        operation.qualityOfService = .userInitiated
        let resultTask = Task.detached(priority: .userInitiated) {
            await result.value()
        }
        jobs[url] = Job(id: id, operation: operation, resultTask: resultTask)

        Task { @MainActor [weak self, resultTask] in
            _ = await resultTask.value
            self?.finish(url: url, id: id)
        }
        ImageDecodeWorkQueue.shared.addOperation(operation)
        return resultTask
    }

    func cancelRequest(for url: URL?) {
        if url == nil || requestedURL == url {
            requestedURL = nil
        }
        cancelQueuedJobs(except: requestedURL)
    }

    private func cancelQueuedJobs(except retainedURL: URL?) {
        let obsolete = jobs.keys.filter { $0 != retainedURL }
        for url in obsolete {
            guard let job = jobs[url] else { continue }
            if job.operation.cancelIfQueued() {
                jobs.removeValue(forKey: url)
            }
        }
    }

    private func finish(url: URL, id: UUID) {
        guard jobs[url]?.id == id else { return }
        jobs.removeValue(forKey: url)
    }
}
