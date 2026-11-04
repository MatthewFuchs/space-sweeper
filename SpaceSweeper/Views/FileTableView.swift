import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Caches Finder icons by extension (or by path for packages such as apps).
@MainActor
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String, isPackage: Bool = false, isFolder: Bool = false) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let key: String
        if ext == "app" {
            key = path
        } else if isFolder || (isPackage && ext.isEmpty) {
            key = "/folder"
        } else {
            key = "." + ext
        }
        if let cached = cache[key] { return cached }
        let image: NSImage
        if ext == "app" {
            image = NSWorkspace.shared.icon(forFile: path)
        } else if key == "/folder" {
            image = NSWorkspace.shared.icon(for: .folder)
        } else {
            image = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        image.size = NSSize(width: 32, height: 32)
        cache[key] = image
        return image
    }
}

/// A file plus its safety rating, so the table can sort and filter by safety.
struct RatedFile: Identifiable, Hashable {
    let record: FileRecord
    let safety: SafetyAssessment

    var id: String { record.path }
    var name: String { record.name }
    var size: Int64 { record.size }
    var modified: Date { record.modified }
    var lastOpened: Date { record.lastOpened }
    var kind: String { record.kind }
    var path: String { record.path }
    /// Sort key: safest first when ascending.
    var safetyRank: Int { safety.level.rawValue }
}

/// Shared table for file lists (Large Files, Old Files). Every row carries a safety rating with an explanation;
/// the list can be filtered by rating, and the inspector explains the selected file. Also provides search,
/// sortable columns, checkboxes, Reveal in Finder, Quick Look (space bar) and a running total of the checked size.
struct FileTableView<Header: View>: View {
    let records: [FileRecord]
    /// Shown when no rows match.
    var emptyMessage = "No files match."
    @ViewBuilder var header: () -> Header

    @Environment(AppState.self) private var state
    @State private var rated: [RatedFile] = []
    @State private var visibleLevels: Set<SafetyLevel> = Set(SafetyLevel.allCases)
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\RatedFile.size, order: .reverse)]
    @State private var selection = Set<RatedFile.ID>()
    @State private var checked = Set<RatedFile.ID>()
    @State private var previewURL: URL?
    @AppStorage("showInspector") private var showInspector = true

    /// Rows after the safety filter and search, in the current sort order.
    private var rows: [RatedFile] {
        rated.filter { row in
            visibleLevels.contains(row.safety.level) && (search.isEmpty
                || row.path.localizedCaseInsensitiveContains(search)
                || row.kind.localizedCaseInsensitiveContains(search)
                || row.safety.whatItIs.localizedCaseInsensitiveContains(search))
        }
        .sorted(using: sortOrder)
    }

    private var tallies: [SafetyLevel: SafetyTally] {
        rated.reduce(into: [:]) { result, row in
            result[row.safety.level, default: SafetyTally()].count += 1
            result[row.safety.level, default: SafetyTally()].size += row.size
        }
    }

    var body: some View {
        let rows = self.rows
        let tallies = self.tallies
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                header()
                SafetyFilterBar(tallies: tallies, visible: $visibleLevels)
                if let safe = tallies[.safe], safe.count > 0 {
                    SafeSummaryCallout(tally: safe) {
                        checked.formUnion(rated.filter { $0.safety.level == .safe }.map(\.id))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            if rows.isEmpty {
                ContentUnavailableView(emptyMessage, systemImage: "doc.text.magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                table(rows)
            }
            footer(rows)
        }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide details about the selected file")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search name, path or kind")
        .onChange(of: records, initial: true) { _, _ in rate() }
        .onChange(of: state.junkItems) { _, _ in rate() }
    }

    /// Rates every record. Runs only when the records or junk list change, not on every redraw.
    private func rate() {
        let advisor = state.safetyAdvisor
        rated = records.map { RatedFile(record: $0, safety: advisor.assess(path: $0.path, modified: $0.modified, isPackage: $0.isPackage)) }
        let valid = Set(rated.map(\.id))
        checked.formIntersection(valid)
        selection.formIntersection(valid)
    }

    /// The sortable table. Kept in its own function so the type checker handles the column builder quickly.
    private func table(_ rows: [RatedFile]) -> some View {
        let maxSize = rows.map(\.size).max() ?? 1
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (row: RatedFile) in
                if row.safety.level == .protected {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).help(row.safety.whatItIs)
                } else {
                    Toggle("", isOn: binding(for: row.id)).toggleStyle(.checkbox).labelsHidden()
                }
            }
            .width(22)
            TableColumn("Name", value: \RatedFile.name) { (row: RatedFile) in
                FileNameCell(record: row.record, subtitle: row.safety.whatItIs)
            }
            .width(min: 150, ideal: 240)
            TableColumn("Safety", value: \RatedFile.safetyRank) { (row: RatedFile) in
                SafetyBadge(level: row.safety.level).help(row.safety.ifDeleted)
            }
            .width(min: 84, ideal: 92)
            TableColumn("Size", value: \RatedFile.size) { (row: RatedFile) in
                SizeWithBar(size: row.size, maxSize: maxSize)
            }
            .width(min: 72, ideal: 90)
            TableColumn("Last Modified", value: \RatedFile.modified) { (row: RatedFile) in
                Text(row.modified.formatted(date: .abbreviated, time: .omitted))
            }
            .width(min: 76, ideal: 100)
            TableColumn("Last Opened", value: \RatedFile.lastOpened) { (row: RatedFile) in
                LastOpenedCell(record: row.record)
            }
            .width(min: 76, ideal: 100)
            TableColumn("Kind", value: \RatedFile.kind) { (row: RatedFile) in
                Text(row.kind).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 100)
            TableColumn("Path", value: \RatedFile.path) { (row: RatedFile) in
                PathCell(path: row.path)
            }
            .width(min: 90, ideal: 260)
        }
        .contextMenu(forSelectionType: RatedFile.ID.self) { ids in
            Button("Reveal in Finder") { AppState.revealInFinder(Array(ids)) }
            Button("Quick Look") { previewURL = ids.first.map { URL(fileURLWithPath: $0) } }
            Divider()
            Button("Check") { checked.formUnion(ids.filter { id in rated.first { $0.id == id }?.safety.level != .protected }) }
            Button("Uncheck") { checked.subtract(ids) }
        } primaryAction: { ids in
            // Double-click reveals the item in Finder.
            AppState.revealInFinder(Array(ids))
        }
        .onKeyPress(.space) {
            togglePreview(rows: rows)
            return .handled
        }
        .quickLookPreview($previewURL, in: rows.map(\.record.url))
    }

    /// Details for the single selected row, or a legend explaining the ratings.
    @ViewBuilder
    private var inspector: some View {
        if selection.count == 1, let id = selection.first, let row = rated.first(where: { $0.id == id }) {
            ItemInspector(path: row.path, size: row.size, assessment: row.safety, modified: row.modified,
                          lastOpened: row.lastOpened, kind: row.kind,
                          onQuickLook: { previewURL = row.record.url })
        } else {
            EmptyInspector()
        }
    }

    /// Footer with checked count/size, a breakdown of anything that isn't rated "safe", and actions.
    private func footer(_ rows: [RatedFile]) -> some View {
        let checkedRows = rated.filter { checked.contains($0.id) }
        let needsReview = checkedRows.filter { $0.safety.level != .safe }.count
        return SelectionFooter(
            checkedCount: checkedRows.count,
            checkedSize: checkedRows.reduce(0) { $0 + $1.size },
            totalCount: rows.count,
            note: needsReview > 0 ? "\(needsReview) not rated Safe" : nil,
            onCheckAll: { checked.formUnion(rows.filter { $0.safety.level != .protected }.map(\.id)) },
            onUncheckAll: { checked.removeAll() },
            onReveal: { AppState.revealInFinder(selection.isEmpty ? checkedRows.map(\.path) : Array(selection)) },
            onQuickLook: { togglePreview(rows: rows) },
            onRemove: state.deletionEnabled ? { state.requestDeletion(paths: checkedRows.map(\.path)) } : nil
        )
    }

    /// Checkbox binding for one row.
    private func binding(for id: RatedFile.ID) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            })
    }

    /// Space bar: opens Quick Look for the highlighted (or first checked) row, or closes it.
    private func togglePreview(rows: [RatedFile]) {
        if previewURL != nil {
            previewURL = nil
        } else if let id = selection.first ?? rows.first(where: { checked.contains($0.id) })?.id {
            previewURL = URL(fileURLWithPath: id)
        }
    }
}

