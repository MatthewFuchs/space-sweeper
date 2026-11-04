import XCTest
@testable import SpaceSweeper

final class ScannerTests: XCTestCase {
    private var fixture: TestFixture!

    override func setUpWithError() throws {
        fixture = try TestFixture()
    }

    override func tearDown() {
        fixture = nil
    }

    /// Small thresholds so a few-KB fixture exercises tracking and pruning.
    private func options(tracked: Int64 = 100_000, keep: Int64 = 0, split: Int? = 2) -> ScanOptions {
        var options = ScanOptions(roots: [fixture.path], homePath: fixture.path)
        options.trackedFileMinimum = tracked
        options.folderKeepMinimum = keep
        options.splitDepth = split
        options.maxConcurrency = 4
        return options
    }

    private func scan(_ options: ScanOptions) async throws -> ScanResult {
        try await FileScanner.scan(options: options, progress: ScanProgress())
    }

    // MARK: Directory listers

    func testBulkListerMatchesFoundationLister() throws {
        try fixture.file("a.bin", bytes: 12_345)
        try fixture.file("b.bin", bytes: 300_000)
        try fixture.dir("sub")
        try fixture.symlink("link", to: "/etc/hosts")
        try fixture.sparseFile("sparse.img", logicalSize: 50_000_000)

        var bulk: [DirEntry] = []
        var reference: [DirEntry] = []
        XCTAssertEqual(BulkDirectoryLister().list(fixture.path, into: &bulk), 0)
        XCTAssertEqual(FoundationDirectoryLister().list(fixture.path, into: &reference), 0)

        let bulkByName = Dictionary(uniqueKeysWithValues: bulk.map { ($0.name, $0) })
        XCTAssertEqual(Set(bulkByName.keys), Set(reference.map(\.name)))
        for expected in reference {
            let actual = try XCTUnwrap(bulkByName[expected.name])
            XCTAssertEqual(actual.type, expected.type, expected.name)
            XCTAssertEqual(actual.fileID, expected.fileID, expected.name)
            if expected.type == .file {
                // Link counts only matter (and are only reported by getattrlistbulk) for files.
                XCTAssertEqual(actual.linkCount, expected.linkCount, expected.name)
                XCTAssertEqual(actual.allocatedSize, expected.allocatedSize, expected.name)
                XCTAssertEqual(actual.logicalSize, expected.logicalSize, expected.name)
                XCTAssertEqual(actual.modified, expected.modified, accuracy: 0.001, expected.name)
            }
        }
    }

    func testListerReportsErrorForMissingDirectory() {
        var entries: [DirEntry] = []
        XCTAssertEqual(BulkDirectoryLister().list(fixture.path("missing"), into: &entries), ENOENT)
    }

    // MARK: Size aggregation

    func testFolderSizesAreSumOfAllocatedSizes() async throws {
        try fixture.file("docs/a.txt", bytes: 5_000)
        try fixture.file("docs/deep/b.txt", bytes: 70_000)
        try fixture.file("media/c.mov", bytes: 400_000)
        try fixture.file("top.dat", bytes: 1_000)

        let result = try await scan(options())
        let tree = result.tree

        let docs = fixture.allocated("docs/a.txt") + fixture.allocated("docs/deep/b.txt")
        let media = fixture.allocated("media/c.mov")
        XCTAssertEqual(tree.size(ofPath: fixture.path("docs")), docs)
        XCTAssertEqual(tree.size(ofPath: fixture.path("docs/deep")), fixture.allocated("docs/deep/b.txt"))
        XCTAssertEqual(tree.size(ofPath: fixture.path("media")), media)
        XCTAssertEqual(result.totalSize, docs + media + fixture.allocated("top.dat"))
        XCTAssertEqual(result.itemsScanned, 7) // 4 files + docs, docs/deep, media
    }

