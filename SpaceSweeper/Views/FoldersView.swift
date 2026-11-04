import QuickLook
import SwiftUI

/// Reference wrapper so tree rows can share one copy of the (large) tree.
final class TreeStore {
    let tree: FolderTree
    init(tree: FolderTree) { self.tree = tree }
}

/// A row of the folder outline. Children are produced lazily when SwiftUI expands the row.
struct TreeRow: Identifiable, Hashable {
    let id: Int32
    let store: TreeStore

    var node: TreeNode { store.tree.nodes[Int(id)] }
    var path: String { store.tree.path(of: id) }
    var isCheckable: Bool { node.kind != .other && node.kind != .root }

    /// Share of the parent folder (1.0 for roots), used for the size bar.
    var fractionOfParent: Double {
        let node = self.node
        guard node.parent >= 0 else { return 1 }
        let parentSize = store.tree.nodes[Int(node.parent)].size
        return parentSize > 0 ? Double(node.size) / Double(parentSize) : 0
    }

    var children: [TreeRow]? {
        let children = node.children
        return children.isEmpty ? nil : children.map { TreeRow(id: $0, store: store) }
    }

    static func == (lhs: TreeRow, rhs: TreeRow) -> Bool { lhs.id == rhs.id && lhs.store === rhs.store }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// DaisyDisk-style drill-down of folder sizes, largest first.
struct FoldersView: View {
    @Environment(AppState.self) private var state
    @State private var store: TreeStore?
    @State private var selection = Set<Int32>()
    @State private var checked = Set<Int32>()
    @State private var search = ""
    @State private var previewURL: URL?
    /// Folder shown by the map (nil = top level).
    @State private var mapFocus: Int32?
    @AppStorage("foldersShowMap") private var showMap = true

