import Foundation
import UniformTypeIdentifiers

/// A file (or package such as an .app or .photoslibrary) large enough to be tracked individually.
struct FileRecord: Identifiable, Hashable, Codable, Sendable {
    var path: String
    /// Allocated bytes on disk.
    var size: Int64
    var logicalSize: Int64
    var modified: Date
    var accessed: Date
    /// Spotlight's kMDItemLastUsedDate, when known.
    var lastUsed: Date?
    var isPackage: Bool
    var kind: String = ""

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var url: URL { URL(fileURLWithPath: path) }
    /// Best estimate of when the file was last opened: Spotlight first, then the access time.
    var lastOpened: Date { lastUsed ?? accessed }
    /// Most recent of modified/opened, used for "old file" decisions.
    var lastActivity: Date { max(modified, lastOpened) }

    /// Extensions whose system description is misleading for large files (e.g. ".bin" is not a MacBinary archive).
    static let kindOverrides: [String: String] = ["bin": "Binary data", "raw": "Raw disk image", "img": "Disk image"]

    /// Human-readable kind ("MPEG-4 movie", "Disk Image") for the Kind column.
    static func kindDescription(forPath path: String, isPackage: Bool) -> String {
        let ext = (path as NSString).pathExtension
        if let override = kindOverrides[ext.lowercased()] { return override }
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription {
            return description
        }
        return isPackage ? "Package" : (ext.isEmpty ? "Document" : ext.uppercased() + " file")
    }
}

enum NodeKind: UInt8, Codable, Sendable {
    case root, directory, package, file, other
}

struct TreeNode: Codable, Sendable, Hashable {
    var name: String
    /// Index of the parent node, -1 for scan roots.
    var parent: Int32
    var size: Int64
    /// Number of files and folders inside (recursive).
    var itemCount: Int64
    var kind: NodeKind
    var children: [Int32] = []
}

/// Folder-size tree stored as a flat array. Folders smaller than the keep threshold are folded into an
/// "Other files" node of their parent; files above the tracking threshold appear as leaves.
struct FolderTree: Codable, Sendable {
    static let otherFilesName = "Other files"

    var nodes: [TreeNode] = []
    var rootIDs: [Int32] = []

    /// Builds the final tree from raw walker output: prunes small folders, adds "Other files" nodes,
    /// links children and sorts them largest first. Parents must precede children in `raw`.
    static func build(from raw: [TreeNode], keepMinimum: Int64) -> FolderTree {
        var newIndex = [Int32](repeating: -1, count: raw.count)
        var nodes: [TreeNode] = []
        nodes.reserveCapacity(raw.count / 4)
        for (i, node) in raw.enumerated() {
            let isRoot = node.parent < 0
            let parentKept = isRoot ? true : newIndex[Int(node.parent)] >= 0
            guard parentKept, isRoot || node.kind == .file || node.size >= keepMinimum else { continue }
            var copy = node
            copy.parent = isRoot ? -1 : newIndex[Int(node.parent)]
            copy.children = []
            newIndex[i] = Int32(nodes.count)
            nodes.append(copy)
        }
        for i in nodes.indices where nodes[i].parent >= 0 {
            nodes[Int(nodes[i].parent)].children.append(Int32(i))
        }
        let realCount = nodes.count
        for i in 0..<realCount where nodes[i].kind != .file && !nodes[i].children.isEmpty {
            let keptSum = nodes[i].children.reduce(Int64(0)) { $0 + nodes[Int($1)].size }
            let rest = nodes[i].size - keptSum
            if rest > 0 {
                let other = TreeNode(name: otherFilesName, parent: Int32(i), size: rest, itemCount: 0, kind: .other)
                nodes[i].children.append(Int32(nodes.count))
                nodes.append(other)
            }
        }
        for i in nodes.indices where nodes[i].children.count > 1 {
            var children = nodes[i].children
            children.sort { nodes[Int($0)].size > nodes[Int($1)].size }
            nodes[i].children = children
        }
        let roots = nodes.indices.filter { nodes[$0].parent < 0 }.map { Int32($0) }
        return FolderTree(nodes: nodes, rootIDs: roots)
    }

    func path(of id: Int32) -> String {
        var components: [String] = []
        var current = id
        while current >= 0 {
            let node = nodes[Int(current)]
            if node.parent < 0 { return ([node.name] + components.reversed()).joined(separator: "/").replacingOccurrences(of: "//", with: "/") }
            components.append(node.name)
            current = node.parent
        }
        return components.reversed().joined(separator: "/")
    }

    /// Finds the node for an absolute path, or nil when it was pruned (smaller than the keep threshold) or not scanned.
    func index(ofPath path: String) -> Int32? {
        guard let root = rootIDs
            .filter({ PathUtil.isSameOrDescendant(path, of: nodes[Int($0)].name) })
            .max(by: { nodes[Int($0)].name.count < nodes[Int($1)].name.count }) else { return nil }
        let rootPath = nodes[Int(root)].name
        if path == rootPath { return root }
        let remainder = rootPath == "/" ? String(path.dropFirst()) : String(path.dropFirst(rootPath.count + 1))
        var current = root
        for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = nodes[Int(current)].children.first(where: {
                let child = nodes[Int($0)]
                return child.kind != .other && child.name == component
            }) else { return nil }
            current = next
        }
        return current
    }

    func size(ofPath path: String) -> Int64? {
        index(ofPath: path).map { nodes[Int($0)].size }
    }

    var totalSize: Int64 { rootIDs.reduce(0) { $0 + nodes[Int($1)].size } }

    /// Removes a deleted item: subtracts its size from all ancestors and detaches it.
    mutating func remove(path: String) {
        guard let id = index(ofPath: path), nodes[Int(id)].parent >= 0 else { return }
        let size = nodes[Int(id)].size
        let count = nodes[Int(id)].itemCount
        let parent = nodes[Int(id)].parent
        nodes[Int(parent)].children.removeAll { $0 == id }
        var current = parent
        while current >= 0 {
            nodes[Int(current)].size -= size
            nodes[Int(current)].itemCount -= count
            current = nodes[Int(current)].parent
        }
    }
}

/// A folder that couldn't be (or deliberately wasn't) scanned.
struct SkippedPath: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var reason: String
    var id: String { path }

    static func describe(errno code: Int32) -> String {
        switch code {
        case EACCES, EPERM: return "Permission denied"
        case ENOENT: return "Disappeared during scan"
        case ELOOP: return "Symbolic link (not followed)"
        case ENOTDIR: return "Not a folder"
        default: return String(cString: strerror(code))
        }
    }
}

/// A regenerable developer folder detected by name during the walk.
struct JunkHit: Codable, Hashable, Sendable {
    var path: String
    var kind: PatternJunkKind
    var size: Int64
    var modified: Date
}

struct ScanResult: Codable, Sendable {
    static let currentVersion = 1

    var version = ScanResult.currentVersion
    var roots: [String]
    var date: Date
    var duration: TimeInterval
    var itemsScanned: Int64
    var tree: FolderTree
    var files: [FileRecord]
    var junkHits: [JunkHit]
    var skipped: [SkippedPath]

    var totalSize: Int64 { tree.totalSize }

    /// Updates the cached results after items were removed from disk.
    mutating func removeItems(atPaths paths: [String]) {
        for path in paths {
            tree.remove(path: path)
            files.removeAll { PathUtil.isSameOrDescendant($0.path, of: path) }
            junkHits.removeAll { PathUtil.isSameOrDescendant($0.path, of: path) }
        }
    }
}
