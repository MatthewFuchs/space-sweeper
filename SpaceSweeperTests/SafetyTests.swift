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