/// Icon + file name with a short "what it is" line underneath; the tooltip shows the full path.
struct FileNameCell: View {
    let record: FileRecord
    var subtitle: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.icon(forPath: record.path, isPackage: record.isPackage))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.name).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .help(record.path)
    }
}

/// "Last opened" date with a tooltip saying where the date came from.
struct LastOpenedCell: View {
    let record: FileRecord

    var body: some View {
        Text(record.lastOpened.formatted(date: .abbreviated, time: .omitted))
            .help(record.lastUsed == nil ? "From the file's access time (Spotlight had no record)" : "From Spotlight")
    }
}

/// Home-abbreviated path, truncated in the middle so both ends stay visible.
struct PathCell: View {
    let path: String

    var body: some View {
        Text(PathUtil.abbreviate(path))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(.secondary)
            .help(path)
    }
}

/// Bottom bar for every list: count and size of checked items plus common actions.
struct SelectionFooter: View {
    let checkedCount: Int
    let checkedSize: Int64
    let totalCount: Int
    /// Optional warning shown next to the checked total, e.g. "2 not rated Safe".
    var note: String?
    var onCheckAll: () -> Void
    var onUncheckAll: () -> Void
    var onReveal: () -> Void
    var onQuickLook: (() -> Void)?
    var onRemove: (() -> Void)?
    var removeTitle = "Move to Trash…"

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Check All Shown", action: onCheckAll)
                Button("Uncheck All", action: onUncheckAll)
            } label: {
                Image(systemName: "checklist")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Check or uncheck items")

            if checkedCount > 0 {
                Text("\(checkedCount) checked · \(checkedSize.formattedBytes)")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                if let note {
                    Label(note, systemImage: "eye.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("\(totalCount.formatted()) items").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder", action: onReveal)
            if let onQuickLook {
                Button("Quick Look", action: onQuickLook)
                    .help("Preview the selected item (Space)")
            }
            if let onRemove {
                Button(removeTitle, action: onRemove)
                    .buttonStyle(.borderedProminent)
                    .disabled(checkedCount == 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
