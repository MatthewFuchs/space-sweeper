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
        .commands {
            CommandGroup(after: .newItem) {
                Button("Rescan") { state.startScan() }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(state.isScanning)
                Button("Cancel Scan") { state.cancelScan() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!state.isScanning)
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
