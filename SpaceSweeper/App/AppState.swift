import AppKit
import Foundation
import Observation

/// Central app model. Lives on the main actor; heavy work runs in detached tasks.
@MainActor
@Observable
final class AppState {
    // MARK: Scan results & progress
    var result: ScanResult?
    private(set) var isScanning = false
    private(set) var scanStart: Date?
    private(set) var progress = ScanProgress.Snapshot()
    var scanError: String?

    // MARK: Environment
    var disk: DiskInfo? = DiskInfo.current()
    var hasFullDiskAccess = FullDiskAccess.isGranted()
    var fullDiskAccessDismissed = UserDefaults.standard.bool(forKey: "fullDiskAccessDismissed") {
        didSet { UserDefaults.standard.set(fullDiskAccessDismissed, forKey: "fullDiskAccessDismissed") }
    }

    /// Folders to scan. Defaults to the home folder.
    var scanRoots: [String] {
        didSet { UserDefaults.standard.set(scanRoots, forKey: "scanRoots") }
    }

    let homePath = NSHomeDirectory()
    private let cache: ScanCache
    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(cache: ScanCache = .standard) {
        self.cache = cache
        scanRoots = UserDefaults.standard.stringArray(forKey: "scanRoots") ?? [NSHomeDirectory()]
        loadCache()
    }

    // MARK: Cache

    private func loadCache() {
        let cache = self.cache
        Task.detached(priority: .userInitiated) {
            let cached = cache.load()
            await MainActor.run {
                if self.result == nil { self.result = cached }
            }
        }
    }

    // MARK: Scanning

    func startScan() {
        guard !isScanning else { return }
        let progress = ScanProgress()
        let options = ScanOptions(roots: scanRoots, homePath: homePath)
        let cache = self.cache
        isScanning = true
        scanError = nil
        scanStart = Date()
        self.progress = ScanProgress.Snapshot()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.progress = progress.snapshot
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await FileScanner.scan(options: options, progress: progress)
                try? cache.save(result)
                await self?.finishScan(result: result, error: nil)
            } catch is CancellationError {
                await self?.finishScan(result: nil, error: nil)
            } catch {
                await self?.finishScan(result: nil, error: error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func finishScan(result: ScanResult?, error: String?) {
        pollTask?.cancel()
        pollTask = nil
        scanTask = nil
        isScanning = false
        if let result { self.result = result }
        scanError = error
        refreshDisk()
    }

    func refreshDisk() {
        disk = DiskInfo.current()
    }

    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: Scan locations

    func addScanRoots(_ urls: [URL]) {
        let added = urls.map { PathUtil.normalize($0.path) }
        scanRoots = PathUtil.dedupedRoots(scanRoots + added)
    }

    func removeScanRoot(_ path: String) {
        scanRoots.removeAll { $0 == path }
        if scanRoots.isEmpty { scanRoots = [homePath] }
    }

    // MARK: Finder helpers

    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
