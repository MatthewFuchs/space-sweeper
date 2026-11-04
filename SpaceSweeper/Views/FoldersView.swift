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

    var body: some View {
        VStack(spacing: 0) {
            SummaryHeader(value: folderTotal, caption: folderCaption,
                          help: "Where your space goes, largest first. Expand a folder to drill down; the badge shows how safe each one is to remove.")
                .padding(18)
            Divider()
            if let store {
                outline(store)
                footer(store)
            }
        }
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
                        Toggle("", isOn: binding(row.id)).toggleStyle(.checkbox).labelsHidden()
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
            onQuickLook: nil,
            onRemove: state.deletionEnabled ? { state.requestDeletion(paths: checkedPaths) } : nil)
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
    }
}
