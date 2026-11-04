import SwiftUI

/// Sidebar sections. The raw value is persisted in scene storage.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, largeFiles, oldFiles, folders, devJunk, applications, couldntScan, activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .largeFiles: return "Large Files"
        case .oldFiles: return "Old Files"
        case .folders: return "Folders"
        case .devJunk: return "Developer Junk"
        case .applications: return "Applications"
        case .couldntScan: return "Couldn't Scan"
        case .activity: return "Activity Log"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "chart.pie"
        case .largeFiles: return "doc.richtext"
        case .oldFiles: return "clock.arrow.circlepath"
        case .folders: return "folder"
        case .devJunk: return "hammer"
        case .applications: return "square.grid.2x2"
        case .couldntScan: return "exclamationmark.triangle"
        case .activity: return "list.bullet.rectangle"
        }
    }

    /// Main sections and secondary sections, shown as two sidebar groups.
    static let library: [SidebarItem] = [.overview, .largeFiles, .oldFiles, .folders, .devJunk, .applications]
    static let more: [SidebarItem] = [.couldntScan, .activity]
}

/// Main window: sidebar navigation, toolbar and the selected section.
struct ContentView: View {
    @Environment(AppState.self) private var state
    @SceneStorage("sidebarSelection") private var selection: SidebarItem = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Disk") {
                    ForEach(SidebarItem.library) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section("More") {
                    ForEach(SidebarItem.more) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(item == .couldntScan ? (state.result?.skipped.count ?? 0) : 0)
                            .tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { DiskSummaryFooter() }
        } detail: {
            detail
                .navigationTitle(selection.title)
                .toolbar { ScanToolbar() }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if state.isScanning { ScanProgressBar() }
                }
        }
    }

    /// The selected section, or a scan prompt/progress view when there are no results yet.
    @ViewBuilder
    private var detail: some View {
        if state.result == nil && selection != .applications && selection != .activity {
            if state.isScanning {
                ScanInProgressView()
            } else {
                NoScanView()
            }
        } else {
            switch selection {
            case .overview: OverviewView()
            case .largeFiles: LargeFilesView()
            case .oldFiles: OldFilesView()
            case .folders: FoldersView()
            case .devJunk: DevJunkView()
            case .applications: ApplicationsView()
            case .couldntScan: CouldntScanView()
            case .activity: ComingSoonView(title: selection.title)
            }
        }
    }
}

/// Placeholder for sections that are added in a later build stage.
struct ComingSoonView: View {
    let title: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Not built yet."))
    }
}
