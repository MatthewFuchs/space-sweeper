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

    /// Outcome of reading the cache, so the UI can tell "no scan yet" from "saved results are damaged".
    enum LoadResult {
        case missing
        case loaded(ScanResult)
        /// Written by a different app version; a rescan replaces it.
        case outdated
        case unreadable(String)
    }

    func loadResult() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            let result = try JSONDecoder().decode(ScanResult.self, from: data)
            return result.version == ScanResult.currentVersion ? .loaded(result) : .outdated
        } catch is DecodingError {
            return .outdated
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// The cached result, or nil when missing, outdated or unreadable.
    func load() -> ScanResult? {
        if case .loaded(let result) = loadResult() { return result }
        return nil
    }
}
