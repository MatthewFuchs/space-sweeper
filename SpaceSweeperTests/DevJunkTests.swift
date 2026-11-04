import XCTest
@testable import SpaceSweeper

/// Developer-junk detectors: the pure name rules and the catalog built from a fixture home folder.
final class DevJunkTests: XCTestCase {
    private let home = "/Users/tester"

    // MARK: DevJunkRules (pure)

    func testNodeModulesIsAlwaysJunkInProjects() {
        XCTAssertEqual(classify("node_modules", in: "/Users/tester/code/app", siblings: []), .nodeModules)
    }

    func testBuildFolderNeedsAProjectMarker() {
        XCTAssertNil(classify("build", in: "/Users/tester/Documents/taxes", siblings: ["receipts.pdf"]),
                     "a plain 'build' folder is user data")
        for marker in ["package.json", "Podfile", "Cargo.toml", "pom.xml", "build.gradle", "CMakeLists.txt", "Package.swift"] {
            XCTAssertEqual(classify("build", in: "/Users/tester/code/p", siblings: [marker]), .build, marker)
        }
        XCTAssertEqual(classify("build", in: "/Users/tester/code/p", siblings: ["App.xcodeproj"]), .build)
    }

    func testTargetDistNextAndPodsNeedTheirOwnMarkers() {
        XCTAssertEqual(classify("target", in: "/Users/tester/rust", siblings: ["Cargo.toml"]), .target)
        XCTAssertEqual(classify("target", in: "/Users/tester/java", siblings: ["pom.xml"]), .target)
        XCTAssertNil(classify("target", in: "/Users/tester/archery", siblings: ["scores.txt"]))
        XCTAssertEqual(classify("dist", in: "/Users/tester/web", siblings: ["package.json"]), .dist)
        XCTAssertNil(classify("dist", in: "/Users/tester/web", siblings: ["setup.cfg"]))
        XCTAssertEqual(classify(".next", in: "/Users/tester/web", siblings: ["package.json"]), .nextBuild)
        XCTAssertEqual(classify("Pods", in: "/Users/tester/app/ios", siblings: ["Podfile"]), .pods)
        XCTAssertNil(classify("Pods", in: "/Users/tester/podcasts", siblings: ["episode.mp3"]))
    }

    func testVirtualenvNames() {
        XCTAssertEqual(classify(".venv", in: "/Users/tester/py", siblings: []), .pythonVenv)
        XCTAssertEqual(classify("venv", in: "/Users/tester/py", siblings: []), .pythonVenv)
    }

    func testToolAndLibraryFoldersAreNotProjects() {
        // Deleting these would break installed tools or apps.
        XCTAssertNil(classify("node_modules", in: "/Users/tester/.nvm/versions/node/v20/lib", siblings: []))
        XCTAssertNil(classify("node_modules", in: "/Users/tester/.vscode/extensions/ext", siblings: ["package.json"]))
        XCTAssertNil(classify("node_modules", in: "/Users/tester/Library/Application Support/Code", siblings: []))
        XCTAssertNil(classify("node_modules", in: "/Applications/Some.app/Contents/Resources", siblings: []))
        XCTAssertNil(classify("node_modules", in: "/opt/homebrew/lib", siblings: []))
        XCTAssertNil(classify("build", in: "/Users/tester/code/Thing.app/Contents", siblings: ["package.json"]))
    }

    func testUnrelatedNamesAreIgnored() {
        XCTAssertNil(classify("src", in: "/Users/tester/code", siblings: ["package.json"]))
        XCTAssertNil(classify("Build", in: "/Users/tester/code", siblings: ["package.json"]), "matching is case-sensitive")
    }

    private func classify(_ name: String, in parent: String, siblings: Set<String>) -> PatternJunkKind? {
        DevJunkRules.classify(directoryName: name, parentPath: parent, siblings: siblings, home: home)
    }

    // MARK: Scanner + catalog on a fixture home

