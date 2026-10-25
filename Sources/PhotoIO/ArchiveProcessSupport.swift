import Darwin
import CoreServices
import Foundation

final class SendableProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

final class BoundedDataCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let data: Data
        let truncated: Bool
    }

    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(contentsOf: chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: data, truncated: truncated)
    }

    func diagnosticString() -> String {
        let snapshot = snapshot()
        var message = String(decoding: snapshot.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.truncated {
            message += message.isEmpty ? "[diagnostic output truncated]" : "\n[diagnostic output truncated]"
        }
        return message.isEmpty ? "(no stderr)" : message
    }
}
