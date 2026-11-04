import AppKit
import Foundation

/// Sections of the Developer Junk view.
enum JunkGroup: String, CaseIterable, Sendable {
    case xcode = "Xcode"
    case projects = "Project Build Artifacts"
    case packageCaches = "Package Manager Caches"
    case appCaches = "App Caches (~/Library/Caches)"
    case docker = "Docker"
    case androidAndVMs = "Android & Virtual Machines"
    case installers = "Installers & Archives in Downloads"

    var symbol: String {
        switch self {
        case .xcode: return "hammer"
        case .projects: return "shippingbox"
        case .packageCaches: return "archivebox"
        case .appCaches: return "internaldrive"
        case .docker: return "cube.transparent"
        case .androidAndVMs: return "iphone.gen3"
        case .installers: return "arrow.down.circle"
        }
    }
}

/// One regenerable location with its size and what deleting it means.
struct DevJunkItem: Identifiable, Hashable, Sendable {
    var path: String
    var title: String
    var explanation: String
    var group: JunkGroup
    var size: Int64
    /// False for items that must be cleaned by their own tool (Docker's disk image).
    var isDeletable = true
    /// How safe deleting it is. Most junk regenerates (safe); simulators, archives, emulators and venvs need care.
    var safety: SafetyLevel = .safe
    /// Apps that use this location and should be quit before it is deleted.
    var ownerBundleIDs: [String] = []

    var id: String { path }
}

/// Builds the Developer Junk list from a scan result plus a few direct file-system checks.
/// All locations are relative to `home`, so tests can point it at a fixture folder.
struct DevJunkCatalog {
    let result: ScanResult
    let home: String
    var fileManager = FileManager.default
    /// Items smaller than this are hidden (they are not worth a decision).
    var minimumSize: Int64 = 1 * MB

    static let xcodeID = "com.apple.dt.Xcode"
    static let simulatorID = "com.apple.iphonesimulator"
    static let androidStudioID = "com.google.android.studio"
    static let dockerID = "com.docker.docker"

