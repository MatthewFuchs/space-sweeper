import QuickLook
import SwiftUI

/// Installed apps with size and last-used date; uninstalling is wired up in AppState.
struct ApplicationsView: View {
    @Environment(AppState.self) private var state
    @State private var sortOrder = [KeyPathComparator(\AppInfo.sizeSortKey, order: .reverse)]
    @State private var selection = Set<AppInfo.ID>()
    @State private var checked = Set<AppInfo.ID>()
    @State private var search = ""
    @State private var previewURL: URL?

    private var rows: [AppInfo] {
        let apps = state.apps.apps
        let filtered = search.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(search) || ($0.bundleID ?? "").localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            SummaryHeader(value: state.apps.apps.reduce(Int64(0)) { $0 + ($1.size ?? 0) }.formattedBytes,
                          caption: "in \(state.apps.apps.count) apps",
                          help: "Apps in /Applications and ~/Applications. Uninstalling also removes the app's leftover files. Apple system apps are locked.") {
                HStack(spacing: 8) {
                    if state.apps.isLoading || state.isPreparingUninstall { ProgressView().controlSize(.small) }
                    Button("Reload Apps") { state.apps.load() }
                        .disabled(state.apps.isLoading)
                        .help("Reload the list of applications")
                }
            }
                .padding(18)
            Divider()
            if state.apps.isLoading && state.apps.apps.isEmpty {
                LoadingView(message: "Finding apps…")
            } else if let error = state.apps.loadError, state.apps.apps.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't list applications", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { state.apps.load() }
                }
            } else if rows.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No apps found" : "No matches", systemImage: "square.grid.2x2")
            } else {
                table(rows)
            }
            footer(rows)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .task {
            if state.apps.apps.isEmpty { state.apps.load() }
        }

    }

    private func table(_ rows: [AppInfo]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (app: AppInfo) in
                if app.protectionReason == nil {
                    Toggle("", isOn: binding(app.id)).toggleStyle(.checkbox).labelsHidden()
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help(app.protectionReason ?? "")
                }
            }
            .width(22)
            TableColumn("Name", value: \AppInfo.name) { (app: AppInfo) in
                AppNameCell(app: app)
            }
            .width(min: 180, ideal: 240)
            TableColumn("Version") { (app: AppInfo) in
                Text(app.version ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Size", value: \AppInfo.sizeSortKey) { (app: AppInfo) in
                if let size = app.size {
                    Text(size.formattedBytes).monospacedDigit()
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Last Used", value: \AppInfo.lastUsedSortKey) { (app: AppInfo) in
                Text(app.lastUsed?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")
                    .foregroundStyle(app.lastUsed == nil ? .secondary : .primary)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Location", value: \AppInfo.path) { (app: AppInfo) in
                PathCell(path: (app.path as NSString).deletingLastPathComponent)
            }
            .width(min: 120, ideal: 200)
        }
        .contextMenu(forSelectionType: AppInfo.ID.self) { ids in
            Button("Reveal in Finder") { AppState.revealInFinder(Array(ids)) }
            Button("Check") { checked.formUnion(ids.filter { id in state.apps.apps.first { $0.id == id }?.protectionReason == nil }) }
            Button("Uncheck") { checked.subtract(ids) }
        } primaryAction: { ids in
            AppState.revealInFinder(Array(ids))
        }
        .onKeyPress(.space) {
            previewURL = previewURL == nil ? selection.first.map { URL(fileURLWithPath: $0) } : nil
            return .handled
        }
        .quickLookPreview($previewURL, in: rows.map(\.url))
    }

    private func footer(_ rows: [AppInfo]) -> some View {
        let checkedApps = state.apps.apps.filter { checked.contains($0.id) }
        return SelectionFooter(
            checkedCount: checkedApps.count,
            checkedSize: checkedApps.reduce(0) { $0 + ($1.size ?? 0) },
            totalCount: rows.count,
            onCheckAll: { checked.formUnion(rows.filter { $0.protectionReason == nil }.map(\.id)) },
            onUncheckAll: { checked.removeAll() },
            onReveal: { AppState.revealInFinder(selection.isEmpty ? checkedApps.map(\.path) : Array(selection)) },
            onQuickLook: { previewURL = selection.first.map { URL(fileURLWithPath: $0) } },
            onRemove: state.uninstallEnabled ? { state.requestUninstall(checkedApps) } : nil,
            removeTitle: "Uninstall…")
    }

    private func binding(_ id: AppInfo.ID) -> Binding<Bool> {
        Binding(get: { checked.contains(id) }, set: { isOn in
            if isOn { checked.insert(id) } else { checked.remove(id) }
        })
    }
}

struct AppNameCell: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 8) {
            LazyIcon(path: app.path, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1)
                if let reason = app.protectionReason {
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .help(app.bundleID ?? app.path)
    }
}

/// Folders the scanner couldn't read or skipped on purpose.
struct CouldntScanView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var selection = Set<SkippedPath.ID>()

    var body: some View {
        let skipped = (state.result?.skipped ?? []).filter {
            search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || $0.reason.localizedCaseInsensitiveContains(search)
        }
        VStack(spacing: 0) {
            SummaryHeader(value: "\(state.result?.skipped.count ?? 0)", caption: "folders couldn't be scanned",
                          help: "Skipped because macOS protects them, they couldn't be read, or they're cloud placeholders. Their size isn't counted anywhere else.")
                .padding(18)
            Divider()
            if !state.hasFullDiskAccess {
                HStack {
                    Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                    Text("Grant Full Disk Access to include most of these.")
                    Spacer()
                    Button("Open System Settings") { FullDiskAccess.openSettings() }
                }
                .padding(10)
                .background(Theme.accent.opacity(0.08))
            }
            Table(skipped, selection: $selection) {
                TableColumn("Path") { (item: SkippedPath) in PathCell(path: item.path) }
                    .width(min: 300, ideal: 500)
                TableColumn("Reason") { (item: SkippedPath) in Text(item.reason).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: SkippedPath.ID.self) { ids in
                Button("Reveal in Finder") { AppState.revealInFinder(Array(ids)) }
            } primaryAction: { ids in
                AppState.revealInFinder(Array(ids))
            }
            HStack {
                Text("\(skipped.count) locations").foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { AppState.revealInFinder(Array(selection)) }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search skipped paths")
    }
}
