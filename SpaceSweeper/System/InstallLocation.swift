import AppKit
import Foundation

/// Helps people who opened SpaceSweeper straight from Downloads or the disk image move it to Applications.
/// Running from Applications matters: macOS remembers Full Disk Access for the copy in Applications, and apps
/// opened from Downloads may run from a temporary "translocated" copy that loses permissions on every launch.
enum InstallLocation {
    /// UserDefaults key: the user chose "Not Now", so don't ask again.
    static let declinedKey = "moveToApplicationsDeclined"

    /// True when the app is running from somewhere a downloaded app shouldn't stay. Developer builds
    /// (e.g. Xcode's DerivedData) are left alone.
    static func needsMove(bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        if bundlePath.contains("/AppTranslocation/") { return true }
        let installed = ["/Applications", PathUtil.join(home, "Applications")]
        if installed.contains(where: { PathUtil.isSameOrDescendant(bundlePath, of: $0) }) { return false }
        // Only where a downloaded app lands. Documents/Desktop are left alone: developers build there.
        let temporary = ["/Volumes", PathUtil.join(home, "Downloads")]
        return temporary.contains { PathUtil.isSameOrDescendant(bundlePath, of: $0) }
    }

    /// Where the app ends up: /Applications/<name>.app.
    static func destination(for bundlePath: String) -> String {
        PathUtil.join("/Applications", (bundlePath as NSString).lastPathComponent)
    }

    /// Copies the app to /Applications (replacing an older copy, which goes to the Trash), asking for an
    /// administrator password only if needed. Returns the new location.
    static func copyToApplications(from bundlePath: String) throws -> String {
        let fm = FileManager.default
        let target = destination(for: bundlePath)
        do {
            if fm.fileExists(atPath: target) {
                try fm.trashItem(at: URL(fileURLWithPath: target), resultingItemURL: nil)
            }
            try fm.copyItem(atPath: bundlePath, toPath: target)
        } catch where PrivilegedFallbackRemover.isPermissionError(error) {
            // /Applications owned by an admin account: use the standard macOS password prompt.
            try PrivilegedFallbackRemover.runAsAdministrator(
                "/bin/rm -rf \(PrivilegedFallbackRemover.shellQuote(target)) && /usr/bin/ditto \(PrivilegedFallbackRemover.shellQuote(bundlePath)) \(PrivilegedFallbackRemover.shellQuote(target))")
        }
        return target
    }

    /// Opens the copy in Applications and quits this one. The downloaded copy is moved to the Trash when it
    /// can be (not when running from the read-only disk image or a translocated copy).
    @MainActor
    static func relaunch(from newPath: String, removing oldPath: String) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: newPath), configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                if !oldPath.contains("/AppTranslocation/") && !oldPath.hasPrefix("/Volumes/") {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: oldPath), resultingItemURL: nil)
                }
                NSApp.terminate(nil)
            }
        }
    }
}
