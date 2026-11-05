import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// How safe an item is to delete, from the user's point of view.
enum SafetyLevel: Int, Codable, Comparable, CaseIterable, Sendable {
    /// Regenerates automatically or is clearly disposable.
    case safe
    /// Personal or unidentified data: fine to delete only if you no longer need it.
    case review
    /// Deleting loses app data, settings or a whole VM/simulator.
    case caution
    /// SpaceSweeper will not delete it.
    case protected

    static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Badge text.
    var shortLabel: String {
        switch self {
        case .safe: return "Safe"
        case .review: return "Review"
        case .caution: return "Careful"
        case .protected: return "Protected"
        }
    }

    /// Heading used in the inspector and review sheet.
    var title: String {
        switch self {
        case .safe: return "Safe to delete"
        case .review: return "Review before deleting"
        case .caution: return "Delete with care"
        case .protected: return "Protected"
        }
    }

    /// Few-word meaning of the level, used in the legend and tooltips.
    var meaning: String {
        switch self {
        case .safe: return "Recreated automatically"
        case .review: return "Your data, check first"
        case .caution: return "Loses app data or settings"
        case .protected: return "Never deleted"
        }
    }

    /// What VoiceOver reads for a badge, e.g. "Rated Safe to delete".
    var accessibilityLabel: String { "Rated \(title)" }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield.fill"
        case .review: return "eye.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .protected: return "lock.fill"
        }
    }

    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return Theme.royalBlue
        case .caution: return .orange
        case .protected: return .secondary
        }
    }
}

/// A safety rating plus the plain-English explanation behind it.
struct SafetyAssessment: Hashable, Sendable {
    var level: SafetyLevel
    /// What the item is, e.g. "Cache file".
    var whatItIs: String
    /// What happens if it is deleted, and how to get it back if that's possible.
    var ifDeleted: String
    /// Extra notes such as "Changed in the last 7 days".
    var notes: [String] = []
}

/// Rates any path for deletion safety. Pure: everything it needs is injected, so it is fully unit-tested.
struct SafetyAdvisor: Sendable {
    let policy: ProtectionPolicy
    /// Known regenerable locations (Developer Junk); their own rating wins for them and everything inside them.
    var junkItems: [DevJunkItem] = []

