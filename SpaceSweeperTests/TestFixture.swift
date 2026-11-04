import Foundation
import XCTest

/// A throwaway directory tree under the system temp folder. Tests never touch real user files.
final class TestFixture {
    let root: URL
    var path: String { root.path }
    private let container: URL

    init(name: String = "fixture") throws {
        // Resolve /var → /private/var so paths match what the scanner reports.
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        container = temp.appendingPathComponent("SpaceSweeperTests-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        precondition(root.path.contains("/SpaceSweeperTests-"), "Fixture must live in a temp directory")
    }

    deinit {
        // Restore permissions changed by tests so cleanup can't fail.
        if let enumerator = FileManager.default.enumerator(atPath: container.path) {
            for case let relative as String in enumerator {
                chmod(container.appendingPathComponent(relative).path, 0o755)
            }
        }
        try? FileManager.default.removeItem(at: container)
    }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func path(_ relative: String) -> String { url(relative).path }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
        return path(relative)
    }

    /// Writes a file of `bytes` non-zero bytes (so it is really allocated, not sparse).
    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> String {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: bytes).write(to: target)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
        }
        return target.path
    }

    /// Creates a sparse file: large logical size, almost nothing allocated.
    @discardableResult
    func sparseFile(_ relative: String, logicalSize: Int64) throws -> String {
        let target = path(relative)
        let fd = open(target, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, off_t(logicalSize)), 0)
        close(fd)
        return target
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func hardLink(_ relative: String, to existingRelative: String) throws {
        try FileManager.default.linkItem(atPath: path(existingRelative), toPath: path(relative))
    }

    /// Allocated size as Foundation reports it, used as the expected value.
    func allocated(_ relative: String) -> Int64 {
        let values = try? url(relative).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? 0)
    }
}
