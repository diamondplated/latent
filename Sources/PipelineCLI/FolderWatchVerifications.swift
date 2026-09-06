import Foundation
import PhotoIO

/// Pin the path rules used by AppState's direct/recursive scans and FSEvents
/// reconciliation. The test deliberately uses `/tmp` instead of
/// `NSTemporaryDirectory()` so Darwin's `/private/tmp` alias is exercised.
public func folderPathMapperHandlesAliasesAndSymlinkRoots() async throws {
    let fileManager = FileManager.default
    let suffix = UUID().uuidString
    let target = URL(
        fileURLWithPath: "/tmp/pv-path-target-\(suffix)",
        isDirectory: true
    )
    let link = URL(
        fileURLWithPath: "/tmp/pv-path-link-\(suffix)",
        isDirectory: true
    )
    defer {
        try? fileManager.removeItem(at: link)
        try? fileManager.removeItem(at: target)
    }

    let nested = target.appendingPathComponent("nested", isDirectory: true)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data([1]).write(to: target.appendingPathComponent("direct.jpg"))
    try Data([2]).write(to: nested.appendingPathComponent("deep.jpg"))
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    let targetMapper = FolderPathMapper(rootURL: target)
    let privateChild = URL(
        fileURLWithPath: "/private" + target.path + "/nested/deep.jpg"
    )
    try require(
        targetMapper.relativePath(of: privateChild) == "nested/deep.jpg",
        "/private/tmp child did not map below a /tmp root"
    )
    try require(
        targetMapper.rebaseToRoot(privateChild).path
            == target.appendingPathComponent("nested/deep.jpg").path,
        "/private/tmp child did not rebase to the selected root spelling"
    )

    let privateTarget = URL(
        fileURLWithPath: "/private" + target.path,
        isDirectory: true
    )
    let privateMapper = FolderPathMapper(rootURL: privateTarget)
    try require(
        privateMapper.rootPath == privateTarget.path,
        "an explicit /private/tmp root lost its caller spelling"
    )
    try require(
        privateMapper.rebaseToRoot(
            target.appendingPathComponent("direct.jpg")
        ).path == privateTarget.appendingPathComponent("direct.jpg").path,
        "a /tmp child did not rebase to an explicit /private/tmp root"
    )
    try require(
        privateMapper.url(forRelativePath: "nested/deep.jpg")?.path
            == privateTarget.appendingPathComponent("nested/deep.jpg").path,
        "search-result reconstruction lost the explicit root spelling"
    )
    try require(
        privateMapper.url(forRelativePath: "../outside.jpg") == nil,
        "relative-path reconstruction accepted traversal"
    )

    let linkMapper = FolderPathMapper(rootURL: link)
    let direct = try fileManager.contentsOfDirectory(
        at: linkMapper.enumerationRootURL,
        includingPropertiesForKeys: nil
    ).map { linkMapper.rebaseToRoot($0).path }
    try require(
        direct.contains(link.appendingPathComponent("direct.jpg").path),
        "direct scan through a directory symlink found no rebased photo"
    )

    guard let enumerator = fileManager.enumerator(
        at: linkMapper.enumerationRootURL,
        includingPropertiesForKeys: nil
    ) else {
        throw VerifyError(message: "recursive scan could not enumerate a directory symlink")
    }
    let recursive = enumerator.compactMap { entry -> String? in
        guard let url = entry as? URL else { return nil }
        return linkMapper.rebaseToRoot(url).path
    }
    try require(
        recursive.contains(link.appendingPathComponent("nested/deep.jpg").path),
        "recursive scan through a directory symlink found no rebased deep photo"
    )
}

/// Prove that deep add/modify/rename/removal activity is delivered without
/// reopening the folder and that teardown suppresses later events.
public func recursiveFolderWatcherTracksDeepChanges() async throws {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pv-folder-watch-\(UUID().uuidString)", isDirectory: true)
        .resolvingSymlinksInPath()
    let nested = root.appendingPathComponent("one/two", isDirectory: true)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }

    let recorder = FolderWatchVerificationRecorder()
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
    try await requireFolderEvent(
        recorder,
        after: 0,
        message: "deep add did not trigger the recursive watcher"
    )

    try await Task.sleep(for: .milliseconds(150))
    let afterAdd = recorder.count
    try Data([4, 5, 6]).write(to: added)
    try await requireFolderEvent(
        recorder,
        after: afterAdd,
        message: "in-place deep modification did not trigger the recursive watcher"
    )

    try await Task.sleep(for: .milliseconds(150))
    let afterModify = recorder.count
    let renamed = nested.appendingPathComponent("renamed.jpg")
    try fileManager.moveItem(at: added, to: renamed)
    try await requireFolderEvent(
        recorder,
        after: afterModify,
        message: "deep rename did not trigger the recursive watcher"
    )

    try await Task.sleep(for: .milliseconds(150))
    let afterRename = recorder.count
    try fileManager.removeItem(at: renamed)
    try await requireFolderEvent(
        recorder,
        after: afterRename,
        message: "deep removal did not trigger the recursive watcher"
    )

    watcher.stop()
    let afterStop = recorder.count
    try Data([7, 8, 9]).write(to: nested.appendingPathComponent("after-stop.jpg"))
    try await Task.sleep(for: .milliseconds(400))
    try require(
        recorder.count == afterStop,
        "recursive watcher delivered an event after stop"
    )
}

private func requireFolderEvent(
    _ recorder: FolderWatchVerificationRecorder,
    after index: Int,
    message: String
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(5))
    while clock.now < deadline {
        if recorder.count > index { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    try require(recorder.count > index, message)
}

private final class FolderWatchVerificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
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
    }
}
