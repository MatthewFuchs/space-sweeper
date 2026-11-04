import XCTest
@testable import SpaceSweeper

/// Overview breakdown, reclaimable estimate, old-file filtering and application discovery.
final class OverviewAndAppsTests: XCTestCase {

    // MARK: Old files filter

    private func record(_ name: String, size: Int64, modifiedDaysAgo: Double, openedDaysAgo: Double?, now: Date) -> FileRecord {
        FileRecord(path: "/x/\(name)", size: size, logicalSize: size,
                   modified: now.addingTimeInterval(-modifiedDaysAgo * 86_400),
                   accessed: now.addingTimeInterval(-(openedDaysAgo ?? modifiedDaysAgo) * 86_400),
                   lastUsed: openedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }, isPackage: false)
    }

    func testOldFilesUsesMostRecentOfModifiedAndOpened() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let files = [
            record("ancient.mov", size: 100 * MB, modifiedDaysAgo: 800, openedDaysAgo: 700, now: now),
            record("opened-recently.mov", size: 100 * MB, modifiedDaysAgo: 800, openedDaysAgo: 30, now: now),
            record("modified-recently.mov", size: 100 * MB, modifiedDaysAgo: 10, openedDaysAgo: 900, now: now),
            record("old-but-small.mov", size: 10 * MB, modifiedDaysAgo: 800, openedDaysAgo: 800, now: now),
            record("year-and-half.mov", size: 100 * MB, modifiedDaysAgo: 550, openedDaysAgo: nil, now: now),
        ]
        let names = { (months: Int) in
            Set(FileFilters.oldFiles(files, olderThanMonths: months, minimumSize: 50 * MB, now: now).map(\.name))
        }
        XCTAssertEqual(names(12), ["ancient.mov", "year-and-half.mov"])
        XCTAssertEqual(names(24), [])
        XCTAssertEqual(names(6), ["ancient.mov", "year-and-half.mov"])
    }

    // MARK: Overview categories

    func testCategoriesAreNonOverlappingAndAddUp() async throws {
        let fixture = try TestFixture(name: "home")
        try fixture.file("Documents/a.bin", bytes: 300_000)
        try fixture.file("Downloads/b.bin", bytes: 200_000)
        try fixture.file("Library/Caches/app/c.bin", bytes: 150_000)
        try fixture.file("Library/Developer/d.bin", bytes: 120_000)
        try fixture.file("Library/Preferences/e.bin", bytes: 110_000)
        try fixture.file("Projects/f.bin", bytes: 100_000)

        var options = ScanOptions(roots: [fixture.path], homePath: fixture.path)
        options.folderKeepMinimum = 0
        let result = try await FileScanner.scan(options: options, progress: ScanProgress())

        let categories = OverviewCalculator.categories(tree: result.tree, home: fixture.path, diskUsed: nil)
        let byName = Dictionary(uniqueKeysWithValues: categories.map { ($0.name, $0.size) })
        XCTAssertEqual(byName["Documents"], fixture.allocated("Documents/a.bin"))
        XCTAssertEqual(byName["Caches"], fixture.allocated("Library/Caches/app/c.bin"))
        XCTAssertEqual(byName["Developer"], fixture.allocated("Library/Developer/d.bin"))
        XCTAssertEqual(byName["Other app data (Library)"], fixture.allocated("Library/Preferences/e.bin"),
                       "Library excludes Caches and Developer, which are shown separately")
        XCTAssertEqual(byName["Other in home folder"], fixture.allocated("Projects/f.bin"))
        XCTAssertEqual(categories.reduce(0) { $0 + $1.size }, result.totalSize, "categories cover the scan exactly once")

        let withDisk = OverviewCalculator.categories(tree: result.tree, home: fixture.path, diskUsed: result.totalSize + 5 * GB)
        XCTAssertEqual(withDisk.first { $0.name == "System, apps & other" }?.size, 5 * GB)
    }

    func testReclaimableSkipsDockerAndDoubleCounting() {
        let junk = [
            DevJunkItem(path: "/h/proj/node_modules", title: "", explanation: "", group: .projects, size: 400 * MB),
            DevJunkItem(path: "/h/Downloads/x.dmg", title: "", explanation: "", group: .installers, size: 300 * MB),
            DevJunkItem(path: "/h/Library/Containers/com.docker.docker/Data/vms", title: "", explanation: "",
                        group: .docker, size: 60 * GB, isDeletable: false),
        ]
        let now = Date()
        let old = [
            record("in-junk", size: 100 * MB, modifiedDaysAgo: 900, openedDaysAgo: 900, now: now),
            record("standalone", size: 200 * MB, modifiedDaysAgo: 900, openedDaysAgo: 900, now: now),
        ].enumerated().map { index, file -> FileRecord in
            var file = file
            file.path = index == 0 ? "/h/proj/node_modules/big.bin" : "/h/Movies/old.mov"
            return file
        }
        let estimate = OverviewCalculator.reclaimable(junk: junk, oldFiles: old)
        XCTAssertEqual(estimate.developerJunk, 400 * MB)
        XCTAssertEqual(estimate.installers, 300 * MB)
        XCTAssertEqual(estimate.oldFiles, 200 * MB, "old files inside junk folders are counted once")
        XCTAssertEqual(estimate.total, 900 * MB)
    }

    // MARK: Applications

    private func makeApp(_ fixture: TestFixture, _ relative: String, bundleID: String, version: String, bytes: Int = 20_000) throws {
        try fixture.file("\(relative)/Contents/MacOS/bin", bytes: bytes)
        let plist: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": (relative as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                                    "CFBundleShortVersionString": version]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: fixture.url("\(relative)/Contents/Info.plist"))
    }

    func testFindsAppsOneLevelDeepAndSkipsSymlinks() throws {
        let fixture = try TestFixture(name: "Applications")
        try makeApp(fixture, "Editor.app", bundleID: "com.example.editor", version: "2.1")
        try makeApp(fixture, "Suite/Tool.app", bundleID: "com.example.tool", version: "1.0")
        try makeApp(fixture, "Suite/Deep/TooDeep.app", bundleID: "com.example.deep", version: "1.0")
        try fixture.symlink("Linked.app", to: fixture.path("Editor.app"))

        let apps = AppScanner.findApps(in: [fixture.path], ownBundlePath: "/nonexistent/Self.app", ownBundleID: "com.self")
        XCTAssertEqual(apps.map(\.name), ["Editor", "Tool"])
        let editor = try XCTUnwrap(apps.first)
        XCTAssertEqual(editor.bundleID, "com.example.editor")
        XCTAssertEqual(editor.version, "2.1")
        XCTAssertNil(editor.protectionReason)
        XCTAssertFalse(editor.needsAdmin, "fixture is owned by the current user")
    }

    func testSystemAndSelfAppsAreProtected() throws {
        let fixture = try TestFixture(name: "Applications")
        try makeApp(fixture, "SpaceSweeper.app", bundleID: "com.self", version: "1.0")

        XCTAssertNotNil(AppScanner.protectionReason(path: "/System/Applications/Mail.app", bundleID: "com.apple.mail",
                                                    ownBundlePath: "/x/Self.app", ownBundleID: "com.self"))
        XCTAssertEqual(AppScanner.protectionReason(path: fixture.path("SpaceSweeper.app"), bundleID: "com.self",
                                                   ownBundlePath: "/elsewhere/Copy.app", ownBundleID: "com.self"),
                       "This is SpaceSweeper", "matched by bundle ID")
        XCTAssertEqual(AppScanner.protectionReason(path: fixture.path("SpaceSweeper.app"), bundleID: nil,
                                                   ownBundlePath: fixture.path("SpaceSweeper.app"), ownBundleID: "com.other"),
                       "This is SpaceSweeper", "matched by path")
    }
}

