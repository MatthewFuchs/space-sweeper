import AppKit
import Foundation

/// Removes items normally, and when that fails for lack of permission (apps owned by root or another user),
/// retries with administrator rights through the standard macOS password prompt instead of failing silently.
struct PrivilegedFallbackRemover: FileRemoving {
    var normal: FileRemoving = SystemFileRemover()
    var trashDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")

    func moveToTrash(_ url: URL) throws {
        do {
            try normal.moveToTrash(url)
        } catch where Self.isPermissionError(error) {
            let destination = Self.uniqueDestination(for: url, in: trashDirectory)
            // Move into the user's Trash (still recoverable), then hand ownership back to the user.
            let command = "/bin/mv \(Self.shellQuote(url.path)) \(Self.shellQuote(destination.path))"
                + " && /usr/sbin/chown -R \(getuid()) \(Self.shellQuote(destination.path))"
            try Self.runAsAdministrator(command)
        }
    }

    func removePermanently(_ url: URL) throws {
        do {
            try normal.removePermanently(url)
        } catch where Self.isPermissionError(error) {
            try Self.runAsAdministrator("/bin/rm -rf \(Self.shellQuote(url.path))")
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM))
    }

    /// "Foo.app" → "Foo.app", or "Foo 23.59.12.app" if the Trash already holds one.
    static func uniqueDestination(for url: URL, in directory: URL) -> URL {
        let candidate = directory.appendingPathComponent(url.lastPathComponent)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            .replacingOccurrences(of: ":", with: ".")
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        return directory.appendingPathComponent(ext.isEmpty ? "\(base) \(stamp)" : "\(base) \(stamp).\(ext)")
    }

    /// Single-quotes a path for /bin/sh.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for use inside an AppleScript string literal.
    static func appleScriptLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Runs a shell command as root after the standard macOS administrator prompt. Cancelling throws.
    static func runAsAdministrator(_ command: String) throws {
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        var errorInfo: NSDictionary?
        let run = {
            _ = NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        }
        // NSAppleScript must run on the main thread.
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? -1
            let message = code == -128 ? "Cancelled at the password prompt"
                : (errorInfo[NSAppleScript.errorMessage] as? String ?? "Administrator command failed")
            throw NSError(domain: "SpaceSweeper.Admin", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
