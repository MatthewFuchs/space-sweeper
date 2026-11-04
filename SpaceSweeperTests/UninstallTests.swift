import XCTest
@testable import SpaceSweeper

/// Leftover matching, the leftover finder on a fixture Library, the uninstall plan and admin-command quoting.
final class UninstallTests: XCTestCase {
    private let bundleID = "com.example.Editor"

    private func match(_ name: String, _ location: LeftoverLocation, appName: String = "Editor") -> LeftoverMatch? {
        LeftoverMatcher.match(entryName: name, in: location, bundleID: bundleID, appName: appName)
    }

    // MARK: Matcher

    func testBundleIDMatchesAcrossLocations() {
        XCTAssertEqual(match("com.example.Editor", .applicationSupport), .bundleID)
        XCTAssertEqual(match("com.example.Editor", .caches), .bundleID)
        XCTAssertEqual(match("com.example.Editor.plist", .preferences), .bundleID)
        XCTAssertEqual(match("com.example.Editor.helper.plist", .preferences), .bundleID)
        XCTAssertEqual(match("com.example.Editor.0A1B2C3D.plist", .preferencesByHost), .bundleID)
        XCTAssertEqual(match("com.example.Editor.savedState", .savedState), .bundleID)
        XCTAssertEqual(match("com.example.Editor.binarycookies", .cookies), .bundleID)
        XCTAssertEqual(match("COM.EXAMPLE.EDITOR", .containers), .bundleID, "case-insensitive like APFS")
    }

    func testSimilarBundleIDsDoNotMatch() {
        XCTAssertNil(match("com.example.EditorPro", .applicationSupport), "prefix must end at a dot")
        XCTAssertNil(match("com.example.Edit", .caches))
        XCTAssertNil(match("com.example", .preferences))
    }

    func testGroupContainers() {
        XCTAssertEqual(match("group.com.example.Editor", .groupContainers), .bundleID)
        XCTAssertEqual(match("ABCDE12345.com.example.Editor", .groupContainers), .bundleID)
        XCTAssertEqual(match("ABCDE12345.com.example.Editor.shared", .groupContainers), .bundleID)
        XCTAssertNil(match("ABCDE12345.com.example.Other", .groupContainers))
        XCTAssertEqual(LeftoverMatcher.stripGroupPrefix("ubf8t346g9.office"), "office")
    }

    func testNameMatchesAreLimitedAndUnambiguous() {
        XCTAssertEqual(match("Editor", .applicationSupport), .name)
        XCTAssertEqual(match("editor", .caches), .name)
        XCTAssertNil(match("Editor", .preferences), "names are too ambiguous outside App Support/Caches/Logs")
        XCTAssertNil(match("Google", .applicationSupport, appName: "Google"), "vendor names are shared by many apps")
        XCTAssertNil(LeftoverMatcher.match(entryName: "AB", in: .caches, bundleID: nil, appName: "AB"), "too short")
    }

    func testUnusableBundleIDsNeverMatch() {
        XCTAssertFalse(LeftoverMatcher.isUsableBundleID(nil))
        XCTAssertFalse(LeftoverMatcher.isUsableBundleID("com.example"))
        XCTAssertNil(LeftoverMatcher.match(entryName: "com.example", in: .caches, bundleID: "com.example", appName: "X Y"))
    }

    func testLaunchAgentPointingIntoApp() {
        let app = "/Applications/Editor.app"
        XCTAssertTrue(LeftoverMatcher.launchAgent(["ProgramArguments": ["/Applications/Editor.app/Contents/MacOS/updater", "--daemon"]], pointsInto: app))
        XCTAssertTrue(LeftoverMatcher.launchAgent(["Program": "/Applications/Editor.app/Contents/Library/Helper"], pointsInto: app))
        XCTAssertFalse(LeftoverMatcher.launchAgent(["Program": "/Applications/Editor Pro.app/Contents/MacOS/x"], pointsInto: app))
    }

    // MARK: Finder + planner on a fixture home

    private func makeApp() -> AppInfo {
        AppInfo(path: "/Applications/Editor.app", name: "Editor", bundleID: bundleID, version: "1.0", size: 50_000_000)
    }

