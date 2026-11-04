import Charts
import SwiftUI

/// Disk capacity, usage breakdown chart and reclaimable-space estimate.
struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let disk = state.disk {
                    DiskCapacityCard(disk: disk)
                }
                if let result = state.result {
                    let categories = OverviewCalculator.categories(tree: result.tree, home: state.homePath, diskUsed: state.disk?.used)
                    BreakdownCard(categories: categories)
                    ReclaimableCard(estimate: state.reclaimable, isComputing: state.isComputingJunk)
                    ScanInfoCard(result: result)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// White card container used by the Overview sections.
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.15)))
    }
}

struct DiskCapacityCard: View {
    let disk: DiskInfo

    var body: some View {
        Card(title: disk.volumeName) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                StatView(label: "Total", value: disk.total.formattedBytes)
                StatView(label: "Used", value: disk.used.formattedBytes)
                StatView(label: "Free", value: disk.available.formattedBytes, highlight: true)
            }
            ProgressView(value: Double(disk.used), total: Double(max(disk.total, 1)))
                .tint(Theme.accent)
            Text("Free space is what macOS reports for important use, including purgeable space it can reclaim on demand.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatView: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(highlight ? Theme.accent : .primary)
        }
    }
}

/// Donut chart plus a legend with sizes.
struct BreakdownCard: View {
    let categories: [UsageCategory]

    var body: some View {
        Card(title: "What's using space") {
            HStack(alignment: .center, spacing: 28) {
                Chart(Array(categories.enumerated()), id: \.element.id) { index, category in
                    SectorMark(angle: .value("Size", category.size), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(color(index))
                }
                .chartLegend(.hidden)
                .frame(width: 200, height: 200)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        HStack {
                            Circle().fill(color(index)).frame(width: 10, height: 10)
                            Image(systemName: category.symbol).frame(width: 18).foregroundStyle(.secondary)
                            Text(category.name)
                            Spacer()
                            Text(category.size.formattedBytes).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func color(_ index: Int) -> Color {
        Theme.chartPalette[index % Theme.chartPalette.count]
    }
}

struct ReclaimableCard: View {
    let estimate: ReclaimableEstimate
    let isComputing: Bool

    var body: some View {
        Card(title: "Estimated reclaimable space") {
            HStack(alignment: .firstTextBaseline) {
                Text(estimate.total.formattedBytes)
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                if isComputing { ProgressView().controlSize(.small) }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Developer junk & caches")
                    Text(estimate.developerJunk.formattedBytes).monospacedDigit()
                }
                GridRow {
                    Text("Installers & archives in Downloads")
                    Text(estimate.installers.formattedBytes).monospacedDigit()
                }
                GridRow {
                    Text("Files untouched for 12+ months (≥ 50 MB)")
                    Text(estimate.oldFiles.formattedBytes).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            Text("An estimate: review each item before removing it. Moving to the Trash frees space only after the Trash is emptied.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScanInfoCard: View {
    let result: ScanResult

    var body: some View {
        Card(title: "Last scan") {
            Text("\(result.itemsScanned.formatted()) items, \(result.totalSize.formattedBytes), scanned \(result.date.formatted(date: .abbreviated, time: .shortened)) in \(String(format: "%.1f", result.duration)) s")
            Text(result.roots.map { PathUtil.abbreviate($0) }.joined(separator: " · "))
                .foregroundStyle(.secondary)
            if !result.skipped.isEmpty {
                Text("\(result.skipped.count) locations couldn't be scanned — see Couldn't Scan.")
                    .foregroundStyle(.orange)
            }
        }
    }
}
