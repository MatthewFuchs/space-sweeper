import AppKit
import Foundation

/// Capacity of the volume that holds the home folder.
struct DiskInfo: Sendable, Equatable {
    var volumeName: String
    var total: Int64
    /// Free space as macOS reports it for important usage (includes purgeable space).
    var available: Int64
    var used: Int64 { max(0, total - available) }

    static func current(for path: String = NSHomeDirectory()) -> DiskInfo? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey,
        ]), let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return DiskInfo(volumeName: values.volumeLocalizedName ?? "Disk", total: Int64(total), available: available)
    }
}

/// Detects whether the app has Full Disk Access by opening files that TCC always protects.
enum FullDiskAccess {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func probePaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "\(home)/Library/Safari/CloudTabs.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
    }

    static func isGranted() -> Bool {
        for path in probePaths() {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        // None of the probe files exist: we can't tell, so don't block the user.
        return true
    }

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }
}
