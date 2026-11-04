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

    /// Rates paths for deletion safety, using the current Developer Junk list for known-regenerable folders.
    var safetyAdvisor: SafetyAdvisor {
        SafetyAdvisor(policy: ProtectionPolicy(home: homePath), junkItems: junkItems)
    }

    // MARK: Navigation

    /// Selected sidebar section; lives here so other views (e.g. Overview quick wins) can navigate.
    var selectedSection: SidebarItem = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "selectedSection") ?? "") ?? .overview {
        didSet { UserDefaults.standard.set(selectedSection.rawValue, forKey: "selectedSection") }
    }

    // MARK: Deletion state

    /// The pending review sheet; nothing is removed until the user confirms it.
    var review: ReviewRequest?
    /// Result of the last deletion, shown in a summary sheet.
    var outcome: DeletionOutcome?
    private(set) var isDeleting = false
    let activityLog: ActivityLog
    private(set) var activityEntries: [ActivityEntry] = []

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

    init(cache: ScanCache = .standard, activityLog: ActivityLog = .standard) {
        self.cache = cache
        self.activityLog = activityLog
        activityEntries = activityLog.entries
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

    // MARK: Deletion

    var deletionEnabled: Bool { true }
    var uninstallEnabled: Bool { true }
    /// True while leftovers are being searched for, before the review sheet opens.
    private(set) var isPreparingUninstall = false

    /// Finds each app's leftovers off the main thread, then opens the review sheet (app bundle + leftover checklist).
    func requestUninstall(_ apps: [AppInfo]) {
        let removable = apps.filter { $0.protectionReason == nil }
        guard !removable.isEmpty, !isPreparingUninstall else { return }
        isPreparingUninstall = true
        let home = homePath
        Task { [weak self] in
            let items = await Task.detached(priority: .userInitiated) { () -> [DeletionItem] in
                let policy = ProtectionPolicy(home: home)
                let finder = LeftoverFinder(home: home)
                return removable.flatMap { app in
                    UninstallPlanner.items(for: app, leftovers: finder.find(for: app), policy: policy)
                }
            }.value
            guard let self else { return }
            self.isPreparingUninstall = false
            let title = removable.count == 1 ? "Uninstall \(removable[0].name)" : "Uninstall \(removable.count) apps"
            self.review = ReviewRequest(title: title, kind: .uninstall(apps: removable), items: items)
        }
    }

    /// Builds the review sheet for `paths`. Sizes come from the scan when available.
    func requestDeletion(paths: [String]) {
        let items = paths.map(makeDeletionItem)
        guard !items.isEmpty else { return }
        review = ReviewRequest(title: "Review \(items.count) item\(items.count == 1 ? "" : "s")", kind: .files, items: items)
    }

    /// Size, protection verdict, safety rating and owning apps for one path.
    func makeDeletionItem(path: String) -> DeletionItem {
        var status = stat()
        let modified = lstat(path, &status) == 0
            ? Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)) : nil
        let junk = junkItems.first { $0.path == path }
        let size = result?.files.first { $0.path == path }?.size
            ?? junk?.size
            ?? result?.tree.size(ofPath: path)
            ?? SizeCalculator.allocatedSize(ofPath: path)
        let policy = ProtectionPolicy(home: homePath)
        let owners = Set((junk?.ownerBundleIDs ?? []) + RunningAppGuard.ownerBundleIDs(forPath: path, home: homePath))
        return DeletionItem(path: path, size: size, verdict: policy.verdict(for: path, modified: modified),
                            ownerBundleIDs: owners.sorted(),
                            safety: safetyAdvisor.assess(path: path, modified: modified))
    }

    /// Removes the confirmed items off the main thread, then updates results, free space and the log.
    func performDeletion(_ request: ReviewRequest, mode: DeletionMode) {
        guard !isDeleting else { return }
        review = nil
        isDeleting = true
        let items = request.items
        var context: String?
        var remover: FileRemoving = SystemFileRemover()
        if case .uninstall(let apps) = request.kind {
            context = "Uninstall " + apps.map(\.name).joined(separator: ", ")
            // Apps owned by root or another user need the administrator prompt instead of failing silently.
            remover = PrivilegedFallbackRemover()
        }
        let service = DeletionService(policy: ProtectionPolicy(home: homePath), remover: remover, log: activityLog)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                service.perform(items, mode: mode, context: context)
            }.value
            self?.finishDeletion(outcome)
        }
    }

    private func finishDeletion(_ outcome: DeletionOutcome) {
        isDeleting = false
        let removedPaths = outcome.removed.map(\.path)
        if var updated = result, !removedPaths.isEmpty {
            updated.removeItems(atPaths: removedPaths)
            result = updated
            let cache = self.cache
            Task.detached(priority: .utility) { try? cache.save(updated) }
        }
        apps.remove(paths: Set(removedPaths))
        activityEntries = activityLog.entries
        refreshDisk()
        self.outcome = outcome
    }

    // MARK: Finder helpers

    /// Selects the items in a Finder window.
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
