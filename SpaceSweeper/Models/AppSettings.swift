import Foundation
import SwiftUI

/// Window appearance preference.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// nil follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// User preferences, stored in UserDefaults. Keys are shared with `@AppStorage` in the Settings views.
/// The defaults store is injectable so tests never touch the real preferences.
struct AppSettings {
    enum Key {
        static let appearance = "appearance"
        static let scanOnLaunch = "scanOnLaunch"
        static let excludedPaths = "excludedPaths"
        static let recentChangeDays = "recentChangeDays"
        static let showPermanentDelete = "showPermanentDelete"
    }

    /// Choices offered for "recently modified".
    static let recentChangeChoices = [3, 7, 14, 30]

    var defaults: UserDefaults = .standard

    var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    /// Start a scan automatically when the app opens.
    var scanOnLaunch: Bool {
        get { defaults.bool(forKey: Key.scanOnLaunch) }
        nonmutating set { defaults.set(newValue, forKey: Key.scanOnLaunch) }
    }

    /// Folders the scanner never enters (user choice), normalized and de-duplicated.
    var excludedPaths: [String] {
        get { defaults.stringArray(forKey: Key.excludedPaths) ?? [] }
        nonmutating set { defaults.set(PathUtil.dedupedRoots(newValue).sorted(), forKey: Key.excludedPaths) }
    }

    /// Items changed within this many days are never rated Safe and get a warning. Default 7.
    var recentChangeDays: Int {
        get {
            let value = defaults.integer(forKey: Key.recentChangeDays)
            return Self.recentChangeChoices.contains(value) ? value : 7
        }
        nonmutating set { defaults.set(newValue, forKey: Key.recentChangeDays) }
    }

    /// Offer "Delete Permanently…" in the review sheet. Default on.
    var showPermanentDelete: Bool {
        get { defaults.object(forKey: Key.showPermanentDelete) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.showPermanentDelete) }
    }

    /// The protection policy with the user's "recently modified" window applied.
    func protectionPolicy(home: String) -> ProtectionPolicy {
        var policy = ProtectionPolicy(home: home)
        policy.recentInterval = TimeInterval(recentChangeDays) * 86_400
        return policy
    }

    func addExclusion(_ path: String) {
        excludedPaths = excludedPaths + [PathUtil.normalize(path)]
    }

    func removeExclusion(_ path: String) {
        excludedPaths = excludedPaths.filter { $0 != path }
    }
}
