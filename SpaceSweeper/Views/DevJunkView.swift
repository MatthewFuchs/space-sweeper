import SwiftUI

/// Regenerable developer folders and caches, grouped by tool, each with an explanation.
struct DevJunkView: View {
    @Environment(AppState.self) private var state
    @State private var checked = Set<DevJunkItem.ID>()
    @State private var selection: DevJunkItem.ID?
    @State private var search = ""

    private var visibleItems: [DevJunkItem] {
        guard !search.isEmpty else { return state.junkItems }
        return state.junkItems.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        let items = visibleItems
        let checkedItems = state.junkItems.filter { checked.contains($0.id) }
        let deletable = state.junkItems.filter(\.isDeletable)
        let safe = deletable.filter { $0.safety == .safe }
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SummaryHeader(
                    value: deletable.reduce(0) { $0 + $1.size }.formattedBytes,
                    caption: "of developer junk in \(deletable.count) places",
                    help: "Build outputs, caches and downloads that developer tools can recreate. Select an item to see what it is and what happens if you delete it.")
                if !safe.isEmpty {
                    SafeActionBar(tally: SafetyTally(count: safe.count, size: safe.reduce(0) { $0 + $1.size }),
                                  allSelected: Set(safe.map(\.id)).isSubset(of: checked),
                                  onSelectSafe: { checked.formUnion(safe.map(\.id)) },
                                  onDeselectSafe: { checked.subtract(safe.map(\.id)) })
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            if state.isComputingJunk && state.junkItems.isEmpty {
                ProgressView("Measuring developer folders…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "sparkles",
                                       description: Text(search.isEmpty ? "No developer junk over 1 MB." : "No matches."))
            } else {
                List(selection: $selection) {
                    ForEach(JunkGroup.allCases, id: \.self) { group in
                        let groupItems = items.filter { $0.group == group }
                        if !groupItems.isEmpty {
                            Section {
                                ForEach(groupItems) { item in
                                    DevJunkRow(item: item, isChecked: binding(item))
                                        .tag(item.id)
                                        .contextMenu {
                                            Button("Reveal in Finder") { AppState.revealInFinder([item.path]) }
                                        }
                                }
                            } header: {
                                GroupHeader(group: group, total: groupItems.reduce(0) { $0 + $1.size })
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onKeyPress(.space) {
                    if let selection { previewURL = URL(fileURLWithPath: selection) }
                    return .handled
                }
                .quickLookPreview($previewURL)
            }
            SelectionFooter(
                checkedCount: checkedItems.count,
                checkedSize: checkedItems.reduce(0) { $0 + $1.size },
                totalCount: items.count,
                note: checkedItems.contains { $0.safety != .safe } ? "\(checkedItems.filter { $0.safety != .safe }.count) not rated Safe" : nil,
                onCheckAll: { checked.formUnion(items.filter { $0.isDeletable && $0.safety == .safe }.map(\.id)) },
                onUncheckAll: { checked.removeAll() },
                onReveal: { AppState.revealInFinder(selection.map { [$0] } ?? checkedItems.map(\.path)) },
                onQuickLook: { previewURL = selection.map { URL(fileURLWithPath: $0) } },
                onRemove: state.deletionEnabled ? { state.requestDeletion(paths: checkedItems.map(\.path)) } : nil)
        }
        .inspector(isPresented: $showInspector) {
            inspector.inspectorColumnWidth(min: 220, ideal: 260, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide details about the selected item")
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search developer junk")
        .onChange(of: state.junkItems) { _, items in
            checked.formIntersection(Set(items.map(\.id)))
        }
    }

    @AppStorage("showInspector") private var showInspector = true

    /// Full explanation for the selected item; the rows themselves stay to one line.
    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let item = state.junkItems.first(where: { $0.id == id }) {
            ItemInspector(path: item.path, size: item.size,
                          assessment: SafetyAssessment(level: item.isDeletable ? item.safety : .protected,
                                                       whatItIs: item.title, ifDeleted: item.explanation),
                          kind: item.group.rawValue)
        } else {
            EmptyInspector()
        }
    }

    @State private var previewURL: URL?

    private func binding(_ item: DevJunkItem) -> Binding<Bool> {
        Binding(get: { checked.contains(item.id) }, set: { isOn in
            if isOn { checked.insert(item.id) } else { checked.remove(item.id) }
        })
    }
}

/// Section header: group name in royal blue and its total.
struct GroupHeader: View {
    let group: JunkGroup
    let total: Int64

    var body: some View {
        HStack {
            Label(group.rawValue, systemImage: group.symbol).foregroundStyle(Theme.accent)
            Spacer()
            Text(total.formattedBytes).monospacedDigit()
        }
        .font(.headline)
    }
}

/// One line per junk location: checkbox, title, the first sentence of its explanation, rating and size.
/// The full explanation and path are in the tooltip and the inspector.
struct DevJunkRow: View {
    let item: DevJunkItem
    @Binding var isChecked: Bool

    /// "Build products and indexes. Xcode rebuilds…" → "Build products and indexes."
    private var shortExplanation: String {
        guard let end = item.explanation.range(of: ". ") else { return item.explanation }
        return String(item.explanation[..<end.lowerBound]) + "."
    }

    var body: some View {
        HStack(spacing: 10) {
            if item.isDeletable {
                Toggle("Select \(item.title)", isOn: $isChecked).toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16)
            }
            Text(item.title).fontWeight(.medium).lineLimit(1).layoutPriority(1)
            // App-cache rows would all say "Cache files for X"; the group header already says it.
            if item.group != .appCaches {
                Text(shortExplanation).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            SafetyBadge(level: item.isDeletable ? item.safety : .protected, compact: true)
            Text(item.size.formattedBytes)
                .font(.body.monospacedDigit().weight(.semibold))
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help("\(item.explanation)\n\n\(PathUtil.abbreviate(item.path))")
    }
}
