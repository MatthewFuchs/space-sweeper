import SwiftUI

/// SpaceSweeper › Settings…: update preferences.
struct SettingsView: View {
    let updates: UpdateController
    @State private var automaticallyChecks = false

    var body: some View {
        Form {
            Section("Updates") {
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
        }
        .formStyle(.grouped)
        .frame(width: 420)
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
