import AppKit
import Foundation
import Observation

/// Central app model. Lives on the main actor; heavy work runs in detached tasks.
@MainActor
@Observable
final class AppState {
    // MARK: Scan results & progress

    /// The latest scan (from cache at launch, then from each rescan). Derived lists are recomputed on change.
    var result: ScanResult? {
        didSet { recomputeDerivedData() }
    }
    private(set) var isScanning = false
    private(set) var scanStart: Date?
    private(set) var progress = ScanProgress.Snapshot()
    var scanError: String?

    // MARK: Derived data

    /// Developer Junk entries for the current result, measured off the main thread.
    private(set) var junkItems: [DevJunkItem] = []
    private(set) var isComputingJunk = false
    private(set) var reclaimable = ReclaimableEstimate()
    private var junkTask: Task<Void, Never>?

    /// Installed applications (loaded on first visit to the Applications view).
    let apps = AppInventory()

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

    /// Starts a background scan of `scanRoots`. Progress is polled 10×/s so the UI never floods.
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

    /// Cancels the running scan; partial results are discarded and the previous result is kept.
    func cancelScan() {
        scanTask?.cancel()
    }

    /// Called on the main actor when a scan ends, successfully or not.
    private func finishScan(result: ScanResult?, error: String?) {
        pollTask?.cancel()
        pollTask = nil
        scanTask = nil
        isScanning = false
        if let result { self.result = result }
        scanError = error
        refreshDisk()
    }

    /// Rebuilds the Developer Junk list and reclaimable estimate in the background.
    private func recomputeDerivedData() {
        junkTask?.cancel()
        guard let result else {
            junkItems = []
            reclaimable = ReclaimableEstimate()
            return
        }
        isComputingJunk = true
        let home = homePath
        junkTask = Task { [weak self] in
            let (items, estimate) = await Task.detached(priority: .utility) {
                let items = DevJunkCatalog(result: result, home: home).items()
                let old = FileFilters.oldFiles(result.files, olderThanMonths: 12, minimumSize: 50 * MB)
                return (items, OverviewCalculator.reclaimable(junk: items, oldFiles: old))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.junkItems = items
            self.reclaimable = estimate
            self.isComputingJunk = false
        }
    }

    /// Re-reads free space for the home volume.
    func refreshDisk() {
        disk = DiskInfo.current()
    }

    /// Re-checks Full Disk Access (called when the app becomes active, e.g. back from System Settings).
    func refreshFullDiskAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted()
    }

    // MARK: Scan locations

    /// Adds folders/volumes chosen in the open panel, dropping any already covered by another root.
    func addScanRoots(_ urls: [URL]) {
        let added = urls.map { PathUtil.normalize($0.path) }
        scanRoots = PathUtil.dedupedRoots(scanRoots + added)
    }

    /// Removes a scan location; falls back to the home folder so there is always one root.
    func removeScanRoot(_ path: String) {
        scanRoots.removeAll { $0 == path }
        if scanRoots.isEmpty { scanRoots = [homePath] }
    }

    // MARK: Removal (implemented in later stages)

    /// Whether list views should offer "Move to Trash…". Enabled once deletion is implemented.
    var deletionEnabled: Bool { false }
    var uninstallEnabled: Bool { false }
    func requestDeletion(paths: [String]) {}
    func requestUninstall(_ apps: [AppInfo]) {}

    // MARK: Finder helpers

    /// Selects the items in a Finder window.
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
