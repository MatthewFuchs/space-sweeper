import Foundation

/// One slice of the Overview breakdown chart.
struct UsageCategory: Identifiable, Hashable, Sendable {
    var name: String
    var size: Int64
    var symbol: String
    var id: String { name }
}

/// Estimate of how much space could be freed, split by source.
struct ReclaimableEstimate: Equatable, Sendable {
    var developerJunk: Int64 = 0
    var installers: Int64 = 0
    var oldFiles: Int64 = 0
    var total: Int64 { developerJunk + installers + oldFiles }
}

/// Pure calculations behind the Overview screen.
enum OverviewCalculator {
    /// Home sub-folders shown as their own categories, in display order.
    static let homeCategories: [(relative: String, name: String, symbol: String)] = [
        ("Documents", "Documents", "doc"),
        ("Desktop", "Desktop", "menubar.dock.rectangle"),
        ("Downloads", "Downloads", "arrow.down.circle"),
        ("Pictures", "Pictures", "photo"),
        ("Movies", "Movies", "film"),
        ("Music", "Music", "music.note"),
        ("Library/Caches", "Caches", "internaldrive"),
        ("Library/Developer", "Developer", "hammer"),
        ("Library", "Other app data (Library)", "books.vertical"),
    ]

    /// Splits scanned space into non-overlapping categories. "Library" excludes the Caches/Developer
    /// sub-folders counted above it; anything outside the scan shows as "System, apps & other".
    static func categories(tree: FolderTree, home: String, diskUsed: Int64?) -> [UsageCategory] {
        var result: [UsageCategory] = []
        var homeAccounted: Int64 = 0

        if let homeID = tree.index(ofPath: home) {
            var librarySubtract: Int64 = 0
            for category in homeCategories {
                let path = PathUtil.join(home, category.relative)
                var size = tree.size(ofPath: path) ?? 0
                if category.relative.hasPrefix("Library/") {
                    librarySubtract += size
                } else if category.relative == "Library" {
                    size -= librarySubtract
                }
                homeAccounted += size
                result.append(UsageCategory(name: category.name, size: size, symbol: category.symbol))
            }
            let homeSize = tree.nodes[Int(homeID)].size
            result.append(UsageCategory(name: "Other in home folder", size: max(0, homeSize - homeAccounted), symbol: "house"))
        }

        for rootID in tree.rootIDs {
            let root = tree.nodes[Int(rootID)]
            if root.name == home || PathUtil.isSameOrDescendant(home, of: root.name) { continue }
            result.append(UsageCategory(name: PathUtil.abbreviate(root.name, home: home), size: root.size, symbol: "folder"))
        }

        // When the scan root contains home (e.g. "/"), home categories already describe part of it.
        if let used = diskUsed {
            let scannedOnDisk = tree.rootIDs
                .map { tree.nodes[Int($0)] }
                .filter { !$0.name.hasPrefix("/Volumes/") }
                .reduce(Int64(0)) { $0 + $1.size }
            result.append(UsageCategory(name: "System, apps & other", size: max(0, used - scannedOnDisk), symbol: "gearshape"))
        }
        return result.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }

    /// Developer junk (deletable only) + installers in Downloads + old files not already inside a junk item.
    static func reclaimable(junk: [DevJunkItem], oldFiles: [FileRecord]) -> ReclaimableEstimate {
        var estimate = ReclaimableEstimate()
        let deletable = junk.filter(\.isDeletable)
        for item in deletable {
            if item.group == .installers {
                estimate.installers += item.size
            } else {
                estimate.developerJunk += item.size
            }
        }
        estimate.oldFiles = oldFiles
            .filter { file in !deletable.contains { PathUtil.isSameOrDescendant(file.path, of: $0.path) } }
            .reduce(0) { $0 + $1.size }
        return estimate
    }
}

/// Filters for the file lists.
enum FileFilters {
    /// Files at least `minimumSize` that were neither opened nor modified in the last `months` months.
    static func oldFiles(_ files: [FileRecord], olderThanMonths months: Int, minimumSize: Int64,
                         now: Date = Date(), calendar: Calendar = .current) -> [FileRecord] {
        guard let cutoff = calendar.date(byAdding: .month, value: -months, to: now) else { return [] }
        return files.filter { $0.size >= minimumSize && $0.lastActivity < cutoff }
    }
}