/// Keeps the Help section consistent with how the app actually behaves.
final class HelpTests: XCTestCase {
    func testEveryRatingIsExplainedWithAnExample() {
        for level in SafetyLevel.allCases {
            XCTAssertFalse(level.meaning.isEmpty)
            XCTAssertFalse(HelpContent.ratingExamples[level, default: ""].isEmpty, "\(level)")
            XCTAssertTrue(HelpContent.dataKinds.contains { $0.rating == level }, "a data kind shows \(level)")
        }
    }

    func testDataKindRatingsMatchTheSafetyRules() {
        let home = "/Users/tester"
        let advisor = SafetyAdvisor(policy: ProtectionPolicy(home: home, appBundlePath: "/Applications/SpaceSweeper.app"))
        for kind in HelpContent.dataKinds {
            guard let sample = kind.samplePath else { continue }
            XCTAssertEqual(advisor.assess(path: PathUtil.join(home, sample)).level, kind.rating,
                           "Help says \(kind.name) is \(kind.rating) but the app rates \(sample) differently")
        }
    }

    func testHelpTextIsFilledIn() {
        for kind in HelpContent.dataKinds {
            XCTAssertFalse(kind.examples.isEmpty, kind.name)
            XCTAssertFalse(kind.ifDeleted.isEmpty, kind.name)
        }
        XCTAssertTrue(HelpContent.faqs.allSatisfy { !$0.answer.isEmpty })
        XCTAssertEqual(Set(HelpContent.dataKinds.map(\.name)).count, HelpContent.dataKinds.count, "names are unique")
    }
}
