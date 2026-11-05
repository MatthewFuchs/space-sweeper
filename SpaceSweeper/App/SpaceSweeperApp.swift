import SwiftUI

@main
struct SpaceSweeperApp: App {
    @State private var state = AppState()
    /// Sparkle updater; stays off until the build has a feed URL and signing key.
    @State private var updates = UpdateController()

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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updates: updates)
            }
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
                Button("SpaceSweeper Website") { NSWorkspace.shared.open(AppLinks.website) }
                Button("Install & Setup Guide") { NSWorkspace.shared.open(AppLinks.installGuide) }
            }
        }

        Settings {
            SettingsView(updates: updates)
                .environment(state)
        }
    }
}

/// Shows the Full Disk Access explainer until access is granted (or the user chooses to continue without it).
struct RootView: View {
    @Environment(AppState.self) private var state
    @AppStorage(AppSettings.Key.appearance) private var appearance = AppearanceMode.system.rawValue
    @Environment(\.openSettings) private var openSettings
    @State private var offerMove = false
    @AppStorage(InstallLocation.declinedKey) private var moveDeclined = false

    var body: some View {
        Group {
            if !state.hasFullDiskAccess && !state.fullDiskAccessDismissed {
                FullDiskAccessView()
            } else {
                ContentView()
            }
        }
        .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
        .sheet(isPresented: $offerMove) { MoveToApplicationsView() }
        .onAppear {
            offerMove = !moveDeclined && InstallLocation.needsMove(bundlePath: Bundle.main.bundlePath)
            #if DEBUG
            DebugLaunch.run(state: state, openSettings: { openSettings() })
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFullDiskAccess()
            state.refreshDisk()
        }
    }
}


/// Public web addresses used in menus and Help.
enum AppLinks {
    static let website = URL(string: "https://matthewfuchs.github.io/space-sweeper/")!
    static let installGuide = URL(string: "https://matthewfuchs.github.io/space-sweeper/install.html")!
}

/// First-launch offer to move a downloaded copy into Applications, so Full Disk Access sticks.
struct MoveToApplicationsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(InstallLocation.declinedKey) private var moveDeclined = false
    @State private var isMoving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Move SpaceSweeper to Applications?").font(.title2.weight(.semibold))
            Text("SpaceSweeper is running from your Downloads or the disk image. Moving it to the Applications folder lets macOS remember its permissions, so you only set them up once.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            }
            HStack {
                Button("Not Now") {
                    moveDeclined = true
                    dismiss()
                }
                Spacer()
                if isMoving { ProgressView().controlSize(.small) }
                Button("Move to Applications", action: move)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isMoving)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    private func move() {
        isMoving = true
        let source = Bundle.main.bundlePath
        Task {
            do {
                let target = try await Task.detached { try InstallLocation.copyToApplications(from: source) }.value
                InstallLocation.relaunch(from: target, removing: source)
            } catch {
                self.error = "Couldn't move it: \(error.localizedDescription). You can drag SpaceSweeper into Applications in Finder instead."
                isMoving = false
            }
        }
    }
}
