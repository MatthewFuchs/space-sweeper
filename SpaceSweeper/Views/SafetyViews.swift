import AppKit
import QuickLook
import SwiftUI

/// Coloured capsule showing a safety level ("Safe", "Review", "Careful", "Protected").
struct SafetyBadge: View {
    let level: SafetyLevel
    var compact = false

    var body: some View {
        Label(level.shortLabel, systemImage: level.symbol)
            .labelStyle(.titleAndIcon)
            .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(level == .protected ? Color.secondary : level.color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 2 : 3)
            .background(Capsule().fill(level.color.opacity(level == .protected ? 0.12 : 0.14)))
            .help("\(level.title): \(level.meaning)")
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(level.accessibilityLabel)
    }
}

/// Compact section summary: one large royal-blue number (the thing to look at), a short caption, an optional
/// ⓘ popover holding the longer explanation, and controls on the right.
struct SummaryHeader<Accessory: View>: View {
    let value: String
    let caption: String
    var help: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(value)
                .font(.system(size: 28, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .fixedSize()
            Text(caption)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            if let help { InfoButton(text: help) }
            Spacer(minLength: 12)
            accessory()
                .fixedSize()
        }
    }
}

extension SummaryHeader where Accessory == EmptyView {
    init(value: String, caption: String, help: String? = nil) {
        self.init(value: value, caption: caption, help: help) { EmptyView() }
    }
}

/// Small ⓘ button that shows a short explanation in a popover, keeping the screen itself uncluttered.
struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("What is this?")
        .accessibilityLabel("More information")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 280, alignment: .leading)
                .padding(14)
        }
    }
}

/// Count and total size for one safety level, used by the filter chips.
struct SafetyTally: Equatable {
    var count = 0
    var size: Int64 = 0
}

/// Toggle chips that filter a list by safety level and show how much each level holds.
struct SafetyFilterBar: View {
    let tallies: [SafetyLevel: SafetyTally]
    @Binding var visible: Set<SafetyLevel>
    var levels: [SafetyLevel] = [.safe, .review, .caution, .protected]

    var body: some View {
        HStack(spacing: 6) {
            Text("Show").font(.callout).foregroundStyle(.secondary)
            // Only levels that have items get a chip; empty chips added noise ("Zero KB").
            ForEach(levels, id: \.self) { level in
                if let tally = tallies[level], tally.count > 0 {
                    chip(level, tally)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One toggleable chip, kept on a single line: filled when its level is shown, tinted when hidden.
    private func chip(_ level: SafetyLevel, _ tally: SafetyTally) -> some View {
        let isOn = visible.contains(level)
        return Button {
            if isOn { visible.remove(level) } else { visible.insert(level) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: level.symbol)
                Text("\(level.shortLabel) \(tally.count)")
                Text("· \(tally.size.formattedBytes)").opacity(0.8)
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(isOn ? Color.white : level.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(isOn ? (level == .protected ? Color.gray : level.color) : level.color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("\(isOn ? "Hide" : "Show") items rated \(level.shortLabel): \(level.meaning)")
    }
}

/// The screen's primary action: "7.2 GB is safe to delete" with a prominent green "Select Safe Items" button,
/// which becomes "Deselect Safe Items" once they are all selected.
struct SafeActionBar: View {
    let tally: SafetyTally
    /// True when every Safe item is already checked.
    var allSelected = false
    var onSelectSafe: () -> Void
    var onDeselectSafe: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill").font(.title3).foregroundStyle(.green)
            Text("**\(tally.size.formattedBytes)** is safe to delete")
                .font(.headline)
            Text("\(tally.count) item\(tally.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Spacer()
            if allSelected {
                Button(action: onDeselectSafe) {
                    Label("Deselect Safe Items", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            } else {
                Button(action: onSelectSafe) {
                    Label("Select Safe Items", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }
}

/// Right-hand inspector for the selected item: what it is, whether it's safe, and what happens if it's deleted.
struct ItemInspector: View {
    let path: String
    let size: Int64
    let assessment: SafetyAssessment
    var modified: Date?
    var lastOpened: Date?
    var kind: String?
    var onQuickLook: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    LazyIcon(path: path, size: 72)
                    Text((path as NSString).lastPathComponent)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    Text(size.formattedBytes)
                        .font(.title.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                .frame(maxWidth: .infinity)

                SafetyCard(assessment: assessment)

                VStack(alignment: .leading, spacing: 8) {
                    if let kind, !kind.isEmpty { InspectorRow(label: "Kind", value: kind) }
                    if let modified { InspectorRow(label: "Modified", value: modified.formatted(date: .abbreviated, time: .shortened)) }
                    if let lastOpened { InspectorRow(label: "Last opened", value: lastOpened.formatted(date: .abbreviated, time: .shortened)) }
                    InspectorRow(label: "Where", value: PathUtil.abbreviate((path as NSString).deletingLastPathComponent))
                }

                HStack {
                    Button("Reveal in Finder") { AppState.revealInFinder([path]) }
                    if let onQuickLook { Button("Quick Look", action: onQuickLook) }
                }
                .controlSize(.small)
            }
            .padding(16)
        }
    }
}

/// Placeholder shown in the inspector when nothing is selected: one instruction plus a compact legend.
struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "cursorarrow.click").font(.system(size: 30)).foregroundStyle(Theme.accent)
            Text("Select a file to see if it's safe to delete")
                .font(.headline)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SafetyLevel.allCases, id: \.self) { level in
                    HStack(spacing: 8) {
                        SafetyBadge(level: level, compact: true).frame(width: 82, alignment: .leading)
                        Text(level.meaning).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Coloured card stating the safety level and the consequences of deleting.
struct SafetyCard: View {
    let assessment: SafetyAssessment

    var body: some View {
        let level = assessment.level
        VStack(alignment: .leading, spacing: 8) {
            Label(level.title, systemImage: level.symbol)
                .font(.headline)
                .foregroundStyle(level == .protected ? Color.primary : level.color)
            Text(assessment.whatItIs).font(.callout.weight(.medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("If you delete it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(assessment.ifDeleted).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(assessment.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(level.color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(level.color.opacity(0.30)))
    }
}

/// Label/value pair in the inspector.
struct InspectorRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }
}

/// Size text with a thin royal-blue bar relative to the largest item in the list.
struct SizeWithBar: View {
    let size: Int64
    let maxSize: Int64

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(size.formattedBytes).monospacedDigit()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.accent.opacity(0.12))
                    Capsule().fill(Theme.accent)
                        .frame(width: max(2, geometry.size.width * CGFloat(Double(size) / Double(max(maxSize, 1)))))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
    }
}
