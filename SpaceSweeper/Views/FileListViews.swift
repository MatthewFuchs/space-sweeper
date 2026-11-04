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
