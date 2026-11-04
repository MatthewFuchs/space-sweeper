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

/// Shared table for file lists (Large Files, Old Files): search, sortable columns, checkboxes,
/// Reveal in Finder, Quick Look (spacebar) and a running total of the checked size.
struct FileTableView<Header: View>: View {
    let records: [FileRecord]
    /// Called with the checked records when the user asks to remove them. Nil hides the button.
    var onRemove: (([FileRecord]) -> Void)?
    @ViewBuilder var header: () -> Header

    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\FileRecord.size, order: .reverse)]
    @State private var selection = Set<FileRecord.ID>()
    @State private var checked = Set<FileRecord.ID>()
    @State private var previewURL: URL?

    private var rows: [FileRecord] {
        let filtered = search.isEmpty ? records : records.filter {
            $0.path.localizedCaseInsensitiveContains(search) || $0.kind.localizedCaseInsensitiveContains(search)
        }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            header()
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()
            table(rows)
            footer(rows)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search name, path or kind")
        .onChange(of: records) { _, newRecords in
            // Drop checks/selection for rows that disappeared (e.g. after deletion or a rescan).
            let valid = Set(newRecords.map(\.id))
            checked.formIntersection(valid)
            selection.formIntersection(valid)
        }
    }

    /// The sortable table. Kept in its own function so the type checker handles the column builder quickly.
    private func table(_ rows: [FileRecord]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { (record: FileRecord) in
                Toggle("", isOn: binding(for: record.id))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            .width(22)
            TableColumn("Name", value: \FileRecord.name) { (record: FileRecord) in
                FileNameCell(record: record)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Size", value: \FileRecord.size) { (record: FileRecord) in
                Text(record.size.formattedBytes).monospacedDigit()
            }
            .width(min: 70, ideal: 85)
            TableColumn("Last Modified", value: \FileRecord.modified) { (record: FileRecord) in
                Text(record.modified.formatted(date: .abbreviated, time: .omitted))
            }
            .width(min: 90, ideal: 105)
            TableColumn("Last Opened", value: \FileRecord.lastOpened) { (record: FileRecord) in
                LastOpenedCell(record: record)
            }
            .width(min: 90, ideal: 105)
            TableColumn("Kind", value: \FileRecord.kind) { (record: FileRecord) in
                Text(record.kind).lineLimit(1).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Path", value: \FileRecord.path) { (record: FileRecord) in
                PathCell(path: record.path)
            }
            .width(min: 160, ideal: 360)
        }
        .contextMenu(forSelectionType: FileRecord.ID.self) { ids in
            Button("Reveal in Finder") { AppState.revealInFinder(Array(ids)) }
            Button("Quick Look") { previewURL = ids.first.map { URL(fileURLWithPath: $0) } }
            Divider()
            Button("Check") { checked.formUnion(ids) }
            Button("Uncheck") { checked.subtract(ids) }
        } primaryAction: { ids in
            // Double-click reveals the item in Finder.
            AppState.revealInFinder(Array(ids))
        }
        .onKeyPress(.space) {
            togglePreview(rows: rows)
            return .handled
        }
        .quickLookPreview($previewURL, in: rows.map(\.url))
    }

    private func footer(_ rows: [FileRecord]) -> some View {
        let checkedRecords = records.filter { checked.contains($0.id) }
        let removeAction: (() -> Void)? = onRemove.map { remove in { remove(checkedRecords) } }
        return SelectionFooter(
            checkedCount: checkedRecords.count,
            checkedSize: checkedRecords.reduce(0) { $0 + $1.size },
            totalCount: rows.count,
            onCheckAll: { checked.formUnion(rows.map(\.id)) },
            onUncheckAll: { checked.removeAll() },
            onReveal: { AppState.revealInFinder(revealTargets(checkedRecords)) },
            onQuickLook: { togglePreview(rows: rows) },
            onRemove: removeAction
        )
    }

    private func binding(for id: FileRecord.ID) -> Binding<Bool> {
        Binding(
            get: { checked.contains(id) },
            set: { isOn in
                if isOn { checked.insert(id) } else { checked.remove(id) }
            })
    }

    private func revealTargets(_ checkedRecords: [FileRecord]) -> [String] {
        selection.isEmpty ? checkedRecords.map(\.path) : Array(selection)
    }

    private func togglePreview(rows: [FileRecord]) {
        if previewURL != nil {
            previewURL = nil
        } else if let id = selection.first ?? rows.first(where: { checked.contains($0.id) })?.id {
            previewURL = URL(fileURLWithPath: id)
        }
    }
}

/// Icon + file name cell; the tooltip shows the full path.
struct FileNameCell: View {
    let record: FileRecord

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(forPath: record.path, isPackage: record.isPackage))
                .resizable()
                .frame(width: 16, height: 16)
            Text(record.name).lineLimit(1)
        }
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