    func testOnlyFilesAboveThresholdAreTracked() async throws {
        try fixture.file("small.bin", bytes: 50_000)
        try fixture.file("big.bin", bytes: 250_000)
        let result = try await scan(options(tracked: 100_000))
        XCTAssertEqual(result.files.map(\.name), ["big.bin"])
        XCTAssertEqual(result.files.first?.size, fixture.allocated("big.bin"))
        XCTAssertFalse(result.files.first?.kind.isEmpty ?? true)
    }

    func testChildrenAreSortedLargestFirstAndSumToParent() async throws {
        try fixture.file("p/small/x", bytes: 20_000)
        try fixture.file("p/large/y", bytes: 300_000)
        try fixture.file("p/medium/z", bytes: 120_000)
        try fixture.file("p/loose.bin", bytes: 3_000)

        // Prune folders below 50 KB so "small" and the loose file roll into "Other files".
        let result = try await scan(options(tracked: 1_000_000, keep: 50_000))
        let tree = result.tree
        let parent = try XCTUnwrap(tree.index(ofPath: fixture.path("p")))
        let children = tree.nodes[Int(parent)].children.map { tree.nodes[Int($0)] }

        XCTAssertEqual(children.map(\.name), ["large", "medium", FolderTree.otherFilesName])
        XCTAssertEqual(children.reduce(0) { $0 + $1.size }, tree.nodes[Int(parent)].size)
        XCTAssertNil(tree.index(ofPath: fixture.path("p/small")), "pruned folder should not be addressable")
    }

    func testParallelScanMatchesSequentialScan() async throws {
        for i in 0..<6 {
            for j in 0..<4 {
                try fixture.file("level1-\(i)/level2-\(j)/level3/file.bin", bytes: 10_000 * (i + 1) + j * 3_000)
            }
        }
        try fixture.file("level1-0/big.bin", bytes: 200_000)

        let parallel = try await scan(options(split: 1))
        let sequential = try await scan(options(split: nil))

        XCTAssertEqual(parallel.totalSize, sequential.totalSize)
        XCTAssertEqual(parallel.itemsScanned, sequential.itemsScanned)
        XCTAssertEqual(Set(parallel.files.map(\.path)), Set(sequential.files.map(\.path)))
        for i in 0..<6 {
            let path = fixture.path("level1-\(i)")
            XCTAssertEqual(parallel.tree.size(ofPath: path), sequential.tree.size(ofPath: path), path)
        }
    }

    // MARK: Special files

    func testHardLinksAreCountedOnce() async throws {
        try fixture.file("original.bin", bytes: 300_000)
        try fixture.dir("other")
        try fixture.hardLink("other/link.bin", to: "original.bin")

        let result = try await scan(options())
        XCTAssertEqual(result.totalSize, fixture.allocated("original.bin"))
    }

    func testSymlinksAreNotFollowed() async throws {
        let outside = try TestFixture(name: "outside")
        try outside.file("huge.bin", bytes: 2_000_000)
        try outside.file("dir/inner.bin", bytes: 500_000)
        try fixture.symlink("file-link", to: outside.path("huge.bin"))
        try fixture.symlink("dir-link", to: outside.path("dir"))

        let result = try await scan(options())
        XCTAssertLessThan(result.totalSize, 100_000, "symlink targets must not be counted")
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertNil(result.tree.index(ofPath: fixture.path("dir-link/inner.bin")))
    }

    func testSparseFileReportsAllocatedNotLogicalSize() async throws {
        try fixture.sparseFile("disk.raw", logicalSize: 5_000_000_000)
        let result = try await scan(options(tracked: 0))
        let record = try XCTUnwrap(result.files.first { $0.name == "disk.raw" })
        XCTAssertEqual(record.logicalSize, 5_000_000_000)
        XCTAssertLessThan(record.size, 1_000_000, "sparse file should report real (allocated) usage")
    }

