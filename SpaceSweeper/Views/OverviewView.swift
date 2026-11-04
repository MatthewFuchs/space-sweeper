import Charts
import SwiftUI

/// Disk capacity, usage breakdown chart and reclaimable-space estimate.
struct OverviewView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let disk = state.disk {
                    HeroCard(disk: disk, reclaimable: state.reclaimable.total)
                }
                if let result = state.result {
                    let categories = OverviewCalculator.categories(tree: result.tree, home: state.homePath, diskUsed: state.disk?.used)
                    QuickWinsCard(items: Array(state.junkItems.filter { $0.isDeletable && $0.safety == .safe }.prefix(5)))
                    HStack(alignment: .top, spacing: 20) {
                        BreakdownCard(categories: categories)
                        VStack(spacing: 20) {
                            ReclaimableCard(estimate: state.reclaimable, isComputing: state.isComputingJunk)
                            ScanInfoCard(result: result)
                        }
                        .frame(width: 300)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
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
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.accent.opacity(0.15)))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}

/// Royal-blue gradient header: free space, a capacity ring and the reclaimable estimate.
struct HeroCard: View {
    @Environment(AppState.self) private var state
    let disk: DiskInfo
    let reclaimable: Int64

    /// Size of junk rated Safe: what the hero's button offers to free.
    private var safeTotal: Int64 {
        state.junkItems.filter { $0.isDeletable && $0.safety == .safe }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        let usedFraction = Double(disk.used) / Double(max(disk.total, 1))
        HStack(spacing: 28) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 14)
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(usedFraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                    Text("used").font(.caption)
                }
            }
            .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 6) {
                Text(disk.volumeName).font(.headline).opacity(0.85)
                Text("\(disk.available.formattedBytes) free")
                    .font(.system(size: 40, weight: .bold).monospacedDigit())
                Text("\(disk.used.formattedBytes) used of \(disk.total.formattedBytes)")
                    .font(.title3).opacity(0.85)
            }
            Spacer()
            // The one thing to do next: review what's safe to delete.
            if safeTotal > 0 {
                Button {
                    state.selectedSection = .devJunk
                } label: {
                    Label("Free up \(safeTotal.formattedBytes) safely", systemImage: "checkmark.shield.fill")
                        .font(.headline)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Theme.royalBlue)
                .controlSize(.large)
            }
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.heroGradient))
        .shadow(color: Theme.royalBlue.opacity(0.3), radius: 12, y: 6)
    }
}

/// The biggest items rated "Safe", one click away from the section where they can be removed.
struct QuickWinsCard: View {
    @Environment(AppState.self) private var state
    let items: [DevJunkItem]

    var body: some View {
        if !items.isEmpty {
            Card(title: "Biggest safe wins") {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.group.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.heroGradient))
                        Text(item.title).fontWeight(.medium).lineLimit(1)
                            .help(item.explanation)
                        Spacer()
                        SafetyBadge(level: item.safety, compact: true)
                        Text(item.size.formattedBytes).font(.body.monospacedDigit().weight(.semibold))
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                Button("See all in Developer Junk →") { state.selectedSection = .devJunk }
                    .buttonStyle(.link)
            }
        }
    }
}

/// Plain capacity card (used when no hero is wanted).
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

/// Label + large value pair.
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
            VStack(alignment: .leading, spacing: 18) {
                Chart(Array(categories.enumerated()), id: \.element.id) { index, category in
                    SectorMark(angle: .value("Size", category.size), innerRadius: .ratio(0.6), angularInset: 1)
                        .foregroundStyle(color(index))
                }
                .chartLegend(.hidden)
                .frame(height: 220)

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

/// Breakdown of the reclaimable estimate by source.
struct ReclaimableCard: View {
    let estimate: ReclaimableEstimate
    let isComputing: Bool

    var body: some View {
        Card(title: "Could be reclaimed") {
            HStack(alignment: .firstTextBaseline) {
                Text(estimate.total.formattedBytes)
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                if isComputing { ProgressView().controlSize(.small) }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Developer junk")
                    Text(estimate.developerJunk.formattedBytes).monospacedDigit()
                }
                GridRow {
                    Text("Installers")
                    Text(estimate.installers.formattedBytes).monospacedDigit()
                }
                GridRow {
                    Text("Old files (12+ months)")
                    Text(estimate.oldFiles.formattedBytes).monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)

        }
    }
}

/// When and what was last scanned.
struct ScanInfoCard: View {
    @Environment(AppState.self) private var state
    let result: ScanResult

    var body: some View {
        Card(title: "Last scan") {
            Text("\(result.date.formatted(.relative(presentation: .named))) · \(result.itemsScanned.formatted()) items · \(String(format: "%.0f", result.duration)) s")
                .foregroundStyle(.secondary)
            if !result.skipped.isEmpty {
                Button("\(result.skipped.count) folders skipped →") { state.selectedSection = .couldntScan }
                    .buttonStyle(.link)
            }
        }
    }
}
