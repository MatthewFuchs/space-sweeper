import AppKit
import CoreServices
import Foundation
import Observation

/// An installed application bundle.
struct AppInfo: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var bundleID: String?
    var version: String?
    /// Allocated size of the bundle; nil until measured.
    var size: Int64?
    var lastUsed: Date?
    /// Why the app can't be uninstalled (Apple system app, SpaceSweeper itself), or nil.
    var protectionReason: String?
    /// Bundle owned by another user or root: removal needs an administrator password.
    var needsAdmin = false

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    /// Sort keys for the table (unknown values sort last when descending).
    var sizeSortKey: Int64 { size ?? -1 }
    var lastUsedSortKey: Date { lastUsed ?? .distantPast }
}

/// Finds and describes installed apps. Stateless and usable from any thread.
enum AppScanner {
    static func defaultFolders(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", PathUtil.join(home, "Applications")]
    }

    /// .app bundles directly inside `folders` or one level down (e.g. /Applications/Utilities/X.app).
    /// Symlinks (like the cryptex-backed Safari) are skipped.
    static func findApps(in folders: [String], ownBundlePath: String = Bundle.main.bundlePath,
                         ownBundleID: String? = Bundle.main.bundleIdentifier) -> [AppInfo] {
        var apps: [AppInfo] = []
        let fm = FileManager.default
        for folder in folders {
            for name in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = PathUtil.join(folder, name)
                guard !isSymlink(path) else { continue }
                if name.hasSuffix(".app") {
                    if let app = appInfo(at: path, ownBundlePath: ownBundlePath, ownBundleID: ownBundleID) { apps.append(app) }
                } else if isDirectory(path) {
                    for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        let innerPath = PathUtil.join(path, inner)
                        guard !isSymlink(innerPath),
                              let app = appInfo(at: innerPath, ownBundlePath: ownBundlePath, ownBundleID: ownBundleID) else { continue }
                        apps.append(app)
                    }
                }
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Reads name, bundle ID and version from Info.plist and decides whether the app is protected.
    static func appInfo(at path: String, ownBundlePath: String = Bundle.main.bundlePath,
                        ownBundleID: String? = Bundle.main.bundleIdentifier) -> AppInfo? {
        let plistPath = PathUtil.join(path, "Contents/Info.plist")
        let info = NSDictionary(contentsOfFile: plistPath) as? [String: Any] ?? [:]
        let bundleID = info["CFBundleIdentifier"] as? String
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? fileName
        let version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        var app = AppInfo(path: path, name: name.isEmpty ? fileName : name, bundleID: bundleID, version: version)
        app.protectionReason = protectionReason(path: path, bundleID: bundleID, ownBundlePath: ownBundlePath, ownBundleID: ownBundleID)

        var status = stat()
        if lstat(path, &status) == 0 {
            app.needsAdmin = status.st_uid != getuid()
        }
        return app
    }

    /// Apple system apps (under /System or SIP-restricted) and SpaceSweeper itself can't be uninstalled.
    static func protectionReason(path: String, bundleID: String?, ownBundlePath: String, ownBundleID: String?) -> String? {
        if PathUtil.isSameOrDescendant(path, of: "/System") {
            return "Apple system app"
        }
        var status = stat()
        if lstat(path, &status) == 0 && (status.st_flags & UInt32(SF_RESTRICTED)) != 0 {
            return "Apple system app (protected by macOS)"
        }
        if PathUtil.normalize(path) == PathUtil.normalize(ownBundlePath) || (bundleID != nil && bundleID == ownBundleID) {
            return "This is SpaceSweeper"
        }
        return nil
    }

    static func lastUsedDate(_ path: String) -> Date? {
        SpotlightMetadata.lastUsedDate(forPath: path)
    }

    private static func isSymlink(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isDirectory(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Observable list of installed apps; sizes and last-used dates fill in progressively.
@MainActor
@Observable
final class AppInventory {
    private(set) var apps: [AppInfo] = []
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?

    /// (Re)loads the app list, then measures bundle sizes in the background with limited parallelism.
    func load(folders: [String] = AppScanner.defaultFolders()) {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                AppScanner.findApps(in: folders).map { app -> AppInfo in
                    var app = app
                    app.lastUsed = AppScanner.lastUsedDate(app.path)
                    return app
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.apps = found
            await self.measureSizes(of: found.map(\.path))
            self.isLoading = false
        }
    }

    /// Measures bundle sizes four at a time and updates rows as each finishes.
    private func measureSizes(of paths: [String]) async {
        await withTaskGroup(of: (String, Int64).self) { group in
            var iterator = paths.makeIterator()
            func addNext() -> Bool {
                guard let path = iterator.next() else { return false }
                group.addTask(priority: .utility) { (path, SizeCalculator.allocatedSize(ofPath: path)) }
                return true
            }
            for _ in 0..<4 where addNext() {}
            for await (path, size) in group {
                if let index = apps.firstIndex(where: { $0.path == path }) {
                    apps[index].size = size
                }
                if Task.isCancelled { group.cancelAll(); return }
                _ = addNext()
            }
        }
    }

    /// Removes apps from the list after they were uninstalled.
    func remove(paths: Set<String>) {
        apps.removeAll { paths.contains($0.path) }
    }
}