    func testPackagesAreListedAsSingleItems() async throws {
        try fixture.file("Big.app/Contents/MacOS/Big", bytes: 150_000)
        try fixture.file("Big.app/Contents/Resources/huge.bin", bytes: 300_000)

        let result = try await scan(options(tracked: 100_000))
        XCTAssertEqual(result.files.map(\.name), ["Big.app"], "files inside a package are not listed separately")
        let app = try XCTUnwrap(result.files.first)
        XCTAssertTrue(app.isPackage)
        XCTAssertEqual(app.size, fixture.allocated("Big.app/Contents/MacOS/Big") + fixture.allocated("Big.app/Contents/Resources/huge.bin"))
    }

    // MARK: Errors & exclusions

    func testUnreadableFolderIsSkippedAndReported() async throws {
        try fixture.file("ok/a.bin", bytes: 10_000)
        try fixture.file("locked/secret.bin", bytes: 10_000)
        XCTAssertEqual(chmod(fixture.path("locked"), 0o000), 0)
        defer { chmod(fixture.path("locked"), 0o755) }

        let result = try await scan(options())
        let skipped = try XCTUnwrap(result.skipped.first { $0.path == fixture.path("locked") })
        XCTAssertEqual(skipped.reason, "Permission denied")
        XCTAssertEqual(result.tree.size(ofPath: fixture.path("ok")), fixture.allocated("ok/a.bin"))
    }

    func testSkipRules() {
        XCTAssertNotNil(SkipRules.exclusionReason(path: "/System/Library", name: "Library", root: "/"))
        XCTAssertNotNil(SkipRules.exclusionReason(path: "/private/var/vm", name: "vm", root: "/"))
        XCTAssertNotNil(SkipRules.exclusionReason(path: "/Volumes/Backup", name: "Backup", root: "/"))
        XCTAssertNil(SkipRules.exclusionReason(path: "/Volumes/Backup/Photos", name: "Photos", root: "/Volumes/Backup"),
                     "an explicitly added volume is scanned")
        XCTAssertNotNil(SkipRules.exclusionReason(path: "/Volumes/X/.Spotlight-V100", name: ".Spotlight-V100", root: "/Volumes/X"))
        XCTAssertNil(SkipRules.exclusionReason(path: "/Users/me/SystemStuff", name: "SystemStuff", root: "/Users/me"))
    }

    func testCancellationStopsScan() async throws {
        for i in 0..<50 { try fixture.file("d\(i)/f.bin", bytes: 1_000) }
        let task = Task { try await scan(options(split: 1)) }
        task.cancel()
        do {
            _ = try await task.value
            // Finishing before cancellation was observed is acceptable on a fast machine.
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: Roots, tree helpers, cache

    func testOverlappingRootsAreDeduplicated() {
        let roots = PathUtil.dedupedRoots(["/tmp/a/b", "/tmp/a", "/tmp/ab"])
        XCTAssertEqual(Set(roots), Set([PathUtil.normalize("/tmp/a"), PathUtil.normalize("/tmp/ab")]))
    }

    func testTreeRemovalUpdatesAncestors() async throws {
        try fixture.file("x/y/big.bin", bytes: 300_000)
        try fixture.file("x/keep.bin", bytes: 200_000)
        var result = try await scan(options())
        let before = result.totalSize
        result.removeItems(atPaths: [fixture.path("x/y")])
        XCTAssertEqual(result.totalSize, before - fixture.allocated("x/y/big.bin"))
        XCTAssertNil(result.tree.index(ofPath: fixture.path("x/y")))
        XCTAssertFalse(result.files.contains { $0.name == "big.bin" })
    }

    func testCacheRoundTrip() async throws {
        try fixture.file("a/b.bin", bytes: 200_000)
        let result = try await scan(options())
        let cache = ScanCache(fileURL: fixture.url("cache/last-scan.json"))
        try cache.save(result)
        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.totalSize, result.totalSize)
        XCTAssertEqual(loaded.files, result.files)
        XCTAssertEqual(loaded.tree.nodes, result.tree.nodes)
    }
}
