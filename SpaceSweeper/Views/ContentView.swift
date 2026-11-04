import SwiftUI

/// Sidebar sections. The raw value is persisted in scene storage.
enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case overview, largeFiles, oldFiles, folders, devJunk, applications, couldntScan, activity, help

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
        case .help: return "Help"
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
        case .help: return "questionmark.circle"
        }
    }

    /// Main sections and secondary sections, shown as two sidebar groups.
    static let library: [SidebarItem] = [.overview, .largeFiles, .oldFiles, .folders, .devJunk, .applications]
    static let more: [SidebarItem] = [.couldntScan, .activity, .help]
    /// Sections that work without scan results.
    var needsScan: Bool { ![.applications, .activity, .help].contains(self) }
}

/// Main window: sidebar navigation, toolbar and the selected section.
struct ContentView: View {
    @Environment(AppState.self) private var state
    var body: some View {
        @Bindable var state = state
        let selection = state.selectedSection
        NavigationSplitView {
            List(selection: $state.selectedSection) {
                Section("Disk") {
                    ForEach(SidebarItem.library) { item in
                        Label(item.title, systemImage: item.symbol)
                            .badge(sidebarBadge(item))
                            .tag(item)
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) { DiskSummaryFooter() }
        } detail: {
            detail
                .navigationTitle(selection.title)
                .toolbar { ScanToolbar() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let notice = state.notice { NoticeBanner(notice: notice) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if state.isScanning { ScanProgressBar() }
                }
                .animation(.easeOut(duration: 0.2), value: state.notice)
        }
        .sheet(item: $state.review) { request in
            ReviewSheet(request: request)
        }
        .sheet(item: $state.outcome) { outcome in
            DeletionOutcomeView(outcome: outcome)
        }
        .overlay {
            if state.isDeleting || state.isPreparingUninstall {
                ProgressView(state.isDeleting ? "Removing…" : "Finding leftover files…")
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            }
        }
    }

    /// Size shown next to sidebar items so the biggest opportunities stand out.
    private func sidebarBadge(_ item: SidebarItem) -> Text? {
        switch item {
        case .devJunk:
            let total = state.junkItems.filter(\.isDeletable).reduce(0) { $0 + $1.size }
            return total > 0 ? Text(total.formattedBytes) : nil
        case .largeFiles:
            let total = (state.result?.files ?? []).filter { $0.size >= 500 * MB }.reduce(0) { $0 + $1.size }
            return total > 0 ? Text(total.formattedBytes) : nil
        default:
            return nil
        }
    }

    /// The selected section, or a scan prompt/progress view when there are no results yet.
    @ViewBuilder
    private var detail: some View {
        let selection = state.selectedSection
        if state.result == nil && selection.needsScan {
            if state.isLoadingCache {
                LoadingView(message: "Loading your last scan…")
            } else if state.isScanning {
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
            case .activity: ActivityLogView()
            case .help: HelpView()
            }
        }
    }
}

