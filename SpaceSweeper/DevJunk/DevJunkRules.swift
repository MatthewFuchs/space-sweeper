import Foundation

/// Regenerable folders found by name inside project folders.
enum PatternJunkKind: String, Codable, CaseIterable, Sendable {
    case nodeModules
    case nextBuild
    case dist
    case pods
    case pythonVenv
    case target
    case build

    var title: String {
        switch self {
        case .nodeModules: return "node_modules"
        case .nextBuild: return ".next"
        case .dist: return "dist"
        case .pods: return "ios/Pods"
        case .pythonVenv: return "Python virtualenv"
        case .target: return "target/"
        case .build: return "build/"
        }
    }

    var explanation: String {
        switch self {
        case .nodeModules:
            return "npm/yarn/pnpm dependencies. Run `npm install` (or yarn/pnpm) to restore them."
        case .nextBuild:
            return "Next.js build cache and output. Rebuilt by the next `next dev` or `next build`."
        case .dist:
            return "Bundled build output of a JavaScript project. Rebuilt by the project's build script."
        case .pods:
            return "CocoaPods dependencies. Restored with `pod install`."
        case .pythonVenv:
            return "Python virtual environment. Recreate it with `python -m venv` and reinstall requirements."
        case .target:
            return "Rust (Cargo) or Maven build output. Rebuilt by `cargo build` / `mvn package`."
        case .build:
            return "Build output next to a project file. Rebuilt the next time you build the project."
        }
    }
}

/// Pure name-based rules for spotting regenerable developer folders.
enum DevJunkRules {
    /// Directory names that can ever be junk; checked first so siblings are only gathered when needed.
    static let candidateNames: Set<String> = ["node_modules", ".next", "dist", "Pods", ".venv", "venv", "target", "build"]

    /// Files that mark a folder as the root of a software project.
    static let projectMarkers: Set<String> = [
        "package.json", "Podfile", "Cargo.toml", "pom.xml", "build.gradle", "build.gradle.kts",
        "settings.gradle", "settings.gradle.kts", "gradlew", "CMakeLists.txt", "setup.py", "pyproject.toml",
        "Package.swift", "pubspec.yaml", "build.sbt", "go.mod", "composer.json", "angular.json", "meson.build",
    ]
    static let projectMarkerExtensions: Set<String> = ["xcodeproj", "xcworkspace", "csproj", "sln", "fsproj"]

    /// Path prefixes (relative to home) where folders named "build"/"node_modules"/… belong to apps, not projects.
    static let nonProjectHomePrefixes = ["Library", "Applications"]
    static let nonProjectAbsolutePrefixes = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/private/etc", "/private/var/db"]

    static func hasProjectMarker(_ siblings: Set<String>) -> Bool {
        if !siblings.isDisjoint(with: projectMarkers) { return true }
        return siblings.contains { projectMarkerExtensions.contains(($0 as NSString).pathExtension) }
    }

    /// A folder is in a "project area" when it is not inside ~/Library, app bundles, hidden tool folders
    /// (~/.nvm, ~/.vscode, …) or system locations. Deleting node_modules there would break installed tools.
    static func isProjectArea(_ parentPath: String, home: String) -> Bool {
        if nonProjectAbsolutePrefixes.contains(where: { PathUtil.isSameOrDescendant(parentPath, of: $0) }) {
            return false
        }
        let inHome = PathUtil.isSameOrDescendant(parentPath, of: home)
        let relative = inHome ? parentPath.dropFirst(home.count) : Substring(parentPath)
        let components = relative.split(separator: "/")
        if inHome, let first = components.first, nonProjectHomePrefixes.contains(String(first)) {
            return false
        }
        for component in components {
            if component.hasPrefix(".") { return false }
            let ext = (component as NSString).pathExtension
            if ["app", "framework", "bundle", "xcarchive"].contains(ext) { return false }
        }
        return true
    }

    /// Classifies a child directory given its name, its parent folder and the names of its siblings.
    static func classify(directoryName name: String, parentPath: String, siblings: Set<String>, home: String) -> PatternJunkKind? {
        guard candidateNames.contains(name), isProjectArea(parentPath, home: home) else { return nil }
        switch name {
        case "node_modules":
            return .nodeModules
        case ".next":
            return siblings.contains("package.json") ? .nextBuild : nil
        case "dist":
            return siblings.contains("package.json") ? .dist : nil
        case "Pods":
            return siblings.contains("Podfile") ? .pods : nil
        case ".venv", "venv":
            return .pythonVenv
        case "target":
            return siblings.contains("Cargo.toml") || siblings.contains("pom.xml") || siblings.contains("build.sbt") ? .target : nil
        case "build":
            return hasProjectMarker(siblings) ? .build : nil
        default:
            return nil
        }
    }
}
