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
        SafetyAdvisor(policy: settings.protectionPolicy(home: homePath), junkItems: junkItems)
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

    // MARK: Trash & system space

    /// Contents of ~/.Trash; nil until measured or when it can't be read (needs Full Disk Access).
    private(set) var trash: TrashInfo?
    /// Purgeable space and Time Machine local snapshots.
    private(set) var systemSpace: SystemSpaceInfo?
    private(set) var isEmptyingTrash = false

    /// Re-measures the Trash and system space in the background.
    func refreshSystemSpace() {
        Task { [weak self] in
            let (trash, system) = await Task.detached(priority: .utility) {
                (TrashInfo.measure(), SystemSpaceInfo.measure())
            }.value
            self?.trash = trash
            self?.systemSpace = system
        }
    }

    /// Permanently removes everything in the Trash (after the user confirmed), logging each item.
    func emptyTrash() {
        guard let trash, !trash.items.isEmpty, !isEmptyingTrash else { return }
        isEmptyingTrash = true
        let items = trash.items.map { DeletionItem(path: $0, size: SizeCalculator.allocatedSize(ofPath: $0), verdict: .allowed) }
        let service = DeletionService(policy: settings.protectionPolicy(home: homePath), log: activityLog)
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                service.perform(items, mode: .permanent, context: "Emptied Trash")
            }.value
            guard let self else { return }
            self.isEmptyingTrash = false
            self.activityEntries = self.activityLog.entries
            self.refreshDisk()
            self.refreshSystemSpace()
            self.outcome = outcome
        }
    }

    /// Deletes Time Machine local snapshots via the administrator prompt.
    func deleteLocalSnapshots() {
        Task { [weak self] in
            do {
                try await Task.detached { try SystemSpaceInfo.deleteLocalSnapshots() }.value
                self?.showNotice(AppNotice(kind: .info, title: "Local snapshots deleted",
                                           message: "macOS may take a minute to report the freed space."))
            } catch {
                self?.showNotice(AppNotice(kind: .warning, title: "Snapshots weren't deleted", message: error.localizedDescription))
            }
            self?.refreshDisk()
            self?.refreshSystemSpace()
        }
    }

    // MARK: Security Check

    private(set) var securityFindings: [SecurityFinding] = []
    private(set) var isCheckingSecurity = false
    private(set) var lastSecurityCheck: Date?
    /// Paths the user marked as trusted; hidden from the results.
    private(set) var securityIgnored: Set<String> = []

    /// Runs the offline Security Check in the background.
    func runSecurityCheck() {
        guard !isCheckingSecurity else { return }
        isCheckingSecurity = true
        let home = homePath
        Task { [weak self] in
            let findings = await Task.detached(priority: .userInitiated) { SecurityScanner.standard(home: home).scan() }.value
            guard let self else { return }
            self.securityFindings = findings
            self.lastSecurityCheck = Date()
            self.isCheckingSecurity = false
        }
    }

    func setSecurityIgnored(_ path: String, ignored: Bool) {
        if ignored { securityIgnored.insert(path) } else { securityIgnored.remove(path) }
        settings.securityIgnored = securityIgnored
    }

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
    /// User preferences (Settings window).
    let settings = AppSettings()
    private let cache: ScanCache
    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(cache: ScanCache = .standard, activityLog: ActivityLog = .standard) {
        self.cache = cache
        self.activityLog = activityLog
        activityEntries = activityLog.entries
        scanRoots = UserDefaults.standard.stringArray(forKey: "scanRoots") ?? [NSHomeDirectory()]
        securityIgnored = settings.securityIgnored
        loadCache()
        refreshSystemSpace()
    }

    // MARK: Notices

    /// The error or info banner shown at the top of the window (one at a time; newest wins).
    var notice: AppNotice?

    func showNotice(_ notice: AppNotice) {
        self.notice = notice
    }

    // MARK: Cache

    /// True while the last scan is being read from disk at launch.
    private(set) var isLoadingCache = true

    private func loadCache() {
        let cache = self.cache
        Task.detached(priority: .userInitiated) {
            let loaded = cache.loadResult()
            await MainActor.run { self.applyCacheLoad(loaded) }
        }
    }

    private func applyCacheLoad(_ loaded: ScanCache.LoadResult) {
        isLoadingCache = false
        defer { if settings.scanOnLaunch { startScan() } }
        guard result == nil else { return }
        switch loaded {
        case .loaded(let cached):
            result = cached
        case .missing:
            break
        case .outdated:
            showNotice(AppNotice(kind: .info, title: "Previous results need a rescan",
                                 message: "They were saved by an older version of SpaceSweeper.", action: .rescan))
        case .unreadable(let reason):
            showNotice(AppNotice(kind: .warning, title: "Couldn't open previous results",
                                 message: reason, action: .rescan))
        }
    }

    // MARK: Scanning

    /// True while Spotlight "last opened" dates are being loaded after a scan.
    private(set) var isLoadingDates = false

    /// Starts a background scan of `scanRoots`. Progress is polled 10×/s so the UI never floods.
    func startScan() {
        guard !isScanning else { return }
        let progress = ScanProgress()
        var options = ScanOptions(roots: scanRoots, homePath: homePath)
        options.excludedPaths = settings.excludedPaths
        // Show results first; Spotlight dates are loaded lazily afterwards.
        options.readSpotlightDates = false
        isScanning = true
        scanError = nil
        if notice?.action == .rescan { notice = nil }
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
                await self?.finishScan(.success(result))
            } catch is CancellationError {
                await self?.finishScan(.cancelled)
            } catch {
                await self?.finishScan(.failure(error))
            }
        }
    }

    /// Cancels the running scan; partial results are discarded and the previous result is kept.
    func cancelScan() {
        scanTask?.cancel()
    }

    private enum ScanOutcome {
        case success(ScanResult)
        case cancelled
        case failure(Error)
    }

    /// Called on the main actor when a scan ends, successfully or not.
    private func finishScan(_ outcome: ScanOutcome) {
        pollTask?.cancel()
        pollTask = nil
        scanTask = nil
        isScanning = false
        refreshDisk()
        switch outcome {
        case .success(let scanned):
            result = scanned
            loadLastOpenedDates(for: scanned)
            refreshSystemSpace()
        case .cancelled:
            if result != nil {
                showNotice(AppNotice(kind: .info, title: "Scan cancelled", message: "Showing your previous results."))
            }
        case .failure(let error):
            let message = [error.localizedDescription, (error as? LocalizedError)?.recoverySuggestion]
                .compactMap { $0 }.joined(separator: " ")
            scanError = message
            showNotice(AppNotice(kind: .error, title: "The scan failed",
                                 message: result == nil ? message : message + " Showing your previous results.",
                                 action: .rescan))
        }
    }

    /// Loads Spotlight dates in the background, then saves the finished result to the cache.
    private func loadLastOpenedDates(for scanned: ScanResult) {
        isLoadingDates = true
        let cache = self.cache
        Task { [weak self] in
            let enriched = await Task.detached(priority: .utility) { () -> ScanResult in
                var copy = scanned
                FileScanner.addLastUsedDates(&copy.files)
                return copy
            }.value
            let saveError = await Task.detached(priority: .utility) { () -> String? in
                do { try cache.save(enriched); return nil } catch { return error.localizedDescription }
            }.value
            guard let self else { return }
            self.isLoadingDates = false
            // Only apply if no newer scan or deletion replaced the result meanwhile.
            if self.result?.date == scanned.date && self.result?.files.count == scanned.files.count {
                self.result = enriched
            }
            if let saveError {
                self.showNotice(AppNotice(kind: .warning, title: "Couldn't save scan results",
                                          message: "\(saveError) SpaceSweeper will need to rescan next time it opens."))
            }
        }
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
        let policy = settings.protectionPolicy(home: homePath)
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
        let service = DeletionService(policy: settings.protectionPolicy(home: homePath), remover: remover, log: activityLog)
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
        refreshSystemSpace()
        self.outcome = outcome
    }

    // MARK: Privacy controls (Settings › Privacy)

    /// Deletes the saved scan and clears results from the window.
    func clearSavedScan() {
        try? FileManager.default.removeItem(at: cache.fileURL)
        result = nil
    }

    /// Erases the activity log history.
    func clearActivityLog() {
        activityLog.clear()
        activityEntries = []
    }

    // MARK: Finder helpers

    /// Selects the items in a Finder window.
    static func revealInFinder(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// A banner message: what happened, and optionally one action that fixes it.
struct AppNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case info, warning, error

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    /// The single action a banner can offer.
    enum Action: Equatable {
        case rescan
        case openFullDiskAccess
        case retryApps

        var title: String {
            switch self {
            case .rescan: return "Rescan"
            case .openFullDiskAccess: return "Open System Settings"
            case .retryApps: return "Try Again"
            }
        }
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
    var action: Action?

    static func == (lhs: AppNotice, rhs: AppNotice) -> Bool { lhs.id == rhs.id }
}