    func testScannerFindsProjectJunkWithoutNesting() async throws {
        let fixture = try TestFixture(name: "home")
        try fixture.file("code/web/package.json", bytes: 100)
        try fixture.file("code/web/node_modules/react/index.js", bytes: 2_000_000)
        try fixture.file("code/web/node_modules/react/node_modules/x/y.js", bytes: 1_500_000)
        try fixture.file("code/web/dist/bundle.js", bytes: 1_200_000)
        try fixture.file("code/rust/Cargo.toml", bytes: 50)
        try fixture.file("code/rust/target/debug/app", bytes: 3_000_000)
        try fixture.file("Documents/build/plan.pdf", bytes: 2_000_000) // no marker → not junk
        try fixture.file("code/py/.venv/pyvenv.cfg", bytes: 50)
        try fixture.file("code/py/.venv/lib/site.py", bytes: 1_100_000)
        try fixture.file("code/notvenv/venv/readme.txt", bytes: 1_100_000) // no pyvenv.cfg

        let result = try await scan(fixture)
        let hits = Dictionary(uniqueKeysWithValues: result.junkHits.map { ($0.path, $0) })

        XCTAssertEqual(hits[fixture.path("code/web/node_modules")]?.kind, .nodeModules)
        XCTAssertNil(hits[fixture.path("code/web/node_modules/react/node_modules")], "nested node_modules is not listed twice")
        XCTAssertEqual(hits[fixture.path("code/web/node_modules")]?.size,
                       fixture.allocated("code/web/node_modules/react/index.js") + fixture.allocated("code/web/node_modules/react/node_modules/x/y.js"))
        XCTAssertEqual(hits[fixture.path("code/web/dist")]?.kind, .dist)
        XCTAssertEqual(hits[fixture.path("code/rust/target")]?.kind, .target)
        XCTAssertNil(hits[fixture.path("Documents/build")])

        let items = DevJunkCatalog(result: result, home: fixture.path).items()
        let paths = Set(items.map(\.path))
        XCTAssertTrue(paths.contains(fixture.path("code/py/.venv")))
        XCTAssertFalse(paths.contains(fixture.path("code/notvenv/venv")), "venv without pyvenv.cfg is not a virtualenv")
    }

