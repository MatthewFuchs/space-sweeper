import AppKit
import Foundation

/// How items are removed. Trash is the default and always recoverable.
enum DeletionMode: String, Codable, Sendable {
    case trash
    case permanent

    var logLabel: String { self == .trash ? "Moved to Trash" : "Deleted permanently" }
}

/// One row of the review sheet.
struct DeletionItem: Identifiable, Hashable, Sendable {
    var path: String
    var size: Int64
    var verdict: ProtectionVerdict
    /// Apps that use this item and should be quit first.
    var ownerBundleIDs: [String] = []
    /// Unchecked rows are listed but not removed (used for optional uninstall leftovers).
    var isChecked = true
    /// Short label shown under the name, e.g. "Preferences" for uninstall leftovers.
    var note: String?
    /// Safety rating with its explanation, shown on the review row.
    var safety: SafetyAssessment?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isRemovable: Bool { isChecked && !verdict.isLocked }
}

/// What the user is being asked to confirm.
struct ReviewRequest: Identifiable {
    enum Kind {
        case files
        /// Uninstalling apps: the apps whose bundles (and chosen leftovers) are being removed.
        case uninstall(apps: [AppInfo])
    }

    let id = UUID()
    var title: String
    var kind: Kind
    var items: [DeletionItem]

    var removableItems: [DeletionItem] { items.filter(\.isRemovable) }
    var removableSize: Int64 { removableItems.reduce(0) { $0 + $1.size } }
    var ownerBundleIDs: Set<String> { Set(items.filter(\.isRemovable).flatMap(\.ownerBundleIDs)) }

    /// Bundle IDs of apps being uninstalled. These must not be running; other owners only trigger a warning.
    var uninstallBundleIDs: Set<String> {
        if case .uninstall(let apps) = kind { return Set(apps.compactMap(\.bundleID)) }
        return []
    }
}

/// Outcome of a deletion run, shown to the user afterwards.
struct DeletionOutcome: Identifiable, Sendable {
    struct Failure: Hashable, Sendable {
        var path: String
        var message: String
    }

    let id = UUID()
    var mode: DeletionMode
    var removed: [DeletionItem] = []
    var failures: [Failure] = []
    var freeBefore: Int64?
    var freeAfter: Int64?

    var removedSize: Int64 { removed.reduce(0) { $0 + $1.size } }
    /// Change in free space measured by the OS (may lag slightly behind for APFS).
    var measuredReclaimed: Int64? {
        guard let freeBefore, let freeAfter else { return nil }
        return freeAfter - freeBefore
    }
}

/// Performs the actual file-system operations. Swappable so tests never touch the real Trash.
protocol FileRemoving: Sendable {
    func moveToTrash(_ url: URL) throws
    func removePermanently(_ url: URL) throws
}

struct SystemFileRemover: FileRemoving {
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func removePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Removes reviewed items. Re-checks the protection policy for every item immediately before removing it,
/// so a locked path can never be deleted even if a caller passes it in.
struct DeletionService: Sendable {
    var policy: ProtectionPolicy
    var remover: FileRemoving = SystemFileRemover()
    var log: ActivityLog
    /// Reads free space; injectable for tests.
    var freeSpace: @Sendable () -> Int64? = { DiskInfo.current()?.available }

    func perform(_ items: [DeletionItem], mode: DeletionMode, context: String? = nil) -> DeletionOutcome {
        var outcome = DeletionOutcome(mode: mode, freeBefore: freeSpace())
        var entries: [ActivityEntry] = []
        for item in items where item.isChecked {
            if case .locked(let reason) = policy.verdict(for: item.path) {
                outcome.failures.append(.init(path: item.path, message: "Protected: \(reason)"))
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            do {
                switch mode {
                case .trash: try remover.moveToTrash(url)
                case .permanent: try remover.removePermanently(url)
                }
                outcome.removed.append(item)
                entries.append(ActivityEntry(date: Date(), path: item.path, size: item.size, action: mode, context: context))
            } catch {
                outcome.failures.append(.init(path: item.path, message: Self.describe(error)))
            }
        }
        log.append(entries)
        outcome.freeAfter = freeSpace()
        return outcome
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return "Permission denied"
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError {
            return "Already gone"
        }
        return ns.localizedDescription
    }
}

/// Finds running apps that own items about to be removed.
enum RunningAppGuard {
    /// Known non-bundle-ID locations and the apps that use them.
    static let knownOwners: [(relative: String, bundleIDs: [String])] = [
        ("Library/Developer", [DevJunkCatalog.xcodeID, DevJunkCatalog.simulatorID]),
        ("Library/Application Support/Code", ["com.microsoft.VSCode"]),
        ("Library/Application Support/Cursor", ["com.todesktop.230313mzl4w4u92"]),
        ("Library/Containers/com.docker.docker", [DevJunkCatalog.dockerID]),
        (".gradle", [DevJunkCatalog.androidStudioID]),
        (".android", [DevJunkCatalog.androidStudioID]),
        ("Library/Android", [DevJunkCatalog.androidStudioID]),
    ]

    /// Library folders whose children are named after the owning app's bundle ID.
    static let bundleNamedFolders = ["Library/Caches", "Library/Containers", "Library/Application Support",
                                     "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit"]

    /// Bundle IDs of apps that likely own `path`. Pure, for tests.
    static func ownerBundleIDs(forPath path: String, home: String) -> [String] {
        var owners: [String] = []
        for known in knownOwners where PathUtil.isSameOrDescendant(path, of: PathUtil.join(home, known.relative)) {
            owners += known.bundleIDs
        }
        for folder in bundleNamedFolders {
            let base = PathUtil.join(home, folder)
            guard PathUtil.isSameOrDescendant(path, of: base), path != base else { continue }
            let component = String(path.dropFirst(base.count + 1).split(separator: "/").first ?? "")
            let candidate = component.replacingOccurrences(of: ".savedState", with: "")
            if candidate.split(separator: ".").count >= 3 { owners.append(candidate) }
        }
        return Array(Set(owners)).sorted()
    }

    /// Running applications among `bundleIDs`.
    static func running(_ bundleIDs: Set<String>) -> [NSRunningApplication] {
        guard !bundleIDs.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return bundleIDs.contains(id)
        }
    }
}