    /// Extensions treated as installers/archives in Downloads.
    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "zip", "xip", "ipsw"]
    /// Extensions treated as VM installer images anywhere.
    static let vmImageExtensions: Set<String> = ["iso", "ipsw"]

    func items() -> [DevJunkItem] {
        var items: [DevJunkItem] = []
        items += xcodeItems()
        items += projectItems()
        items += packageCacheItems()
        items += appCacheItems()
        items += dockerItems()
        items += androidAndVMItems()
        items += installerItems()
        return deduplicated(items.filter { $0.size >= minimumSize })
    }

    // MARK: Sizes

    /// Size from the scan tree when the path was scanned; otherwise measured directly.
    /// A scanned path missing from the tree was pruned, i.e. smaller than the keep threshold.
    func size(of path: String) -> Int64 {
        if let size = result.tree.size(ofPath: path) { return size }
        if result.roots.contains(where: { PathUtil.isSameOrDescendant(path, of: $0) }) { return 0 }
        return fileManager.fileExists(atPath: path) ? SizeCalculator.allocatedSize(ofPath: path) : 0
    }

    private func home(_ relative: String) -> String { PathUtil.join(home, relative) }

    /// Child directory names of `path` (empty when missing).
    private func children(of path: String) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A fixed home-relative location, or nil when it doesn't exist.
    private func item(_ relative: String, _ title: String, _ explanation: String, _ group: JunkGroup,
                      owners: [String] = [], deletable: Bool = true, safety: SafetyLevel = .safe) -> DevJunkItem? {
        let path = home(relative)
        guard fileManager.fileExists(atPath: path) else { return nil }
        return DevJunkItem(path: path, title: title, explanation: explanation, group: group, size: size(of: path),
                           isDeletable: deletable, safety: deletable ? safety : .protected, ownerBundleIDs: owners)
    }

    // MARK: Groups

    private func xcodeItems() -> [DevJunkItem] {
        let xcode = [Self.xcodeID]
        var items = [
            item("Library/Developer/Xcode/DerivedData", "Xcode DerivedData",
                 "Build products and indexes. Xcode rebuilds them; the next build of each project is slower.",
                 .xcode, owners: xcode),
            item("Library/Developer/CoreSimulator/Devices", "Simulator devices",
                 "All simulators with their installed apps and data. Xcode recreates default simulators, but data inside them is lost. `xcrun simctl delete unavailable` removes only obsolete ones.",
                 .xcode, owners: xcode + [Self.simulatorID], safety: .caution),
            item("Library/Developer/CoreSimulator/Caches", "Simulator caches",
                 "Shared caches for simulator runtimes. Rebuilt automatically when a simulator boots.",
                 .xcode, owners: xcode + [Self.simulatorID]),
            item("Library/Developer/Xcode/Archives", "Xcode Archives",
                 "Builds made with Product › Archive. They contain the dSYMs needed to symbolicate crash reports, so keep the ones for released versions.",
                 .xcode, owners: xcode, safety: .caution),
        ].compactMap { $0 }

        for platform in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let base = home("Library/Developer/Xcode/\(platform) DeviceSupport")
            for version in children(of: base) {
                let path = PathUtil.join(base, version)
                items.append(DevJunkItem(
                    path: path, title: "\(platform) DeviceSupport \(version)",
                    explanation: "Debug symbols copied from a device running \(platform) \(version). Xcode copies them again if you connect a device with that version.",
                    group: .xcode, size: size(of: path), ownerBundleIDs: xcode))
            }
        }
        return items
    }

    private func projectItems() -> [DevJunkItem] {
        result.junkHits.compactMap { hit in
            // A folder named venv only counts when it really is a virtual environment.
            if hit.kind == .pythonVenv && !fileManager.fileExists(atPath: PathUtil.join(hit.path, "pyvenv.cfg")) {
                return nil
            }
            return DevJunkItem(path: hit.path, title: "\(hit.kind.title) — \(Self.projectName(forJunkAt: hit.path))",
                               explanation: hit.kind.explanation, group: .projects, size: hit.size,
                               safety: hit.kind == .pythonVenv ? .review : .safe)
        }
    }

    private func packageCacheItems() -> [DevJunkItem] {
        [
            item(".cache", "~/.cache",
                 "Shared cache used by many command-line tools (pip, Hugging Face, pre-commit…). Tools re-download what they need, which can take a while for large models.",
                 .packageCaches, safety: .review),
            item(".npm/_cacache", "npm cache",
                 "npm's download cache. npm re-downloads packages when they are next installed.", .packageCaches),
            item(".nuget/packages", "NuGet packages",
                 "NuGet's global package folder. Restored by `dotnet restore` or the next build.", .packageCaches),
            item(".gradle/caches", "Gradle caches",
                 "Gradle dependency and build caches. Re-downloaded and rebuilt on the next Gradle build.",
                 .packageCaches, owners: [Self.androidStudioID]),
            item(".m2/repository", "Maven repository",
                 "Maven's local repository. Dependencies are re-downloaded on the next Maven build.", .packageCaches),
            item(".expo", "Expo cache",
                 "Expo CLI caches and downloaded tooling. Recreated the next time you run Expo.", .packageCaches),
            item("Library/Caches/Homebrew", "Homebrew downloads",
                 "Downloaded bottles and source archives, same as `brew cleanup --prune=all`. Installed packages are not affected.",
                 .packageCaches),
        ].compactMap { $0 }
    }

    /// One item per app folder in ~/Library/Caches (Homebrew has its own entry above).
    private func appCacheItems() -> [DevJunkItem] {
        let base = home("Library/Caches")
        let names: [String]
        if let id = result.tree.index(ofPath: base) {
            names = result.tree.nodes[Int(id)].children
                .map { result.tree.nodes[Int($0)] }
                .filter { $0.kind == .directory || $0.kind == .package }
                .map(\.name)
        } else {
            names = children(of: base)
        }
        return names.filter { $0 != "Homebrew" }.map { name in
            let path = PathUtil.join(base, name)
            let appName = Self.appName(forBundleID: name)
            return DevJunkItem(
                path: path, title: appName ?? name,
                explanation: "Cache files for \(appName ?? name). The app recreates what it needs, but may be slower the first time.",
                group: .appCaches, size: size(of: path),
                ownerBundleIDs: name.contains(".") ? [name] : [])
        }
    }

    private func dockerItems() -> [DevJunkItem] {
        [
            item("Library/Containers/com.docker.docker/Data/vms", "Docker disk image",
                 "Docker Desktop's virtual disk holding all images, containers and volumes. Don't delete the file: clean it with `docker system prune` or in Docker Desktop › Troubleshoot › Clean / Purge data.",
                 .docker, owners: [Self.dockerID], deletable: false),
        ].compactMap { $0 }
    }

    private func androidAndVMItems() -> [DevJunkItem] {
        var items: [DevJunkItem] = []
        let images = home("Library/Android/sdk/system-images")
        for api in children(of: images) {
            let path = PathUtil.join(images, api)
            items.append(DevJunkItem(
                path: path, title: "Android system image \(api)",
                explanation: "Emulator system images for \(api). Re-download them from Android Studio's SDK Manager if needed.",
                group: .androidAndVMs, size: size(of: path), ownerBundleIDs: [Self.androidStudioID]))
        }
        let avds = home(".android/avd")
        for avd in children(of: avds) where avd.hasSuffix(".avd") {
            let path = PathUtil.join(avds, avd)
            items.append(DevJunkItem(
                path: path, title: "Android emulator \((avd as NSString).deletingPathExtension)",
                explanation: "An Android Virtual Device including its disk and snapshots. Deleting removes the emulator and everything installed in it.",
                group: .androidAndVMs, size: size(of: path), safety: .caution, ownerBundleIDs: [Self.androidStudioID]))
        }
        let downloads = home("Downloads")
        for file in result.files where Self.vmImageExtensions.contains(file.url.pathExtension.lowercased())
            && !PathUtil.isSameOrDescendant(file.path, of: downloads) {
            items.append(DevJunkItem(
                path: file.path, title: file.name,
                explanation: "Operating-system installer image (used by Parallels, UTM, VMware…). Not needed once the virtual machine is installed.",
                group: .androidAndVMs, size: file.size))
        }
        return items
    }

    private func installerItems() -> [DevJunkItem] {
        let downloads = home("Downloads")
        return result.files
            .filter { PathUtil.isSameOrDescendant($0.path, of: downloads) && Self.installerExtensions.contains($0.url.pathExtension.lowercased()) }
            .map { file in
                DevJunkItem(path: file.path, title: file.name,
                            explanation: "Downloaded installer or archive. Usually not needed once the app is installed or the archive is extracted.",
                            group: .installers, size: file.size)
            }
    }

    // MARK: Helpers

    /// Drops items nested inside another listed item so nothing is counted twice.
    private func deduplicated(_ items: [DevJunkItem]) -> [DevJunkItem] {
        let sorted = items.sorted { $0.path.count < $1.path.count }
        var kept: [DevJunkItem] = []
        for item in sorted where !kept.contains(where: { PathUtil.isSameOrDescendant(item.path, of: $0.path) }) {
            kept.append(item)
        }
        return kept.sorted { $0.size > $1.size }
    }

    /// The project a junk folder belongs to: its parent folder, or the grandparent when the parent is a platform
    /// sub-folder such as "ios" (so ".../MyApp/ios/Pods" is labelled "MyApp", not "ios").
    static func projectName(forJunkAt path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let parentName = (parent as NSString).lastPathComponent
        if ["ios", "android", "macos"].contains(parentName.lowercased()) {
            let grandparent = ((parent as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return "\(grandparent)/\(parentName)"
        }
        return parentName
    }

    /// "com.microsoft.VSCode" → "Visual Studio Code" when the app is installed.
    static func appName(forBundleID bundleID: String) -> String? {
        guard bundleID.contains("."),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
