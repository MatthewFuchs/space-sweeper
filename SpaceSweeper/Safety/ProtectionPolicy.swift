import Foundation

/// Result of checking one path against the protection rules.
enum ProtectionVerdict: Hashable, Sendable {
    /// Safe to remove without extra warnings.
    case allowed
    /// Allowed, but the user should look twice (reasons are shown in the review sheet).
    case warning([String])
    /// Never removable; the reason is shown on a locked row.
    case locked(String)

    var isLocked: Bool {
        if case .locked = self { return true }
        return false
    }

    var warnings: [String] {
        if case .warning(let reasons) = self { return reasons }
        return []
    }
}

/// The built-in protection list. Pure and injectable (home, app path, clock) so it can be tested exhaustively.
struct ProtectionPolicy: Sendable {
    let home: String
    /// SpaceSweeper's own bundle, which must never be deleted.
    let appBundlePath: String
    var now: Date = Date()
    /// How recent a modification triggers the "recently modified" warning.
    var recentInterval: TimeInterval = 7 * 86_400
    /// Injectable only so tests can operate on temp fixtures (which live under /private/var). The app uses the default.
    var systemPrefixes: [String] = ProtectionPolicy.defaultSystemPrefixes

    /// System locations: the path itself, anything inside it, and anything containing it is locked.
    static let defaultSystemPrefixes = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var", "/tmp", "/cores", "/dev"]

    /// Home-relative locations holding credentials or irreplaceable data.
    static let homeProtected: [(relative: String, reason: String)] = [
        ("Library/Keychains", "Keychains (passwords and certificates)"),
        ("Library/Mobile Documents", "iCloud Drive"),
        (".ssh", "SSH keys"),
        ("Library/Mail", "Mail data"),
        ("Library/Containers/com.apple.mail", "Mail data"),
        ("Library/Group Containers/group.com.apple.mail", "Mail data"),
        ("Pictures/Photos Library.photoslibrary", "Photos library"),
    ]

    /// Folders macOS expects to exist: the folder itself is locked, its contents are not.
    static let homeStructureFolders = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Applications", "Public"]

    /// Contents of these get a "personal files" warning.
    static let personalFolders = ["Documents", "Desktop"]

    init(home: String = NSHomeDirectory(), appBundlePath: String = Bundle.main.bundlePath, now: Date = Date()) {
        self.home = home
        self.appBundlePath = appBundlePath
        self.now = now
    }

    /// Checks `path`. `modified` is the item's modification date when known (used for the 7-day warning).
    func verdict(for rawPath: String, modified: Date? = nil) -> ProtectionVerdict {
        let path = Self.standardize(rawPath)
        if let reason = lockReason(path) { return .locked(reason) }

        var warnings: [String] = []
        for folder in Self.personalFolders where PathUtil.isSameOrDescendant(path, of: PathUtil.join(home, folder)) {
            warnings.append("Inside your \(folder) folder")
        }
        if let modified, now.timeIntervalSince(modified) < recentInterval {
            warnings.append("Modified in the last \(recentDays) days")
        }
        return warnings.isEmpty ? .allowed : .warning(warnings)
    }

    private func lockReason(_ path: String) -> String? {
        // Exact top-level locations whose removal would break the system or the user account.
        let exact: [String: String] = [
            "/": "The startup disk", "/Applications": "The Applications folder", "/Users": "All user accounts",
            "/Volumes": "Mounted volumes", home: "Your home folder",
        ]
        if let reason = exact[path] { return reason }
        if path.hasPrefix("/Volumes/") && path.dropFirst("/Volumes/".count).split(separator: "/").count == 1 {
            return "A whole volume"
        }
        for folder in Self.homeStructureFolders where path == PathUtil.join(home, folder) {
            return "Your \(folder) folder (macOS expects it to exist)"
        }
        if PathUtil.isSameOrDescendant(home, of: path) {
            return "Contains your home folder"
        }

        for prefix in systemPrefixes {
            if PathUtil.isSameOrDescendant(path, of: prefix) { return "macOS system location (\(prefix))" }
        }
        for item in Self.homeProtected {
            let protected = PathUtil.join(home, item.relative)
            if PathUtil.isSameOrDescendant(path, of: protected) { return item.reason }
            if PathUtil.isSameOrDescendant(protected, of: path) { return "Contains \(item.reason)" }
        }
        if path.split(separator: "/").contains(where: { $0.hasSuffix(".photoslibrary") }) {
            return "Photos library"
        }
        let app = Self.standardize(appBundlePath)
        if PathUtil.isSameOrDescendant(path, of: app) || PathUtil.isSameOrDescendant(app, of: path) {
            return "SpaceSweeper itself"
        }
        return nil
    }

    /// The "recently modified" window in whole days, for messages.
    var recentDays: Int { max(1, Int((recentInterval / 86_400).rounded())) }

    /// Absolute path with "." / ".." removed and parent symlinks resolved (/var → /private/var).
    /// The last component is kept as-is: removing a symlink removes the link, not its target.
    static func standardize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard standardized != "/" else { return "/" }
        let parent = (standardized as NSString).deletingLastPathComponent
        let resolvedParent = URL(fileURLWithPath: parent).resolvingSymlinksInPath().path
        return PathUtil.join(resolvedParent, (standardized as NSString).lastPathComponent)
    }
}
