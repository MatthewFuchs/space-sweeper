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
            SummaryHeader(
                value: records.reduce(0) { $0 + $1.size }.formattedBytes,
                caption: "in \(records.count) files over \(threshold.formattedBytes)",
                help: "Every file at least as big as the minimum size. Each one is rated Safe, Review or Careful; select a file to see what it is and what happens if you delete it."
            ) {
                HStack(spacing: 8) {
                    Text("Min").foregroundStyle(.secondary)
                    Slider(value: $thresholdLog, in: 1...log10(20_000)).frame(width: 160)
                    Text(threshold.formattedBytes).monospacedDigit().frame(width: 64, alignment: .leading)
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
            SummaryHeader(
                value: records.reduce(0) { $0 + $1.size }.formattedBytes,
                caption: "in \(records.count) files untouched for \(months) months",
                help: "Files not opened or modified in the chosen period. Old doesn't mean unwanted: check the rating, and back up anything personal before deleting."
            ) {
                HStack(spacing: 8) {
                    Picker("", selection: $months) {
                        Text("6 months").tag(6)
                        Text("12 months").tag(12)
                        Text("24 months").tag(24)
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("", selection: $minimumMB) {
                        Text("≥ 10 MB").tag(10)
                        Text("≥ 50 MB").tag(50)
                        Text("≥ 100 MB").tag(100)
                        Text("≥ 500 MB").tag(500)
                        Text("≥ 1 GB").tag(1000)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}