    var home: String { policy.home }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "ipsw"]
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar"]
    static let vmExtensions: Set<String> = ["utm", "pvm", "vmwarevm", "vdi", "vmdk", "qcow2", "vhd", "vhdx"]

    func assess(path: String, modified: Date? = nil, isPackage: Bool = false) -> SafetyAssessment {
        // 1. The protection list always wins.
        let verdict = policy.verdict(for: path, modified: modified)
        if case .locked(let reason) = verdict {
            return SafetyAssessment(level: .protected, whatItIs: reason,
                                    ifDeleted: "SpaceSweeper won't delete this. Removing it could break macOS, your account or lose irreplaceable data.")
        }

        var assessment = baseAssessment(path: path, isPackage: isPackage)

        // 2. Recent changes mean the item may be in use, so it is never rated "safe".
        if let modified, policy.now.timeIntervalSince(modified) < policy.recentInterval {
            assessment.notes.append("Changed in the last \(policy.recentDays) days, so it may still be in use.")
            if assessment.level == .safe { assessment.level = .review }
        }
        for warning in verdict.warnings where warning.hasPrefix("Inside your") {
            assessment.notes.append("\(warning). Make sure you have a backup.")
        }
        return assessment
    }

    /// Location- and type-based rating, before the "recently changed" adjustment.
    private func baseAssessment(path: String, isPackage: Bool) -> SafetyAssessment {
        if let junk = junkItems.first(where: { PathUtil.isSameOrDescendant(path, of: $0.path) }) {
            let inside = junk.path != path
            // Items titled by their own file name (installers, VM images) get a description instead of a repeat.
            let title = junk.title == (junk.path as NSString).lastPathComponent ? junk.group.itemDescription : junk.title
            return SafetyAssessment(
                level: junk.isDeletable ? junk.safety : .protected,
                whatItIs: inside ? "Inside \(junk.title)" : title,
                ifDeleted: junk.explanation)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let relative = relativeToHome(path)

        if let relative {
            if hasPrefix(relative, ".Trash") {
                return .init(level: .safe, whatItIs: "Already in the Trash",
                             ifDeleted: "It is removed for good when the Trash is emptied.")
            }
            if hasPrefix(relative, "Library/Caches") {
                return .init(level: .safe, whatItIs: "Cache file",
                             ifDeleted: "Apps recreate caches as needed. The app may be a little slower the first time.")
            }
            if hasPrefix(relative, "Library/Logs") {
                return .init(level: .safe, whatItIs: "Log file",
                             ifDeleted: "Logs are only used for troubleshooting. Nothing stops working.")
            }
        }

        if ext == "app" {
            return .init(level: .review, whatItIs: "Application",
                         ifDeleted: "Use Applications › Uninstall instead, so its leftover files are removed too.")
        }
        if Self.vmExtensions.contains(ext) {
            return .init(level: .caution, whatItIs: "Virtual machine",
                         ifDeleted: "The virtual machine and everything installed in it are lost.")
        }

        if let relative {
            if hasPrefix(relative, "Downloads") {
                if Self.installerExtensions.contains(ext) {
                    return .init(level: .safe, whatItIs: "Downloaded installer",
                                 ifDeleted: "Not needed once the app is installed. You can download it again.")
                }
                if Self.archiveExtensions.contains(ext) {
                    return .init(level: .review, whatItIs: "Downloaded archive",
                                 ifDeleted: "Safe if you already extracted what you need from it.")
                }
                return .init(level: .review, whatItIs: "Something you downloaded",
                             ifDeleted: "Fine to delete if you no longer need it. Download it again from its source if you do.")
            }
            if ["Library/Application Support", "Library/Containers", "Library/Group Containers"].contains(where: { hasPrefix(relative, $0) }) {
                return .init(level: .caution, whatItIs: "App data",
                             ifDeleted: "The app may reset or lose what it stored here (documents, game saves, chat history, downloaded content).")
            }
            if hasPrefix(relative, "Library") {
                return .init(level: .caution, whatItIs: "App or system settings",
                             ifDeleted: "Apps or macOS rely on files here. Deleting can reset settings or break an app.")
            }
            if relative.hasPrefix(".") {
                return .init(level: .caution, whatItIs: "Hidden tool or configuration data",
                             ifDeleted: "Command-line tools keep settings and data here. Deleting can break or reset them.")
            }
        }

        if Self.installerExtensions.contains(ext) {
            return .init(level: .safe, whatItIs: "Installer or disk image",
                         ifDeleted: "Usually not needed once the software is installed. Keep it if you can't download it again.")
        }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) || type.conforms(to: .audio) || type.conforms(to: .image) {
                return .init(level: .review, whatItIs: "Your media file",
                             ifDeleted: "It can't be recreated. Make sure it is backed up or you no longer want it.")
            }
            if type.conforms(to: .archive) {
                return .init(level: .review, whatItIs: "Archive",
                             ifDeleted: "Safe if its contents are stored elsewhere or no longer needed.")
            }
        }
        return .init(level: .review, whatItIs: isPackage ? "Document package" : "Your file",
                     ifDeleted: "SpaceSweeper can't tell whether you need this. Open it or reveal it in Finder before deleting.")
    }

    private func relativeToHome(_ path: String) -> String? {
        guard PathUtil.isSameOrDescendant(path, of: home), path != home else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    private func hasPrefix(_ relative: String, _ folder: String) -> Bool {
        relative == folder || relative.hasPrefix(folder + "/")
    }
}
