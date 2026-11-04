import Foundation
import CoreServices

/// Why a scan produced no results.
enum ScanError: LocalizedError, Equatable {
    case noLocations
    case nothingReadable([SkippedPath])

    var errorDescription: String? {
        switch self {
        case .noLocations:
            return "No scan locations are selected."
        case .nothingReadable(let failures):
            let list = failures.map { "\(PathUtil.abbreviate($0.path)) (\($0.reason.lowercased()))" }.joined(separator: ", ")
            return "Couldn't read \(list)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .noLocations: return "Add a folder under Scan Locations."
        case .nothingReadable: return "Check the drive is connected and that SpaceSweeper has Full Disk Access."
        }
    }
}

/// Coordinates a full scan: walks the top levels of each root, scans deeper subtrees in parallel,
/// splices the results into one tree and enriches large files with Spotlight metadata.
enum FileScanner {
    static func scan(options: ScanOptions, progress: ScanProgress) async throws -> ScanResult {
        let start = Date()
        let roots = PathUtil.dedupedRoots(options.roots)
        guard !roots.isEmpty else { throw ScanError.noLocations }
        var unreadableRoots: [SkippedPath] = []
        let hardLinks = HardLinkRegistry()

        var nodes: [TreeNode] = []
        var output = WalkerOutput()

        for root in roots {
            try Task.checkCancellation()
            let top = SubtreeWalker(options: options, rootPath: root, progress: progress,
                                    hardLinks: hardLinks, splitDepth: options.splitDepth)
            top.walk(path: root, name: root, parent: -1, kind: .root, depth: 0, context: WalkContext())
            if let failure = top.output.skipped.first(where: { $0.path == root }) {
                unreadableRoots.append(failure)
            }

            let base = Int32(nodes.count)
            for var node in top.output.nodes {
                if node.parent >= 0 { node.parent += base }
                nodes.append(node)
            }
            merge(top.output, into: &output)

            let units = try await runUnits(top.output.deferred, root: root, options: options,
                                           progress: progress, hardLinks: hardLinks)
            try Task.checkCancellation()

            // Splice each unit's subtree under its placeholder and add its totals to every ancestor.
            for (unit, unitOutput) in units {
                let placeholder = base + unit.nodeIndex
                let offset = Int32(nodes.count) - 1
                for i in 1..<max(unitOutput.nodes.count, 1) {
                    var node = unitOutput.nodes[i]
                    node.parent = node.parent == 0 ? placeholder : node.parent + offset
                    nodes.append(node)
                }
                if let unitRoot = unitOutput.nodes.first {
                    var current = placeholder
                    while current >= 0 {
                        nodes[Int(current)].size += unitRoot.size
                        nodes[Int(current)].itemCount += unitRoot.itemCount
                        current = nodes[Int(current)].parent
                    }
                }
                merge(unitOutput, into: &output)
            }
        }

        try Task.checkCancellation()
        // Every location failed (missing volume, no permission): report it instead of an empty "0 bytes" scan.
        if unreadableRoots.count == roots.count {
            throw ScanError.nothingReadable(unreadableRoots)
        }
        progress.setPhase(.finalizing)

        let tree = FolderTree.build(from: nodes, keepMinimum: options.folderKeepMinimum)
        nodes = []

        var files = output.files
        for package in output.packages {
            guard let size = tree.size(ofPath: package.path), size >= options.trackedFileMinimum else { continue }
            files.append(FileRecord(path: package.path, size: size, logicalSize: size, modified: package.modified,
                                    accessed: package.accessed, lastUsed: nil, isPackage: true))
        }
        addKinds(&files)
        if options.readSpotlightDates { addLastUsedDates(&files) }

        var junk: [JunkHit] = []
        for var hit in output.junk {
            guard let size = tree.size(ofPath: hit.path), size > 0 else { continue }
            hit.size = size
            junk.append(hit)
        }

        return ScanResult(
            roots: roots, date: Date(), duration: Date().timeIntervalSince(start),
            itemsScanned: progress.snapshot.items, tree: tree, files: files,
            junkHits: junk, skipped: output.skipped.sorted { $0.path < $1.path })
    }

    /// Appends one walker's files, packages, junk hits and skipped paths to the combined output.
    private static func merge(_ source: WalkerOutput, into target: inout WalkerOutput) {
        target.files += source.files
        target.packages += source.packages
        target.junk += source.junk
        target.skipped += source.skipped
    }

    /// Runs deferred subtrees with bounded parallelism. Results come back in completion order.
    private static func runUnits(_ units: [DeferredUnit], root: String, options: ScanOptions,
                                 progress: ScanProgress, hardLinks: HardLinkRegistry) async throws -> [(DeferredUnit, WalkerOutput)] {
        guard !units.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (DeferredUnit, WalkerOutput).self) { group in
            var results: [(DeferredUnit, WalkerOutput)] = []
            results.reserveCapacity(units.count)
            var iterator = units.makeIterator()

            func addNext() -> Bool {
                guard let unit = iterator.next() else { return false }
                group.addTask {
                    try Task.checkCancellation()
                    let walker = SubtreeWalker(options: options, rootPath: root, progress: progress,
                                               hardLinks: hardLinks, splitDepth: nil)
                    walker.walk(path: unit.path, name: unit.name, parent: -1, kind: unit.kind, depth: 0, context: unit.context)
                    return (unit, walker.output)
                }
                return true
            }

            for _ in 0..<options.maxConcurrency where addNext() {}
            while let result = try await group.next() {
                results.append(result)
                _ = addNext()
            }
            return results
        }
    }

    /// Adds a human-readable kind ("MPEG-4 movie") to each tracked file. Cheap; done during the scan.
    static func addKinds(_ files: inout [FileRecord]) {
        for i in files.indices {
            files[i].kind = FileRecord.kindDescription(forPath: files[i].path, isPackage: files[i].isPackage)
        }
    }

    /// Adds Spotlight "last used" dates in parallel. Slower (one metadata query per file), so the app runs it
    /// after the results are already on screen.
    static func addLastUsedDates(_ files: inout [FileRecord]) {
        files.withUnsafeMutableBufferPointer { buffer in
            let records = buffer
            DispatchQueue.concurrentPerform(iterations: records.count) { i in
                records[i].lastUsed = SpotlightMetadata.lastUsedDate(forPath: records[i].path)
            }
        }
    }
}

enum SpotlightMetadata {
    static func lastUsedDate(forPath path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Measures a single path outside a full scan (apps, leftovers, locations outside the scan roots).
enum SizeCalculator {
    static func allocatedSize(ofPath path: String) -> Int64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        if (info.st_mode & S_IFMT) != S_IFDIR {
            return Int64(info.st_blocks) * 512
        }
        let lister = BulkDirectoryLister()
        var seen = Set<UInt64>()
        return directorySize(path, lister: lister, seenHardLinks: &seen)
    }

    private static func directorySize(_ path: String, lister: BulkDirectoryLister, seenHardLinks: inout Set<UInt64>) -> Int64 {
        var entries: [DirEntry] = []
        guard lister.list(path, into: &entries) == 0 else { return 0 }
        var total: Int64 = 0
        for entry in entries {
            switch entry.type {
            case .file:
                if entry.linkCount > 1 && !seenHardLinks.insert(entry.fileID).inserted { continue }
                total += entry.allocatedSize
            case .directory:
                total += directorySize(PathUtil.join(path, entry.name), lister: lister, seenHardLinks: &seenHardLinks)
            case .symlink:
                total += entry.allocatedSize
            case .other:
                break
            }
        }
        return total
    }
}