    func testFinderFindsLeftoversInFixtureLibrary() throws {
        let home = try TestFixture(name: "home")
        try home.file("Library/Application Support/com.example.Editor/db.sqlite", bytes: 40_000)
        try home.file("Library/Application Support/Editor/settings.json", bytes: 1_000)
        try home.file("Library/Caches/com.example.Editor/cache.bin", bytes: 80_000)
        try home.file("Library/Preferences/com.example.Editor.plist", bytes: 500)
        try home.file("Library/Preferences/ByHost/com.example.Editor.ABC.plist", bytes: 500)
        try home.file("Library/Saved Application State/com.example.Editor.savedState/data", bytes: 500)
        try home.file("Library/Group Containers/ABCDE12345.com.example.Editor/x", bytes: 500)
        try home.file("Library/Caches/com.example.EditorPro/cache.bin", bytes: 500) // different app
        try home.file("Library/Preferences/com.other.app.plist", bytes: 500)
        let agent: [String: Any] = ["Label": "org.updater", "ProgramArguments": ["/Applications/Editor.app/Contents/MacOS/upd"]]
        try home.dir("Library/LaunchAgents")
        try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
            .write(to: home.url("Library/LaunchAgents/org.updater.plist"))

        let leftovers = LeftoverFinder(home: home.path).find(for: makeApp())
        let byPath = Dictionary(uniqueKeysWithValues: leftovers.map { ($0.path, $0) })

        XCTAssertEqual(byPath[home.path("Library/Application Support/com.example.Editor")]?.match, .bundleID)
        XCTAssertEqual(byPath[home.path("Library/Application Support/Editor")]?.match, .name)
        XCTAssertNotNil(byPath[home.path("Library/Caches/com.example.Editor")])
        XCTAssertNotNil(byPath[home.path("Library/Preferences/com.example.Editor.plist")])
        XCTAssertNotNil(byPath[home.path("Library/Preferences/ByHost/com.example.Editor.ABC.plist")])
        XCTAssertNotNil(byPath[home.path("Library/Saved Application State/com.example.Editor.savedState")])
        XCTAssertNotNil(byPath[home.path("Library/Group Containers/ABCDE12345.com.example.Editor")])
        XCTAssertEqual(byPath[home.path("Library/LaunchAgents/org.updater.plist")]?.match, .bundleID)
        XCTAssertNil(byPath[home.path("Library/Caches/com.example.EditorPro")])
        XCTAssertNil(byPath[home.path("Library/Preferences/com.other.app.plist")])
        XCTAssertNil(byPath[home.path("Library/Preferences/ByHost")], "the ByHost folder itself is not a leftover")
        XCTAssertEqual(byPath[home.path("Library/Caches/com.example.Editor")]?.size, home.allocated("Library/Caches/com.example.Editor/cache.bin"))
    }

    func testPlanListsAppFirstAndChecksOnlyBundleIDMatches() {
        let app = makeApp()
        let leftovers = [
            Leftover(path: "/Users/t/Library/Caches/com.example.Editor", location: .caches, match: .bundleID, size: 10),
            Leftover(path: "/Users/t/Library/Application Support/Editor", location: .applicationSupport, match: .name, size: 20),
        ]
        let items = UninstallPlanner.items(for: app, leftovers: leftovers,
                                           policy: ProtectionPolicy(home: "/Users/t", appBundlePath: "/Applications/SpaceSweeper.app"))
        XCTAssertEqual(items.map(\.path), [app.path] + leftovers.map(\.path))
        XCTAssertEqual(items.map(\.isChecked), [true, true, false], "name-only matches start unchecked")
        XCTAssertEqual(items[0].ownerBundleIDs, [bundleID], "running check targets the app itself")
        XCTAssertEqual(items[1].safety?.level, .safe)
        XCTAssertEqual(items[2].safety?.level, .review, "App Support may hold the user's data")
    }

    func testProtectedAppIsLockedInPlan() {
        var app = makeApp()
        app.protectionReason = "Apple system app"
        let items = UninstallPlanner.items(for: app, leftovers: [], policy: ProtectionPolicy(home: "/Users/t"))
        XCTAssertTrue(items[0].verdict.isLocked)
        XCTAssertFalse(items[0].isRemovable)
    }

    func testUninstallRequestExposesTargetBundleIDs() {
        let request = ReviewRequest(title: "t", kind: .uninstall(apps: [makeApp()]), items: [])
        XCTAssertEqual(request.uninstallBundleIDs, [bundleID])
        XCTAssertEqual(ReviewRequest(title: "t", kind: .files, items: []).uninstallBundleIDs, [])
    }

    // MARK: Admin command quoting

    func testShellAndAppleScriptQuoting() {
        XCTAssertEqual(PrivilegedFallbackRemover.shellQuote("/Applications/My App.app"), "'/Applications/My App.app'")
        XCTAssertEqual(PrivilegedFallbackRemover.shellQuote("/x/it's.app"), "'/x/it'\\''s.app'")
        XCTAssertEqual(PrivilegedFallbackRemover.appleScriptLiteral("say \"hi\" \\ there"), "\"say \\\"hi\\\" \\\\ there\"")
    }

    func testPermissionErrorsAreRecognised() {
        XCTAssertTrue(PrivilegedFallbackRemover.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(PrivilegedFallbackRemover.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(PrivilegedFallbackRemover.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testUniqueTrashDestination() throws {
        let trash = try TestFixture(name: "Trash")
        let first = PrivilegedFallbackRemover.uniqueDestination(for: URL(fileURLWithPath: "/Applications/Editor.app"), in: trash.root)
        XCTAssertEqual(first.lastPathComponent, "Editor.app")
        try trash.dir("Editor.app")
        let second = PrivilegedFallbackRemover.uniqueDestination(for: URL(fileURLWithPath: "/Applications/Editor.app"), in: trash.root)
        XCTAssertNotEqual(second.lastPathComponent, "Editor.app")
        XCTAssertEqual(second.pathExtension, "app")
    }
}
