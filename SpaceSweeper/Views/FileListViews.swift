import SwiftUI

/// Every tracked file above a size threshold.
struct LargeFilesView: View {
    @Environment(AppState.self) private var state
    /// Threshold in MB, stored as log10 so the slider is usable from 10 MB to 20 GB.
    @AppStorage("largeFilesThresholdLog") private var thresholdLog: Double = log10(500)

    private var thresholdBytes: Int64 { Int64(pow(10, thresholdLog).rounded()) * MB }

    var body: some View {
        let threshold = thresholdBytes
        let records = (state.result?.files ?? []).filter { $0.size >= threshold }
        FileTableView(records: records) {
            HStack(spacing: 12) {
                Text("Minimum size")
                Slider(value: $thresholdLog, in: 1...log10(20_000))
                    .frame(maxWidth: 320)
                Text(threshold.formattedBytes)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)
                Spacer()
                Text("\(records.count) files · \(records.reduce(0) { $0 + $1.size }.formattedBytes)")
                    .foregroundStyle(.secondary)
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
        FileTableView(records: records) {
            HStack(spacing: 16) {
                Picker("Not opened or modified in", selection: $months) {
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                    Text("24 months").tag(24)
                }
                .fixedSize()
                Picker("Minimum size", selection: $minimumMB) {
                    Text("10 MB").tag(10)
                    Text("50 MB").tag(50)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                }
                .fixedSize()
                Spacer()
                Text("\(records.count) files · \(records.reduce(0) { $0 + $1.size }.formattedBytes)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
