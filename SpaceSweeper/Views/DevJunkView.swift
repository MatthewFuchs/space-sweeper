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
        VStack(spacing: 0) {
            if state.isComputingJunk && state.junkItems.isEmpty {
                ProgressView("Measuring developer folders…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("Nothing found", systemImage: "sparkles",
                                       description: Text(search.isEmpty ? "No developer junk over 1 MB was found." : "No matches."))
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
                onCheckAll: { checked.formUnion(items.filter(\.isDeletable).map(\.id)) },
                onUncheckAll: { checked.removeAll() },
                onReveal: { AppState.revealInFinder(selection.map { [$0] } ?? checkedItems.map(\.path)) },
                onQuickLook: { previewURL = selection.map { URL(fileURLWithPath: $0) } },
                onRemove: state.deletionEnabled ? { state.requestDeletion(paths: checkedItems.map(\.path)) } : nil)
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search developer junk")
        .onChange(of: state.junkItems) { _, items in
            checked.formIntersection(Set(items.map(\.id)))
        }
    }

    @State private var previewURL: URL?

    private func binding(_ item: DevJunkItem) -> Binding<Bool> {
        Binding(get: { checked.contains(item.id) }, set: { isOn in
            if isOn { checked.insert(item.id) } else { checked.remove(item.id) }
        })
    }
}

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

/// Checkbox, title, explanation, path and size for one junk location.
struct DevJunkRow: View {
    let item: DevJunkItem
    @Binding var isChecked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if item.isDeletable {
                Toggle("", isOn: $isChecked).toggleStyle(.checkbox).labelsHidden()
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16)
                    .help("Clean this with its own tool instead")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium)
                Text(item.explanation).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(PathUtil.abbreviate(item.path)).font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(item.size.formattedBytes)
                .font(.body.monospacedDigit().weight(.semibold))
        }
        .padding(.vertical, 4)
    }
}
