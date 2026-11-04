import Foundation
import Darwin

struct ScanOptions: Sendable {
    var roots: [String]
    var homePath: String = NSHomeDirectory()
    /// Files at least this large get an individual record (Large/Old Files views).
    var trackedFileMinimum: Int64 = 10 * MB
    /// Folders smaller than this are folded into their parent's "Other files" node.
    var folderKeepMinimum: Int64 = 1 * MB
    /// Directories at this depth below a root are scanned as independent parallel units. nil = sequential.
    var splitDepth: Int? = 2
    var maxConcurrency: Int = max(2, min(ProcessInfo.processInfo.activeProcessorCount - 2, 8))
    var useBulkAPI = true
    /// Read Spotlight "last used" dates during the scan. The app turns this off and loads them afterwards,
    /// so results appear sooner.
    var readSpotlightDates = true
}

struct WalkContext: Sendable {
    var insidePackage = false
    var insideJunk = false
}

/// A subtree whose walk was deferred to a parallel worker.
struct DeferredUnit: Sendable {
    let path: String
    let name: String
    let nodeIndex: Int32
    let kind: NodeKind
    let context: WalkContext
}

/// A package (.app, .photoslibrary, …) seen during the walk; its size is resolved from the tree afterwards.
struct PackageHit: Sendable {
    let path: String
    let modified: Date
    let accessed: Date
}

struct WalkerOutput: Sendable {
    var nodes: [TreeNode] = []
    var files: [FileRecord] = []
    var packages: [PackageHit] = []
    var junk: [JunkHit] = []
    var skipped: [SkippedPath] = []
    var deferred: [DeferredUnit] = []
}

/// Depth-first walker for one subtree. Single-threaded; the scanner runs many of these in parallel.
final class SubtreeWalker {
    private let options: ScanOptions
    private let rootPath: String
    private let progress: ScanProgress
    private let hardLinks: HardLinkRegistry
    private let splitDepth: Int?
    private let lister: DirectoryLister

    private(set) var output = WalkerOutput()

    init(options: ScanOptions, rootPath: String, progress: ScanProgress, hardLinks: HardLinkRegistry, splitDepth: Int?) {
        self.options = options
        self.rootPath = rootPath
        self.progress = progress
        self.hardLinks = hardLinks
        self.splitDepth = splitDepth
        self.lister = options.useBulkAPI ? BulkDirectoryLister() : FoundationDirectoryLister()
    }

    /// Walks `path`, appending its node (with `parent`) and all kept descendants. Returns the subtree's
    /// allocated size and item count. Deferred children contribute 0 until the scanner splices them in.
    @discardableResult
    func walk(path: String, name: String, parent: Int32, kind: NodeKind, depth: Int, context: WalkContext) -> (size: Int64, count: Int64) {
        let index = Int32(output.nodes.count)
        output.nodes.append(TreeNode(name: name, parent: parent, size: 0, itemCount: 0, kind: kind))
        if Task.isCancelled { return (0, 0) }

        progress.noteDirectory(path)
        var entries: [DirEntry] = []
        let error = lister.list(path, into: &entries)
        if error != 0 {
            output.skipped.append(SkippedPath(path: path, reason: SkippedPath.describe(errno: error)))
            return (0, 0)
        }

        var total: Int64 = 0
        var count: Int64 = 0
        var directBytes: Int64 = 0
        var siblingNames: Set<String>?

        for entry in entries {
            let childPath = PathUtil.join(path, entry.name)
            switch entry.type {
            case .file:
                var size = entry.allocatedSize
                if entry.linkCount > 1 && !hardLinks.claim(device: entry.device, inode: entry.fileID) {
                    size = 0
                }
                total += size
                directBytes += size
                count += 1
                if size >= options.trackedFileMinimum {
                    output.nodes.append(TreeNode(name: entry.name, parent: index, size: size, itemCount: 1, kind: .file))
                    if !context.insidePackage {
                        output.files.append(FileRecord(
                            path: childPath, size: size, logicalSize: entry.logicalSize,
                            modified: Date(timeIntervalSince1970: entry.modified),
                            accessed: Date(timeIntervalSince1970: entry.accessed),
                            lastUsed: nil, isPackage: false))
                    }
                }

            case .directory:
                count += 1
                if let reason = SkipRules.exclusionReason(path: childPath, name: entry.name, root: rootPath) {
                    output.skipped.append(SkippedPath(path: childPath, reason: reason))
                    continue
                }
                if entry.flags & UInt32(SF_DATALESS) != 0 {
                    output.skipped.append(SkippedPath(path: childPath, reason: "Cloud placeholder, not downloaded (skipped to avoid downloading it)"))
                    continue
                }
                var childContext = context
                let isPackage = !context.insidePackage && PackageRules.isPackage(name: entry.name)
                if isPackage {
                    childContext.insidePackage = true
                    output.packages.append(PackageHit(
                        path: childPath,
                        modified: Date(timeIntervalSince1970: entry.modified),
                        accessed: Date(timeIntervalSince1970: entry.accessed)))
                }
                if !context.insidePackage, !context.insideJunk, DevJunkRules.candidateNames.contains(entry.name) {
                    if siblingNames == nil { siblingNames = Set(entries.map(\.name)) }
                    if let junkKind = DevJunkRules.classify(directoryName: entry.name, parentPath: path,
                                                            siblings: siblingNames ?? [], home: options.homePath) {
                        output.junk.append(JunkHit(path: childPath, kind: junkKind, size: 0,
                                                   modified: Date(timeIntervalSince1970: entry.modified)))
                        childContext.insideJunk = true
                    }
                }
                let childKind: NodeKind = isPackage ? .package : .directory

                if let split = splitDepth, depth + 1 >= split {
                    let placeholder = Int32(output.nodes.count)
                    output.nodes.append(TreeNode(name: entry.name, parent: index, size: 0, itemCount: 0, kind: childKind))
                    output.deferred.append(DeferredUnit(path: childPath, name: entry.name, nodeIndex: placeholder,
                                                        kind: childKind, context: childContext))
                    continue
                }

                let mark = output.nodes.count
                let child = walk(path: childPath, name: entry.name, parent: index, kind: childKind,
                                 depth: depth + 1, context: childContext)
                total += child.size
                count += child.count
                // Prune small folders as we go to keep memory flat. Never in split mode: placeholders hold indices.
                if splitDepth == nil && child.size < options.folderKeepMinimum {
                    output.nodes.removeSubrange(mark...)
                }

            case .symlink:
                // Never followed; only the link itself counts.
                total += entry.allocatedSize
                count += 1

            case .other:
                count += 1
            }
        }

        progress.add(items: entries.count, bytes: directBytes)
        output.nodes[Int(index)].size = total
        output.nodes[Int(index)].itemCount = count
        return (total, count)
    }
}
