#if DEBUG
import AppKit
import SwiftUI

/// Debug-only launch actions used to verify sheets visually without UI scripting. Compiled out of Release.
///
///   SPACESWEEPER_DEBUG_OPEN=review      review sheet for the largest scanned file (nothing is deleted)
///   SPACESWEEPER_DEBUG_OPEN=outcome     sample result sheet (nothing is deleted)
///   SPACESWEEPER_DEBUG_OPEN=uninstall   uninstall sheet for the dummy "SpaceSweeper Test App"
///   SPACESWEEPER_DEBUG_OPEN=settings    Settings window
///   SPACESWEEPER_DEBUG_CONFIRM=1        with "uninstall": press Move to Trash, but only for the dummy app
@MainActor
enum DebugLaunch {
    /// The only app the confirm action may remove.
    static let dummyAppName = "SpaceSweeper Test App"

    static func run(state: AppState, openSettings: @escaping () -> Void) {
        let env = ProcessInfo.processInfo.environment
        // SPACESWEEPER_DEMO_ROOT=<folder>: scan a demo folder for screenshots; nothing is saved.
        if let demoRoot = env["SPACESWEEPER_DEMO_ROOT"], !demoRoot.isEmpty {
            state.isDemo = true
            state.useDemoHome(demoRoot)
            state.startScan(roots: [demoRoot])
        }
        guard let action = env["SPACESWEEPER_DEBUG_OPEN"], !action.isEmpty else { return }
        let confirm = env["SPACESWEEPER_DEBUG_CONFIRM"] == "1"
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            switch action {
            case "review":
                if let file = state.result?.files.max(by: { $0.size < $1.size }) {
                    state.requestDeletion(paths: [file.path])
                }
            case "outcome":
                var outcome = DeletionOutcome(mode: .trash, freeBefore: 100 * GB, freeAfter: 100 * GB)
                outcome.removed = [DeletionItem(path: "/Users/example/Downloads/Installer.dmg", size: 1_200 * MB, verdict: .allowed)]
                outcome.failures = [.init(path: "/Users/example/Library/Caches/locked", message: "Permission denied")]
                state.outcome = outcome
            case "uninstall":
                await openDummyUninstall(state: state, confirm: confirm)
            case "settings":
                openSettings()
            default:
                break
            }
        }
    }

    private static func openDummyUninstall(state: AppState, confirm: Bool) async {
        let path = PathUtil.join(NSHomeDirectory(), "Applications/\(dummyAppName).app")
        guard var app = AppScanner.appInfo(at: path), app.name == dummyAppName else { return }
        app.size = SizeCalculator.allocatedSize(ofPath: path)
        state.requestUninstall([app])
        guard confirm else { return }
        // Wait for the sheet, then confirm only if every removable item belongs to the dummy app.
        for _ in 0..<40 where state.review == nil { try? await Task.sleep(nanoseconds: 250_000_000) }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let request = state.review,
              request.removableItems.allSatisfy({ $0.path.contains("SpaceSweeper Test App") || $0.path.contains("com.mattfuchs.sstestapp") })
        else { return }
        state.performDeletion(request, mode: .trash)
    }
}
#endif
