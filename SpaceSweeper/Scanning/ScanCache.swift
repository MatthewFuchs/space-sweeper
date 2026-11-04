import Foundation

/// Persists the last scan so the app opens instantly with previous results.
struct ScanCache {
    let fileURL: URL

    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SpaceSweeper", isDirectory: true)
    }

    static let standard = ScanCache(fileURL: appSupportDirectory.appendingPathComponent("last-scan.json"))

    func save(_ result: ScanResult) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(result)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Returns nil when there is no cache or it was written by an incompatible version.
    func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: fileURL),
              let result = try? JSONDecoder().decode(ScanResult.self, from: data),
              result.version == ScanResult.currentVersion else { return nil }
        return result
    }
}
