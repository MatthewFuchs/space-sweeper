import Foundation

/// Where in ~/Library a leftover was found.
enum LeftoverLocation: String, CaseIterable, Sendable {
    case applicationSupport = "Library/Application Support"
    case caches = "Library/Caches"
    case preferences = "Library/Preferences"
    case preferencesByHost = "Library/Preferences/ByHost"
    case containers = "Library/Containers"
    case groupContainers = "Library/Group Containers"
    case savedState = "Library/Saved Application State"
    case httpStorages = "Library/HTTPStorages"
    case webKit = "Library/WebKit"
    case launchAgents = "Library/LaunchAgents"
    case logs = "Library/Logs"
    case cookies = "Library/Cookies"

    /// Short label shown next to each leftover in the review sheet.
    var label: String {
        switch self {
        case .applicationSupport: return "App data"
        case .caches: return "Cache"
        case .preferences, .preferencesByHost: return "Preferences"
        case .containers: return "Sandbox container"
        case .groupContainers: return "Shared container"
        case .savedState: return "Saved window state"
        case .httpStorages: return "Web storage"
        case .webKit: return "Web data"
        case .launchAgents: return "Background helper"
        case .logs: return "Logs"
        case .cookies: return "Cookies"
        }
    }

    /// App data and containers may hold documents; everything else is disposable once the app is gone.
    var safety: SafetyLevel {
        switch self {
        case .applicationSupport, .containers, .groupContainers: return .review
        default: return .safe
        }
    }

    /// Only these are searched by app name (in addition to bundle ID); elsewhere names are too ambiguous.
    var allowsNameMatch: Bool {
        self == .applicationSupport || self == .caches || self == .logs
    }
}

/// How confidently a leftover was tied to the app.
enum LeftoverMatch: Sendable, Equatable {
    /// Named after the bundle identifier: checked by default.
    case bundleID
    /// Named after the app only: shown unchecked, because names can be shared between apps.
    case name
}

/// Pure matching rules: does a ~/Library entry belong to an app?
enum LeftoverMatcher {
    /// Vendor names shared by many apps; never matched by name alone.
    static let ambiguousNames: Set<String> = [
        "google", "microsoft", "apple", "adobe", "jetbrains", "mozilla", "oracle", "com", "app", "helper", "data", "cache",
    ]

    /// A bundle ID must look like reverse-DNS with at least three parts to be used for matching.
    static func isUsableBundleID(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return bundleID.split(separator: ".").count >= 3
    }

    static func match(entryName: String, in location: LeftoverLocation, bundleID: String?, appName: String) -> LeftoverMatch? {
        if isUsableBundleID(bundleID), let id = bundleID {
            let lowerName = entryName.lowercased()
            let lowerID = id.lowercased()
            // "com.foo.App", "com.foo.App.helper", "com.foo.App.plist", "com.foo.App.savedState", "com.foo.App.binarycookies"
            if lowerName == lowerID || lowerName.hasPrefix(lowerID + ".") {
                return .bundleID
            }
            if location == .groupContainers {
                // "group.com.foo.App", "ABCDE12345.com.foo.App", "ABCDE12345.com.foo.App.shared"
                let stripped = stripGroupPrefix(lowerName)
                if stripped == lowerID || stripped.hasPrefix(lowerID + ".") { return .bundleID }
            }
        }
        if location.allowsNameMatch, appName.count >= 3, !ambiguousNames.contains(appName.lowercased()),
           entryName.compare(appName, options: .caseInsensitive) == .orderedSame {
            return .name
        }
        return nil
    }

    /// Removes a "group." or 10-character team-ID prefix from a group container name.
    static func stripGroupPrefix(_ name: String) -> String {
        if name.hasPrefix("group.") { return String(name.dropFirst("group.".count)) }
        let parts = name.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isLetter || $0.isNumber }) {
            return String(parts[1])
        }
        return name
    }

    /// True when a launch agent plist starts a program inside the app bundle.
    static func launchAgent(_ plist: [String: Any], pointsInto appPath: String) -> Bool {
        var programs: [String] = []
        if let program = plist["Program"] as? String { programs.append(program) }
        if let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first { programs.append(first) }
        return programs.contains { PathUtil.isSameOrDescendant($0, of: appPath) }
    }
}

/// One leftover found on disk.
struct Leftover: Identifiable, Hashable, Sendable {
    var path: String
    var location: LeftoverLocation
    var match: LeftoverMatch
    var size: Int64
    var id: String { path }
}

/// Finds an app's leftovers in a home folder's Library. Home is injectable so tests use a fixture.
struct LeftoverFinder {
    var home: String = NSHomeDirectory()

    func find(for app: AppInfo) -> [Leftover] {
        let fm = FileManager.default
        var found: [Leftover] = []
        for location in LeftoverLocation.allCases {
            let folder = PathUtil.join(home, location.rawValue)
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { continue }
            for name in names {
                let path = PathUtil.join(folder, name)
                // ByHost lives inside Preferences; don't also list the ByHost folder itself as a match.
                if location == .preferences && name == "ByHost" { continue }
                var match = LeftoverMatcher.match(entryName: name, in: location, bundleID: app.bundleID, appName: app.name)
                if match == nil, location == .launchAgents, name.hasSuffix(".plist"),
                   let plist = NSDictionary(contentsOfFile: path) as? [String: Any],
                   LeftoverMatcher.launchAgent(plist, pointsInto: app.path) {
                    match = .bundleID
                }
                guard let match else { continue }
                found.append(Leftover(path: path, location: location, match: match, size: SizeCalculator.allocatedSize(ofPath: path)))
            }
        }
        return found.sorted { $0.size > $1.size }
    }
}

/// Builds the review-sheet rows for uninstalling one app: the bundle first, then its leftovers.
enum UninstallPlanner {
    static func items(for app: AppInfo, leftovers: [Leftover], policy: ProtectionPolicy) -> [DeletionItem] {
        var appItem = DeletionItem(
            path: app.path, size: app.size ?? SizeCalculator.allocatedSize(ofPath: app.path),
            verdict: app.protectionReason.map { .locked($0) } ?? policy.verdict(for: app.path),
            ownerBundleIDs: app.bundleID.map { [$0] } ?? [],
            note: app.needsAdmin ? "Application · needs your password" : "Application",
            safety: SafetyAssessment(level: .safe, whatItIs: "The \(app.name) app",
                                     ifDeleted: "Reinstall it from its website or the App Store if you need it again."))
        if app.protectionReason != nil { appItem.isChecked = false }

        let rows = leftovers.map { leftover -> DeletionItem in
            DeletionItem(
                path: leftover.path, size: leftover.size, verdict: policy.verdict(for: leftover.path),
                isChecked: leftover.match == .bundleID,
                note: leftover.match == .name ? "\(leftover.location.label) · matched by name, check it" : leftover.location.label,
                safety: SafetyAssessment(
                    level: leftover.location.safety,
                    whatItIs: "\(leftover.location.label) left by \(app.name)",
                    ifDeleted: leftover.location.safety == .safe
                        ? "Only used by \(app.name). Not needed once the app is removed."
                        : "May contain documents or data you made in \(app.name). Keep it if you might reinstall."))
        }
        return [appItem] + rows
    }
}