    func testCatalogFindsFixedLocationsAndProtectsDocker() async throws {
        let fixture = try TestFixture(name: "home")
        try fixture.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 2_000_000)
        try fixture.file("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)/Symbols/a", bytes: 1_500_000)
        try fixture.file("Library/Developer/Xcode/iOS DeviceSupport/18.1 (22B83)/Symbols/a", bytes: 1_500_000)
        try fixture.file("Library/Caches/com.example.editor/cache.db", bytes: 1_200_000)
        try fixture.file("Library/Caches/Homebrew/downloads/x.tar.gz", bytes: 1_300_000)
        try fixture.file(".npm/_cacache/content/a", bytes: 1_100_000)
        try fixture.file(".gradle/caches/modules/a.jar", bytes: 1_100_000)
        try fixture.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 2_000_000)
        try fixture.file(".android/avd/Pixel.avd/userdata.img", bytes: 1_400_000)
        try fixture.file("Library/Android/sdk/system-images/android-33/x86/system.img", bytes: 1_600_000)
        try fixture.file("Downloads/Installer.dmg", bytes: 1_000)
        try fixture.file("Library/Developer/Xcode/DerivedData/tiny/x", bytes: 10)

        let result = try await scan(fixture, tracked: 500)
        let items = DevJunkCatalog(result: result, home: fixture.path).items()
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })

        let derived = try XCTUnwrap(byPath[fixture.path("Library/Developer/Xcode/DerivedData")])
        XCTAssertEqual(derived.group, .xcode)
        XCTAssertEqual(derived.ownerBundleIDs, [DevJunkCatalog.xcodeID])
        XCTAssertGreaterThanOrEqual(derived.size, fixture.allocated("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o"))
        XCTAssertNil(byPath[fixture.path("Library/Developer/Xcode/DerivedData/App-abc")], "nested items are de-duplicated")

        XCTAssertNotNil(byPath[fixture.path("Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)")])
        XCTAssertNotNil(byPath[fixture.path("Library/Developer/Xcode/iOS DeviceSupport/18.1 (22B83)")])
        XCTAssertEqual(byPath[fixture.path("Library/Caches/com.example.editor")]?.group, .appCaches)
        XCTAssertEqual(byPath[fixture.path("Library/Caches/com.example.editor")]?.ownerBundleIDs, ["com.example.editor"])
        XCTAssertEqual(byPath[fixture.path("Library/Caches/Homebrew")]?.group, .packageCaches, "Homebrew is listed once, as a package cache")
        XCTAssertEqual(byPath[fixture.path(".npm/_cacache")]?.group, .packageCaches)
        XCTAssertEqual(byPath[fixture.path(".gradle/caches")]?.group, .packageCaches)
        XCTAssertEqual(byPath[fixture.path(".android/avd/Pixel.avd")]?.group, .androidAndVMs)
        XCTAssertEqual(byPath[fixture.path("Library/Android/sdk/system-images/android-33")]?.group, .androidAndVMs)

        let docker = try XCTUnwrap(byPath[fixture.path("Library/Containers/com.docker.docker/Data/vms")])
        XCTAssertFalse(docker.isDeletable, "Docker's disk image must never be offered for deletion")
        XCTAssertTrue(docker.explanation.contains("docker system prune"))

        XCTAssertTrue(items.allSatisfy { $0.size >= 1 * MB }, "tiny items are hidden")
        XCTAssertEqual(items.map(\.size), items.map(\.size).sorted(by: >), "largest first")
    }

    func testInstallersInDownloadsAreListed() async throws {
        let fixture = try TestFixture(name: "home")
        try fixture.file("Downloads/Tool.dmg", bytes: 1_200_000)
        try fixture.file("Downloads/sub/Setup.pkg", bytes: 1_200_000)
        try fixture.file("Downloads/photo.jpg", bytes: 1_200_000)
        try fixture.file("VMs/ubuntu.iso", bytes: 1_200_000)

        let result = try await scan(fixture, tracked: 1_000_000)
        let items = DevJunkCatalog(result: result, home: fixture.path).items()
        let installers = Set(items.filter { $0.group == .installers }.map(\.path))
        XCTAssertEqual(installers, [fixture.path("Downloads/Tool.dmg"), fixture.path("Downloads/sub/Setup.pkg")])
        XCTAssertEqual(items.first { $0.path == fixture.path("VMs/ubuntu.iso") }?.group, .androidAndVMs)
    }

    private func scan(_ fixture: TestFixture, tracked: Int64 = 1_000_000) async throws -> ScanResult {
        var options = ScanOptions(roots: [fixture.path], homePath: fixture.path)
        options.trackedFileMinimum = tracked
        options.folderKeepMinimum = 0
        return try await FileScanner.scan(options: options, progress: ScanProgress())
    }
}

/// Labels and formatting found during the visual review.
final class LabelTests: XCTestCase {
    func testProjectNameSkipsPlatformSubfolders() {
        XCTAssertEqual(DevJunkCatalog.projectName(forJunkAt: "/Users/t/code/MyApp/ios/Pods"), "MyApp/ios")
        XCTAssertEqual(DevJunkCatalog.projectName(forJunkAt: "/Users/t/code/web/node_modules"), "web")
        XCTAssertEqual(DevJunkCatalog.projectName(forJunkAt: "/Users/t/code/tool/target"), "tool")
    }

    func testZeroBytesIsNumeric() {
        XCTAssertEqual(Int64(0).formattedBytes, "0 bytes")
        XCTAssertEqual((2 * GB).formattedBytes, "2 GB")
    }
}
