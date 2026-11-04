import AppKit
import SwiftUI

/// Toolbar: scan locations, Rescan / Cancel.
struct ScanToolbar: ToolbarContent {
    @Environment(AppState.self) private var state
    @State private var showLocations = false

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showLocations.toggle()
            } label: {
                Label("Scan Locations", systemImage: "externaldrive.badge.plus")
            }
            .help("Choose which folders and volumes to scan")
            .popover(isPresented: $showLocations, arrowEdge: .bottom) {
                ScanLocationsView()
            }

            if state.isScanning {
                Button(role: .cancel) {
                    state.cancelScan()
                } label: {
                    Label("Cancel Scan", systemImage: "xmark.circle")
                }
                .help("Stop the scan in progress")
            } else {
                Button {
                    state.startScan()
                } label: {
                    Label(state.result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan the selected locations again (⌘R)")
            }
        }
    }
}

/// Popover listing scan roots with add/remove controls.
struct ScanLocationsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scan Locations").font(.headline)
            ForEach(state.scanRoots, id: \.self) { root in
                HStack {
                    Image(systemName: root.hasPrefix("/Volumes/") ? "externaldrive" : "folder")
                        .foregroundStyle(Theme.accent)
                    Text(PathUtil.abbreviate(root)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button {
                        state.removeScanRoot(root)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.scanRoots.count == 1)
                    .help("Remove this location")
                }
            }
            Divider()
            HStack {
                Button("Add Folder or Volume…", action: addFolder)
                Spacer()
                Button("Reset to Home") { state.scanRoots = [state.homePath] }
            }
            Text("Changes apply on the next Rescan.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 380)
    }

    /// Lets the user pick extra folders or volumes (starts in /Volumes).
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        if panel.runModal() == .OK {
            state.addScanRoots(panel.urls)
        }
    }
}

/// Live progress strip shown at the bottom of the window during a scan.
struct ScanProgressBar: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.progress.phase == .finalizing ? "Finishing up…" : "Scanning — \(state.progress.items.formatted()) items, \(state.progress.bytes.formattedBytes)")
                    .font(.callout.monospacedDigit())
                Text(PathUtil.abbreviate(state.progress.currentPath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            ElapsedTimeText(start: state.scanStart)
            Button("Cancel") { state.cancelScan() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// m:ss elapsed since `start`, refreshed every second.
struct ElapsedTimeText: View {
    let start: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(start ?? context.date))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// Full-pane progress shown during the first scan, when there are no results to display yet.
struct ScanInProgressView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Scanning \(state.progress.items.formatted()) items…")
                .font(.title3.monospacedDigit())
            Text(PathUtil.abbreviate(state.progress.currentPath))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 520)
            Button("Cancel") { state.cancelScan() }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Empty state before the first scan.
struct NoScanView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ContentUnavailableView {
            Label("No scan yet", systemImage: "magnifyingglass")
        } description: {
            Text("Scan \(state.scanRoots.map { PathUtil.abbreviate($0) }.joined(separator: ", ")) to find large, old and regenerable files.")
            if let error = state.scanError {
                Text(error).foregroundStyle(.red)
            }
        } actions: {
            Button("Start Scan") { state.startScan() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

/// Free-space summary pinned to the bottom of the sidebar.
struct DiskSummaryFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let disk = state.disk {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(disk.used), total: Double(max(disk.total, 1)))
                    .tint(Theme.accent)
                Text("\(disk.available.formattedBytes) free of \(disk.total.formattedBytes)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let trash = state.trash, trash.size > 0 {
                    Label("\(trash.size.formattedBytes) in Trash", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let result = state.result {
                    Text("Scanned \(result.date.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Visible way into Settings, which otherwise lives only in the app menu (⌘,).
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
                .help("Open Settings (⌘,)")
            }
            .padding(12)
        }
    }
}

/// First-launch explainer shown when Full Disk Access is missing.
struct FullDiskAccessView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.shield")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("SpaceSweeper needs Full Disk Access")
                .font(.largeTitle.weight(.semibold))
            VStack(alignment: .leading, spacing: 10) {
                Text("macOS hides parts of your home folder (Mail, Safari, app containers, caches, and other apps' data) from apps by default. Without access, SpaceSweeper would under-report how much space is used and miss many caches.")
                Text("SpaceSweeper only reads file sizes and dates. It never uploads anything, and nothing is deleted without your confirmation.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 520)

            VStack(alignment: .leading, spacing: 6) {
                Label("Click **Open System Settings**", systemImage: "1.circle.fill")
                Label("Turn on **SpaceSweeper** in the Full Disk Access list (use **+** if it's missing)", systemImage: "2.circle.fill")
                Label("Return here. If macOS asks, choose **Quit & Reopen**", systemImage: "3.circle.fill")
            }
            .foregroundStyle(.primary)
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.accent.opacity(0.08)))

            HStack(spacing: 12) {
                Button("Continue Without Access") { state.fullDiskAccessDismissed = true }
                Button("Check Again") { state.refreshFullDiskAccess() }
                Button("Open System Settings") { FullDiskAccess.openSettings() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Dismissible banner for the current notice, with its action button.
struct NoticeBanner: View {
    @Environment(AppState.self) private var state
    let notice: AppNotice

    private var tint: Color {
        switch notice.kind {
        case .info: return Theme.accent
        case .warning: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.kind.symbol).foregroundStyle(tint).font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title).font(.headline)
                Text(notice.message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let action = notice.action {
                Button(action.title) { perform(action) }
            }
            Button {
                state.notice = nil
            } label: {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func perform(_ action: AppNotice.Action) {
        state.notice = nil
        switch action {
        case .rescan: state.startScan()
        case .openFullDiskAccess: FullDiskAccess.openSettings()
        case .retryApps: state.apps.load()
        }
    }
}

/// Centered spinner with a short message, used while something loads for the first time.
struct LoadingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
