import Foundation

/// Locations the scanner never enters.
enum SkipRules {
    /// OS-managed areas: the sealed system volume (and its firmlinked duplicates), swap, devices and other mounts.
    static let excludedPaths = [
        "/System", "/private/var/vm", "/dev", "/Volumes", "/Network", "/.vol", "/cores",
        "/private/var/db/uuidtext", "/private/var/db/diagnostics",
    ]
    /// Volume bookkeeping folders that exist at the root of every volume.
    static let excludedNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".MobileBackups", ".TemporaryItems",
    ]

    /// Returns a reason when `path` must not be scanned. Excluded prefixes don't apply when the scan root itself
    /// lives inside them (e.g. scanning "/Volumes/External" explicitly).
    static func exclusionReason(path: String, name: String, root: String) -> String? {
        if excludedNames.contains(name) {
            return "Volume metadata (skipped by design)"
        }
        for excluded in excludedPaths where PathUtil.isSameOrDescendant(path, of: excluded) {
            if PathUtil.isSameOrDescendant(root, of: excluded) { continue }
            return excluded == "/Volumes" ? "Other volume (add it as a scan location to include it)" : "Protected by macOS (skipped by design)"
        }
        return nil
    }
}

/// Folder extensions that Finder shows as a single document.
enum PackageRules {
    static let extensions: Set<String> = [
        "app", "bundle", "framework", "plugin", "kext", "appex", "xpc", "photoslibrary", "musiclibrary",
        "imovielibrary", "tvlibrary", "fcpbundle", "logicx", "band", "xcarchive", "sparsebundle",
        "pkg", "mpkg", "rtfd", "pages", "numbers", "key", "dSYM", "playground", "xcodeproj", "xcworkspace",
        "pvm", "vmwarevm", "utm", "lrlibrary", "lrdata", "aplibrary",
    ]

    static func isPackage(name: String) -> Bool {
        let ext = (name as NSString).pathExtension
        return !ext.isEmpty && extensions.contains(ext)
    }
}

/// Thread-safe live progress shared between scan workers and the UI, which polls `snapshot`.
final class ScanProgress: @unchecked Sendable {
    enum Phase: Sendable, Equatable {
        case scanning, finalizing
    }

    struct Snapshot: Sendable, Equatable {
        var items: Int64 = 0
        var bytes: Int64 = 0
        var currentPath = ""
        var phase: Phase = .scanning
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    func noteDirectory(_ path: String) {
        lock.lock(); state.currentPath = path; lock.unlock()
    }

    func add(items: Int, bytes: Int64) {
        lock.lock(); state.items += Int64(items); state.bytes += bytes; lock.unlock()
    }

    func setPhase(_ phase: Phase) {
        lock.lock(); state.phase = phase; lock.unlock()
    }
}

/// Ensures each hard-linked inode is counted once across all workers.
final class HardLinkRegistry: @unchecked Sendable {
    private struct Key: Hashable {
        let device: Int32
        let inode: UInt64
    }

    private let lock = NSLock()
    private var seen = Set<Key>()

    /// Returns true the first time an inode is seen.
    func claim(device: Int32, inode: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(Key(device: device, inode: inode)).inserted
    }
}
