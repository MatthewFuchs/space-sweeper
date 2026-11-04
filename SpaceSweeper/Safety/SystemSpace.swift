import Foundation

/// What's in the user's Trash (~/.Trash). Reading it needs Full Disk Access.
struct TrashInfo: Equatable, Sendable {
    /// Top-level items in the Trash.
    var items: [String]
    var size: Int64

    /// Measures the Trash folder; nil when it can't be read (usually missing Full Disk Access).
    static func measure(trashPath: String = PathUtil.join(NSHomeDirectory(), ".Trash")) -> TrashInfo? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else { return nil }
        let items = names.filter { $0 != ".DS_Store" && $0 != ".localized" }.map { PathUtil.join(trashPath, $0) }
        let size = items.reduce(Int64(0)) { $0 + SizeCalculator.allocatedSize(ofPath: $1) }
        return TrashInfo(items: items, size: size)
    }
}

/// Explains the part of "used" space the scan can't attribute to folders.
struct SystemSpaceInfo: Equatable, Sendable {
    /// Space macOS counts as available for important use but hasn't freed yet (caches, snapshots it can thin).
    var purgeable: Int64
    /// Dates of Time Machine local snapshots on the startup disk.
    var snapshotDates: [Date]

    static func measure(volume: String = "/") -> SystemSpaceInfo {
        SystemSpaceInfo(purgeable: purgeableBytes(volume: volume), snapshotDates: localSnapshotDates(volume: volume))
    }

    /// "Important" capacity minus plain free capacity.
    static func purgeableBytes(volume: String) -> Int64 {
        guard let values = try? URL(fileURLWithPath: volume).resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]), let free = values.volumeAvailableCapacity, let important = values.volumeAvailableCapacityForImportantUsage else {
            return 0
        }
        return max(0, important - Int64(free))
    }

    /// Runs `tmutil listlocalsnapshots` (no admin rights needed) and parses the snapshot dates.
    static func localSnapshotDates(volume: String) -> [Date] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return parseSnapshotList(output)
    }

    /// Parses lines like "com.apple.TimeMachine.2026-11-03-120000.local".
    static func parseSnapshotList(_ output: String) -> [Date] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return output.split(separator: "\n").compactMap { line -> Date? in
            guard let range = line.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
            return formatter.date(from: String(line[range]))
        }
        .sorted()
    }

    /// Deletes all local snapshots on the volume. Requires an administrator password (standard macOS prompt).
    static func deleteLocalSnapshots(volume: String = "/") throws {
        try PrivilegedFallbackRemover.runAsAdministrator("/usr/bin/tmutil deletelocalsnapshots \(PrivilegedFallbackRemover.shellQuote(volume))")
    }
}
