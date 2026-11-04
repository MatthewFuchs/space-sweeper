import Foundation

/// One removed item in the activity log.
struct ActivityEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var path: String
    var size: Int64
    var action: DeletionMode
    /// Optional context, e.g. "Uninstall Slack".
    var context: String?
}

/// Append-only history of everything SpaceSweeper removed, persisted as JSON. Thread-safe.
final class ActivityLog: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()
    private var cached: [ActivityEntry]?

    static let standard = ActivityLog(fileURL: ScanCache.appSupportDirectory.appendingPathComponent("activity-log.json"))

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// All entries, newest first.
    var entries: [ActivityEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().sorted { $0.date > $1.date }
    }

    func append(_ newEntries: [ActivityEntry]) {
        guard !newEntries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all += newEntries
        cached = all
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("SpaceSweeper: could not save activity log: \(error)")
        }
    }

    /// Removes all history (Settings › Privacy).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        cached = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadLocked() -> [ActivityEntry] {
        if let cached { return cached }
        let loaded = (try? Data(contentsOf: fileURL)).flatMap { try? JSONDecoder().decode([ActivityEntry].self, from: $0) } ?? []
        cached = loaded
        return loaded
    }

    /// CSV with an ISO-8601 date, action, size in bytes and readable size, path and context.
    static func csv(_ entries: [ActivityEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = ["Date,Action,Size (bytes),Size,Path,Context"]
        for entry in entries {
            let fields = [
                formatter.string(from: entry.date), entry.action.logLabel, String(entry.size),
                entry.size.formattedBytes, entry.path, entry.context ?? "",
            ]
            lines.append(fields.map(escapeCSV).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes a field when it contains a comma, quote or newline (RFC 4180).
    static func escapeCSV(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
