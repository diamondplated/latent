import Foundation
import XCTest
@testable import PhotoIO

final class RecursiveFolderWatcherTests: XCTestCase {
    func testDeepAddRenameRemoveAndStop() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("one/two", isDirectory: true)
        let recorder = FolderChangeRecorder()
        let watcher = RecursiveFolderWatcher(
            rootURL: root,
            latency: 0.02,
            debounceInterval: 0.05,
            handler: recorder.record
        )
        try watcher.start()
        defer { watcher.stop() }

        let added = nested.appendingPathComponent("added.jpg")
        try Data([1, 2, 3]).write(to: added)
        XCTAssertTrue(
            recorder.waitForBatch(after: 0),
            "a file added two levels below the root should emit an event"
        )

        Thread.sleep(forTimeInterval: 0.15)
        let afterAdd = recorder.count
        try Data([4, 5, 6]).write(to: added)
        XCTAssertTrue(
            recorder.waitForBatch(after: afterAdd),
            "modifying an existing deep file in place should emit an event"
        )

        Thread.sleep(forTimeInterval: 0.15)
        let afterModify = recorder.count
        let renamed = nested.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: added, to: renamed)
        XCTAssertTrue(
            recorder.waitForBatch(after: afterModify),
            "a deep rename should emit an event"
        )

        Thread.sleep(forTimeInterval: 0.15)
        let afterRename = recorder.count
        try FileManager.default.removeItem(at: renamed)
        XCTAssertTrue(
            recorder.waitForBatch(after: afterRename),
            "a deeply nested removal should emit an event"
        )

        watcher.stop()
        let afterStop = recorder.count
        try Data([7, 8, 9]).write(to: nested.appendingPathComponent("after-stop.jpg"))
        XCTAssertFalse(
            recorder.waitForBatch(after: afterStop, timeout: 0.50),
            "stop must prevent later event delivery"
        )
    }

    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("latent-folder-watch-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("one/two", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }
}

private final class FolderChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var batches: [RecursiveFolderChangeBatch] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return batches.count
    }

    func record(_ batch: RecursiveFolderChangeBatch) {
        lock.lock()
        batches.append(batch)
        lock.unlock()
        signal.signal()
    }

    func waitForBatch(after index: Int, timeout: TimeInterval = 5) -> Bool {
        wait(after: index, timeout: timeout) { _ in true }
    }

    private func wait(
        after index: Int,
        timeout: TimeInterval,
        matching predicate: (RecursiveFolderChangeBatch) -> Bool
    ) -> Bool {
        let deadline = DispatchTime.now() + timeout
        var nextIndex = index
        while true {
            lock.lock()
            let snapshot = batches
            lock.unlock()
            while nextIndex < snapshot.count {
                if predicate(snapshot[nextIndex]) { return true }
                nextIndex += 1
            }
            if signal.wait(timeout: deadline) == .timedOut { return false }
        }
    }
}
