import AppKit
import SwiftUI

/// SpaceSweeper › Settings… (⌘,): General, Appearance, Scanning, Safety, Privacy and Updates tabs.
struct SettingsView: View {
    let updates: UpdateController
    @AppStorage(AppSettings.Key.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            ScanningSettings()
                .tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            SafetySettings()
                .tabItem { Label("Safety", systemImage: "checkmark.shield") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            UpdateSettings(updates: updates)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
        .preferredColorScheme(AppearanceMode(rawValue: appearance)?.colorScheme)
    }
}

/// Scan on open and default list thresholds.
struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.scanOnLaunch) private var scanOnLaunch = false
    @AppStorage("largeFilesThresholdLog") private var thresholdLog: Double = log10(500)
    @AppStorage("oldFilesMonths") private var oldMonths = 12

    var body: some View {
        Form {
            Toggle("Scan automatically when SpaceSweeper opens", isOn: $scanOnLaunch)
            Picker("Large Files minimum", selection: $thresholdLog) {
                Text("100 MB").tag(log10(100.0))
                Text("500 MB").tag(log10(500.0))
                Text("1 GB").tag(log10(1_000.0))
                Text("5 GB").tag(log10(5_000.0))
            }
            Picker("Old Files after", selection: $oldMonths) {
                Text("6 months").tag(6)
                Text("12 months").tag(12)
                Text("24 months").tag(24)
            }
        }
        .formStyle(.grouped)
    }
}

/// Light, dark or follow the system.
struct AppearanceSettings: View {
    @AppStorage(AppSettings.Key.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
    }
}

/// Scan locations and folders to always skip.
struct ScanningSettings: View {
    @Environment(AppState.self) private var state
    @State private var excluded: [String] = []

    var body: some View {
        Form {
            Section("Scan locations") {
                ForEach(state.scanRoots, id: \.self) { root in
                    PathRow(path: root, symbol: root.hasPrefix("/Volumes/") ? "externaldrive" : "folder",
                            canRemove: state.scanRoots.count > 1) { state.removeScanRoot(root) }
                }
                Button("Add Folder or Volume…") {
                    if let urls = Self.chooseFolders(prompt: "Add") { state.addScanRoots(urls) }
                }
            }
            Section {
                if excluded.isEmpty {
                    Text("No excluded folders.").foregroundStyle(.secondary)
                }
                ForEach(excluded, id: \.self) { path in
                    PathRow(path: path, symbol: "eye.slash", canRemove: true) {
                        state.settings.removeExclusion(path)
                        excluded = state.settings.excludedPaths
                    }
                }
                Button("Exclude a Folder…") {
                    if let urls = Self.chooseFolders(prompt: "Exclude") {
                        urls.forEach { state.settings.addExclusion($0.path) }
                        excluded = state.settings.excludedPaths
                    }
                }
            } header: {
                Text("Always skip")
            } footer: {
                Text("Skipped folders aren't counted and appear under Couldn't Scan. Changes apply on the next scan.")
            }
        }
        .formStyle(.grouped)
        .onAppear { excluded = state.settings.excludedPaths }
    }

    static func chooseFolders(prompt: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.urls : nil
    }
}

/// A path with an icon and an optional remove button.
struct PathRow: View {
    let path: String
    let symbol: String
    let canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(PathUtil.abbreviate(path)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
                .accessibilityLabel("Remove \(PathUtil.abbreviate(path))")
        }
    }
}

/// How cautious the ratings and review sheet are.
struct SafetySettings: View {
    @AppStorage(AppSettings.Key.recentChangeDays) private var recentDays = 7
    @AppStorage(AppSettings.Key.showPermanentDelete) private var showPermanentDelete = true

    var body: some View {
        Form {
            Picker("Treat files as in use if changed within", selection: $recentDays) {
                ForEach(AppSettings.recentChangeChoices, id: \.self) { days in
                    Text("\(days) days").tag(days)
                }
            }
            Toggle("Offer “Delete Permanently” in the review sheet", isOn: $showPermanentDelete)
            Section {
                Label("Protected locations (macOS, Keychains, iCloud Drive, Mail, Photos, ~/.ssh) can never be deleted.",
                      systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Privacy policy and controls for the data SpaceSweeper keeps on this Mac.
struct PrivacySettings: View {
    @Environment(AppState.self) private var state
    @State private var showPolicy = false
    @State private var confirmClearLog = false

    var body: some View {
        Form {
            Section {
                ForEach(HelpContent.privacy, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                Button("Read the Privacy Policy") { showPolicy = true }
            }
            Section("Data stored on this Mac") {
                LabeledContent("Saved scan") {
                    Button("Delete") { state.clearSavedScan() }.disabled(state.result == nil)
                }
                LabeledContent("Activity log (\(state.activityEntries.count) items)") {
                    Button("Clear…") { confirmClearLog = true }.disabled(state.activityEntries.isEmpty)
                }
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.open(ScanCache.appSupportDirectory)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPolicy) { PrivacyPolicyView() }
        .confirmationDialog("Clear the activity log?", isPresented: $confirmClearLog) {
            Button("Clear Log", role: .destructive) { state.clearActivityLog() }
        } message: {
            Text("This only erases the history. Items already in the Trash stay there.")
        }
    }
}

/// Automatic update preferences (Sparkle).
struct UpdateSettings: View {
    let updates: UpdateController
    @State private var automaticallyChecks = false

    var body: some View {
        Form {
            if updates.isConfigured {
                Toggle("Automatically check for updates", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, value in updates.automaticallyChecks = value }
                HStack {
                    Button("Check Now") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                    if let last = updates.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Updates aren't set up in this build.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { automaticallyChecks = updates.automaticallyChecks }
    }
}

/// "Check for Updates…" menu item, disabled with an explanation when updates aren't configured.
struct CheckForUpdatesCommand: View {
    let updates: UpdateController

    var body: some View {
        Button(updates.isConfigured ? "Check for Updates…" : "Check for Updates… (not set up)") {
            updates.checkForUpdates()
        }
        .disabled(!updates.isConfigured || !updates.canCheckForUpdates)
    }
}
