import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Confirmation sheet listing every item, its size, safety and consequences. Nothing is removed until the user
/// presses "Move to Trash" (or confirms "Delete Permanently" in a second dialog). Cancel is the default button.
struct ReviewSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var request: ReviewRequest
    @State private var runningApps: [NSRunningApplication] = []
    @State private var confirmPermanent = false
    @AppStorage(AppSettings.Key.showPermanentDelete) private var showPermanentDelete = true

    init(request: ReviewRequest) {
        _request = State(initialValue: request)
    }

    var body: some View {
        let removable = request.removableItems
        VStack(alignment: .leading, spacing: 0) {
            header(removable)
                .padding(20)
            if !runningApps.isEmpty {
                runningAppsBanner.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            List {
                ForEach($request.items) { $item in
                    ReviewRow(item: $item)
                }
            }
            // No alternating stripes: with few items they filled the empty space below the rows.
            .listStyle(.inset)
            Divider()
            footer(removable)
                .padding(16)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 460, idealHeight: 560)
        .onAppear(perform: refreshRunningApps)
        .alert("Delete \(removable.count) item\(removable.count == 1 ? "" : "s") permanently?", isPresented: $confirmPermanent) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Permanently", role: .destructive) {
                state.performDeletion(request, mode: .permanent)
            }
        } message: {
            Text("\(request.removableSize.formattedBytes) will be erased immediately. These items will not go to the Trash and cannot be recovered.")
        }
    }

    /// Title, total and a count of items per safety level.
    private func header(_ removable: [DeletionItem]) -> some View {
        let levels = Dictionary(grouping: removable, by: { $0.safety?.level ?? .review }).mapValues(\.count)
        let locked = request.items.filter { $0.verdict.isLocked }.count
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.heroGradient))
            VStack(alignment: .leading, spacing: 6) {
                Text(request.title).font(.title2.weight(.semibold))
                Text("\(removable.count) item\(removable.count == 1 ? "" : "s") selected · \(request.removableSize.formattedBytes)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 6) {
                    ForEach([SafetyLevel.safe, .review, .caution], id: \.self) { level in
                        if let count = levels[level] {
                            SafetyBadge(level: level, compact: true)
                            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if locked > 0 {
                        SafetyBadge(level: .protected, compact: true)
                        Text("\(locked) won't be touched").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Orange banner listing running apps that own these items, with Quit buttons.
    private var runningAppsBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Quit these apps first").font(.headline)
                Text("They use these files and may recreate them or misbehave if they disappear.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    ForEach(runningApps, id: \.processIdentifier) { app in
                        Button("Quit \(app.localizedName ?? app.bundleIdentifier ?? "app")") {
                            app.terminate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: refreshRunningApps)
                        }
                    }
                    Button("Check Again", action: refreshRunningApps)
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
    }

    /// Apps being uninstalled that are still running; removing them is blocked until they quit.
    private var runningTargets: [NSRunningApplication] {
        runningApps.filter { request.uninstallBundleIDs.contains($0.bundleIdentifier ?? "") }
    }

    private func footer(_ removable: [DeletionItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Moving to the Trash is reversible. The space is freed when you empty the Trash.", systemImage: "arrow.uturn.backward.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if showPermanentDelete {
                    Button("Delete Permanently…") { confirmPermanent = true }
                        .disabled(removable.isEmpty || !runningTargets.isEmpty)
                        .help("Skip the Trash. Asks for confirmation; cannot be undone.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                if !runningTargets.isEmpty {
                    Text("Quit \(runningTargets.compactMap(\.localizedName).joined(separator: ", ")) first")
                        .font(.callout).foregroundStyle(.orange)
                }
                Button("Move to Trash") { state.performDeletion(request, mode: .trash) }
                    .disabled(removable.isEmpty || !runningTargets.isEmpty)
            }
            .controlSize(.large)
        }
    }

    private func refreshRunningApps() {
        runningApps = RunningAppGuard.running(request.ownerBundleIDs)
    }
}

/// One row of the review sheet: checkbox (or lock), name, path, safety and size.
struct ReviewRow: View {
    @Binding var item: DeletionItem

    var body: some View {
        let locked = item.verdict.isLocked
        HStack(alignment: .top, spacing: 10) {
            if locked {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16)
            } else {
                Toggle("", isOn: $item.isChecked).toggleStyle(.checkbox).labelsHidden()
            }
            LazyIcon(path: item.path, size: 28)
                .opacity(locked ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium).lineLimit(1)
                    if let note = item.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(PathUtil.abbreviate(item.path)).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                if case .locked(let reason) = item.verdict {
                    Text("Protected: \(reason). This item will not be touched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let safety = item.safety {
                    Text("\(safety.whatItIs). \(safety.ifDeleted)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // The rating's notes already cover the policy's warnings (recent change, Documents/Desktop),
                    // so show them once rather than twice in different words.
                    ForEach(safety.notes, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.size.formattedBytes).font(.body.monospacedDigit().weight(.semibold))
                SafetyBadge(level: locked ? .protected : (item.safety?.level ?? .review), compact: true)
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isChecked || locked ? 1 : 0.55)
    }
}

/// Summary after a deletion: what was removed, what failed, and how free space changed.
struct DeletionOutcomeView: View {
    @Environment(\.dismiss) private var dismiss
    let outcome: DeletionOutcome

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: outcome.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(outcome.failures.isEmpty ? Theme.accent : .orange)
            Text(headline).font(.title2.weight(.semibold)).multilineTextAlignment(.center)

            if let reclaimed = outcome.measuredReclaimed {
                Text(reclaimedText(reclaimed))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if outcome.mode == .trash && !outcome.removed.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(Theme.accent)
                    Text("Items in the Trash still use disk space. Empty the Trash in Finder to free \(outcome.removedSize.formattedBytes).")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.08)))
            }
            if !outcome.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Couldn't remove \(outcome.failures.count) item\(outcome.failures.count == 1 ? "" : "s"):").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(outcome.failures, id: \.self) { failure in
                                Text("\(PathUtil.abbreviate(failure.path)): \(failure.message)")
                                    .font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
            HStack {
                if outcome.mode == .trash && !outcome.removed.isEmpty {
                    Button("Open Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash"))
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var headline: String {
        let count = outcome.removed.count
        let items = "\(count) item\(count == 1 ? "" : "s") (\(outcome.removedSize.formattedBytes))"
        return outcome.mode == .trash ? "Moved \(items) to the Trash" : "Permanently deleted \(items)"
    }

    private func reclaimedText(_ reclaimed: Int64) -> String {
        if reclaimed > 0 { return "Free space went up by \(reclaimed.formattedBytes)." }
        return outcome.mode == .trash
            ? "Free space is unchanged until the Trash is emptied."
            : "macOS hasn't reported the freed space yet. It can take a moment to update."
    }
}

/// History of everything removed, exportable as CSV.
struct ActivityLogView: View {
    @Environment(AppState.self) private var state
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ActivityEntry.date, order: .reverse)]
    @State private var selection = Set<ActivityEntry.ID>()

    var body: some View {
        let entries = state.activityEntries
            .filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || ($0.context ?? "").localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
        VStack(spacing: 0) {
            SummaryHeader(value: state.activityEntries.reduce(Int64(0)) { $0 + $1.size }.formattedBytes,
                          caption: "removed in \(state.activityEntries.count) items",
                          help: "Everything SpaceSweeper has moved to the Trash or deleted. Trashed items can be put back from the Trash in Finder.") {
                Button("Export CSV…") { export(entries) }
                    .disabled(entries.isEmpty)
            }
            .padding(18)
            Divider()
            if entries.isEmpty {
                ContentUnavailableView("Nothing removed yet", systemImage: "tray",
                                       description: Text("Items you remove will be listed here."))
                    .frame(maxHeight: .infinity)
            } else {
                Table(entries, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Date", value: \ActivityEntry.date) { (entry: ActivityEntry) in
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Action") { (entry: ActivityEntry) in
                        Label(entry.action.logLabel, systemImage: entry.action == .trash ? "trash" : "xmark.bin.fill")
                            .foregroundStyle(entry.action == .trash ? Theme.accent : .red)
                    }
                    .width(min: 130, ideal: 150)
                    TableColumn("Size", value: \ActivityEntry.size) { (entry: ActivityEntry) in
                        Text(entry.size.formattedBytes).monospacedDigit()
                    }
                    .width(min: 70, ideal: 90)
                    TableColumn("Path", value: \ActivityEntry.path) { (entry: ActivityEntry) in
                        PathCell(path: entry.path)
                    }
                    TableColumn("Context") { (entry: ActivityEntry) in
                        Text(entry.context ?? "").foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 140)
                }
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search log")
    }

    /// Saves the visible entries as CSV via the standard save panel.
    private func export(_ entries: [ActivityEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "SpaceSweeper Activity \(Date().formatted(.iso8601.year().month().day())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ActivityLog.csv(entries).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
