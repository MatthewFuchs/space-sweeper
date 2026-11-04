import SwiftUI

@main
struct SpaceSweeperApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .frame(minWidth: 980, minHeight: 620)
                .tint(Theme.accent)
        }
        // Roomy default so all table columns fit next to the inspector on a laptop screen.
        .defaultSize(width: 1380, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { state.startScan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(state.isScanning)
                Button("Cancel Scan") { state.cancelScan() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!state.isScanning)
            }
            // Help › SpaceSweeper Help opens the in-app guide.
            CommandGroup(replacing: .help) {
                Button("SpaceSweeper Help") { state.selectedSection = .help }
                    .keyboardShortcut("?", modifiers: [.command])
            }
        }
    }
}

/// Shows the Full Disk Access explainer until access is granted (or the user chooses to continue without it).
struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if !state.hasFullDiskAccess && !state.fullDiskAccessDismissed {
                FullDiskAccessView()
            } else {
                ContentView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFullDiskAccess()
            state.refreshDisk()
        }
    }
}
