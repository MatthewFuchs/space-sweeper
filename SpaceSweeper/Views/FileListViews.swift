import SwiftUI

/// Every tracked file above a size threshold, rated for deletion safety.
struct LargeFilesView: View {
    @Environment(AppState.self) private var state
    /// Threshold in MB, stored as log10 so the slider is usable from 10 MB to 20 GB.
    @AppStorage("largeFilesThresholdLog") private var thresholdLog: Double = log10(500)

    private var thresholdBytes: Int64 { Int64(pow(10, thresholdLog).rounded()) * MB }

    var body: some View {
        let threshold = thresholdBytes
        let records = (state.result?.files ?? []).filter { $0.size >= threshold }
        FileTableView(records: records, emptyMessage: "No files over \(threshold.formattedBytes)") {
            SectionHeader(
                symbol: "doc.richtext",
                title: "\(records.count) files over \(threshold.formattedBytes) · \(records.reduce(0) { $0 + $1.size }.formattedBytes)",
                subtitle: "Each file is rated Safe, Review or Careful. Select one to see what it is and what happens if you delete it."
            ) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Minimum size: \(threshold.formattedBytes)").font(.callout.monospacedDigit())
                    Slider(value: $thresholdLog, in: 1...log10(20_000)).frame(width: 220)
                }
            }
        }
    }
}

/// Large files nobody has opened or modified for a while.
struct OldFilesView: View {
    @Environment(AppState.self) private var state
    @AppStorage("oldFilesMonths") private var months = 12
    @AppStorage("oldFilesMinimumMB") private var minimumMB = 50

    var body: some View {
        let records = FileFilters.oldFiles(state.result?.files ?? [], olderThanMonths: months,
                                           minimumSize: Int64(minimumMB) * MB)
        FileTableView(records: records, emptyMessage: "No old files match these filters") {
            SectionHeader(
                symbol: "clock.arrow.circlepath",
                title: "\(records.count) files untouched for \(months) months · \(records.reduce(0) { $0 + $1.size }.formattedBytes)",
                subtitle: "Not opened or modified recently. Old doesn't mean unwanted: check the rating and back up anything personal first."
            ) {
                HStack(spacing: 12) {
                    Picker("Untouched for", selection: $months) {
                        Text("6 months").tag(6)
                        Text("12 months").tag(12)
                        Text("24 months").tag(24)
                    }
                    .fixedSize()
                    Picker("At least", selection: $minimumMB) {
                        Text("10 MB").tag(10)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                    }
                    .fixedSize()
                }
            }
        }
    }
}