    var body: some View {
        VStack(spacing: 0) {
            SummaryHeader(value: folderTotal, caption: folderCaption,
                          help: "Where your space goes, largest first. In the map, bigger tiles use more space: double-click a folder to open it. In the list, expand folders to drill down.") {
                Picker("View", selection: $showMap) {
                    Label("Map", systemImage: "square.grid.3x3.square").tag(true)
                    Label("List", systemImage: "list.bullet.indent").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Switch between the space map and the folder list")
            }
                .padding(18)
            Divider()
            if let store {
                if showMap && search.isEmpty {
                    FolderMapView(tree: store.tree, focus: $mapFocus, selection: $selection, checked: $checked,
                                  onPreview: { previewURL = URL(fileURLWithPath: $0) })
                } else {
                    outline(store)
                }
                footer(store)
            }
        }
        .quickLookPreview($previewURL)
        .task(id: state.result?.date) { rebuildStore() }
        .onChange(of: state.result?.totalSize) { _, _ in rebuildStore() }
    }

    /// Total size of everything scanned.
    private var folderTotal: String { (store?.tree.totalSize ?? 0).formattedBytes }

    /// "in ~" for a single root, otherwise "in N locations".
    private var folderCaption: String {
        guard let tree = store?.tree else { return "" }
        if tree.rootIDs.count == 1, let root = tree.rootIDs.first {
            return "in \(PathUtil.abbreviate(tree.nodes[Int(root)].name)), largest first"
        }
        return "in \(tree.rootIDs.count) locations, largest first"
    }

    private func rebuildStore() {
        store = state.result.map { TreeStore(tree: $0.tree) }
        checked.removeAll()
        selection.removeAll()
        mapFocus = nil
    }

    /// With a search term, shows a flat list of matching folders/files; otherwise the expandable tree.
    private func rows(_ store: TreeStore) -> [TreeRow] {
        if search.isEmpty {
            // With a single scan root, start one level in: a lone collapsed "~" row hid everything useful.
            let tree = store.tree
            if tree.rootIDs.count == 1, let root = tree.rootIDs.first {
                return tree.nodes[Int(root)].children.map { TreeRow(id: $0, store: store) }
            }
            return tree.rootIDs.map { TreeRow(id: $0, store: store) }
        }
        return store.tree.nodes.indices
            .filter { store.tree.nodes[$0].kind != .other && store.tree.nodes[$0].name.localizedCaseInsensitiveContains(search) }
            .sorted { store.tree.nodes[$0].size > store.tree.nodes[$1].size }
            .prefix(500)
            .map { TreeRow(id: Int32($0), store: store) }
    }

    private func outline(_ store: TreeStore) -> some View {
        let advisor = state.safetyAdvisor
        return Table(rows(store), children: \.children, selection: $selection) {
            TableColumn("") { (row: TreeRow) in
                if row.isCheckable {
                    if ProtectionPolicy(home: state.homePath).verdict(for: row.path).isLocked {
                        // Same lock affordance as the other lists, instead of an unexplained gap.
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                            .help("Protected: SpaceSweeper won't delete this folder")
                    } else {
                            Toggle("Select \(row.node.name)", isOn: binding(row.id)).toggleStyle(.checkbox).labelsHidden()
                    }
                }
            }
            .width(22)
            TableColumn("Name") { (row: TreeRow) in
                TreeNameCell(row: row, showPath: !search.isEmpty)
            }
            .width(min: 220, ideal: 360)
            TableColumn("Size") { (row: TreeRow) in
                Text(row.node.size.formattedBytes).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("") { (row: TreeRow) in
                SizeBar(fraction: row.fractionOfParent)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Safety") { (row: TreeRow) in
                if row.node.kind != .other {
                    let assessment = advisor.assess(path: row.path, isPackage: row.node.kind == .package)
                    SafetyBadge(level: assessment.level, compact: true)
                        .help("\(assessment.whatItIs). \(assessment.ifDeleted)")
                }
            }
            .width(min: 76, ideal: 84)
            TableColumn("Items") { (row: TreeRow) in
                Text(row.node.kind == .other ? "" : row.node.itemCount.formatted())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: Int32.self) { ids in
            Button("Reveal in Finder") { AppState.revealInFinder(ids.map { store.tree.path(of: $0) }) }
            Button("Check") { checked.formUnion(ids) }
            Button("Uncheck") { checked.subtract(ids) }
        } primaryAction: { ids in
            AppState.revealInFinder(ids.map { store.tree.path(of: $0) })
        }
        .onKeyPress(.space) {
            togglePreview(store)
            return .handled
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Find folder or file")
    }

    private func footer(_ store: TreeStore) -> some View {
        let checkedPaths = checked.map { store.tree.path(of: $0) }
        let size = checked.reduce(Int64(0)) { $0 + store.tree.nodes[Int($1)].size }
        return SelectionFooter(
            checkedCount: checked.count, checkedSize: size, totalCount: rows(store).count,
            onCheckAll: { checked.formUnion(selection) },
            onUncheckAll: { checked.removeAll() },
            onReveal: { AppState.revealInFinder(selection.isEmpty ? checkedPaths : selection.map { store.tree.path(of: $0) }) },
            onQuickLook: { togglePreview(store) },
            onRemove: state.deletionEnabled ? { state.requestDeletion(paths: checkedPaths) } : nil)
    }

    /// Space bar / Quick Look button: previews the selected item, or closes the preview.
    private func togglePreview(_ store: TreeStore) {
        if previewURL != nil {
            previewURL = nil
        } else if let id = selection.first, store.tree.nodes[Int(id)].kind != .other {
            previewURL = URL(fileURLWithPath: store.tree.path(of: id))
        }
    }

    private func binding(_ id: Int32) -> Binding<Bool> {
        Binding(get: { checked.contains(id) }, set: { isOn in
            if isOn { checked.insert(id) } else { checked.remove(id) }
        })
    }
}

/// Icon, name and (when searching) the full path of a tree node.
struct TreeNameCell: View {
    let row: TreeRow
    let showPath: Bool

    var body: some View {
        let node = row.node
        HStack(spacing: 6) {
            switch node.kind {
            case .other:
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary).frame(width: 16)
            case .file, .package:
                Image(nsImage: IconCache.icon(forPath: node.name, isPackage: node.kind == .package))
                    .resizable().frame(width: 16, height: 16)
            case .directory, .root:
                Image(systemName: "folder.fill").foregroundStyle(Theme.accent).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(node.kind == .root ? PathUtil.abbreviate(node.name) : node.name)
                    .foregroundStyle(node.kind == .other ? .secondary : .primary)
                    .lineLimit(1)
                if showPath {
                    Text(PathUtil.abbreviate(row.path)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

/// Horizontal royal-blue bar showing a fraction of the parent's size.
struct SizeBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accent.opacity(0.12))
                Capsule().fill(Theme.accent).frame(width: max(2, geometry.size.width * min(1, fraction)))
            }
        }
        .frame(height: 8)
        .help(fraction.formatted(.percent.precision(.fractionLength(1))) + " of parent folder")
        .accessibilityLabel(fraction.formatted(.percent.precision(.fractionLength(0))) + " of parent folder")
    }
}


/// Squarified treemap of one folder: each tile's area is proportional to its size.
/// Click selects, double-click opens a folder (or previews a file), breadcrumbs go back up.
struct FolderMapView: View {
    let tree: FolderTree
    @Binding var focus: Int32?
    @Binding var selection: Set<Int32>
    @Binding var checked: Set<Int32>
    var onPreview: (String) -> Void

    /// Tiles shown at most; the rest are drawn as one "smaller items" tile to keep the map readable.
    private let maxTiles = 60

    /// Children of the focused folder (or the scan roots / single root's children at the top).
    private var children: [Int32] {
        if let focus { return tree.nodes[Int(focus)].children }
        if tree.rootIDs.count == 1, let root = tree.rootIDs.first { return tree.nodes[Int(root)].children }
        return tree.rootIDs
    }

    /// Path from the top level to the focused folder, for breadcrumbs.
    private var trail: [Int32] {
        var ids: [Int32] = []
        var current = focus
        while let id = current {
            ids.insert(id, at: 0)
            let parent = tree.nodes[Int(id)].parent
            current = parent >= 0 && !(tree.rootIDs.count == 1 && tree.rootIDs.contains(parent)) ? parent : nil
        }
        return ids
    }

    var body: some View {
        let ids = Array(children.filter { tree.nodes[Int($0)].size > 0 }.prefix(maxTiles))
        let restSize = children.dropFirst(maxTiles).reduce(Int64(0)) { $0 + tree.nodes[Int($1)].size }
        VStack(alignment: .leading, spacing: 0) {
            breadcrumbs
            GeometryReader { geometry in
                let sizes = ids.map { Double(tree.nodes[Int($0)].size) } + (restSize > 0 ? [Double(restSize)] : [])
                let rects = Treemap.layout(sizes: sizes, in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: 6, dy: 6))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        tile(id: id, rect: rects[index], colorIndex: index)
                    }
                    if restSize > 0, let rect = rects.last {
                        MapTile(title: "\(children.count - ids.count) smaller items", size: restSize,
                                color: Color.gray.opacity(0.35), isSelected: false, symbol: "ellipsis")
                            .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Space map")
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            Button {
                focus = nil
                selection.removeAll()
            } label: {
                Label(topTitle, systemImage: "house")
            }
            .buttonStyle(.borderless)
            ForEach(trail, id: \.self) { id in
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
                Button(tree.nodes[Int(id)].name) {
                    focus = id
                    selection.removeAll()
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Text("Double-click a folder to open it").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var topTitle: String {
        if tree.rootIDs.count == 1, let root = tree.rootIDs.first { return PathUtil.abbreviate(tree.nodes[Int(root)].name) }
        return "All locations"
    }

    private func tile(id: Int32, rect: CGRect, colorIndex: Int) -> some View {
        let node = tree.nodes[Int(id)]
        let isFolder = (node.kind == .directory || node.kind == .package || node.kind == .root) && !node.children.isEmpty
        let color: Color = node.kind == .other ? Color.gray.opacity(0.35)
            : Theme.mapPalette[colorIndex % Theme.mapPalette.count]
        return MapTile(title: node.name, size: node.size, color: color, isSelected: selection.contains(id),
                       symbol: node.kind == .other ? "ellipsis" : (isFolder ? "folder.fill" : nil),
                       isChecked: checked.contains(id))
            .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
            .position(x: rect.midX, y: rect.midY)
            .onTapGesture(count: 2) {
                if isFolder {
                    focus = id
                    selection.removeAll()
                } else if node.kind != .other {
                    onPreview(tree.path(of: id))
                }
            }
            .onTapGesture { selection = node.kind == .other ? [] : [id] }
            .contextMenu {
                if node.kind != .other {
                    if isFolder { Button("Open") { focus = id } }
                    Button("Quick Look") { onPreview(tree.path(of: id)) }
                    Button("Reveal in Finder") { AppState.revealInFinder([tree.path(of: id)]) }
                    Divider()
                    if checked.contains(id) {
                        Button("Uncheck") { checked.remove(id) }
                    } else {
                        Button("Check for Removal") { checked.insert(id) }
                    }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isFolder ? "Double-tap to open this folder" : "")
    }
}

/// One rectangle in the space map. Shows its name and size when there's room; always has a tooltip.
struct MapTile: View {
    let title: String
    let size: Int64
    let color: Color
    let isSelected: Bool
    var symbol: String?
    var isChecked = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.gradient)
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.15), lineWidth: isSelected ? 3 : 1)
                if geometry.size.width > 70 && geometry.size.height > 34 {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            if let symbol { Image(systemName: symbol).font(.caption2) }
                            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                        Text(size.formattedBytes).font(.caption2.monospacedDigit()).opacity(0.85)
                    }
                    .foregroundStyle(.white)
                    .padding(6)
                }
                if isChecked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
        .contentShape(Rectangle())
        .help("\(title) · \(size.formattedBytes)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(size.formattedBytes)\(isChecked ? ", checked" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
