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
    }
}

/// Banner at the top of each section: icon tile, title and a sentence explaining what the list shows.
struct SectionHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 11).fill(Theme.heroGradient))
                .shadow(color: Theme.royalBlue.opacity(0.25), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
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
        HStack(spacing: 8) {
            Text("Show").font(.callout).foregroundStyle(.secondary)
            ForEach(levels, id: \.self) { level in
                let tally = tallies[level] ?? SafetyTally()
                if tally.count > 0 || visible.contains(level) {
                    chip(level, tally)
                }
            }
        }
    }

    /// One toggleable chip: filled when its level is shown, tinted outline when hidden.
    private func chip(_ level: SafetyLevel, _ tally: SafetyTally) -> some View {
        let isOn = visible.contains(level)
        return Button {
            if isOn { visible.remove(level) } else { visible.insert(level) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: level.symbol)
                Text("\(level.shortLabel) \(tally.count)")
                Text(tally.size.formattedBytes).foregroundStyle(isOn ? Color.white.opacity(0.85) : .secondary)
            }
            .font(.callout.weight(.medium).monospacedDigit())
            .foregroundStyle(isOn ? Color.white : level.color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isOn ? (level == .protected ? Color.gray : level.color) : level.color.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(level.meaning)
    }
}

/// Green callout: "4.2 GB can be deleted safely" with a one-click "Check Safe Items" action.
struct SafeSummaryCallout: View {
    let tally: SafetyTally
    var onCheckSafe: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill").font(.title3).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(tally.size.formattedBytes) can be deleted safely")
                    .font(.headline)
                Text("\(tally.count) item\(tally.count == 1 ? "" : "s") that regenerate automatically or are clearly disposable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check Safe Items", action: onCheckSafe)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.green.opacity(0.25)))
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
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                        .resizable()
                        .frame(width: 72, height: 72)
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

/// Placeholder shown in the inspector when nothing is selected.
struct EmptyInspector: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "hand.point.up.left").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Select an item to see what it is and whether it's safe to delete.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SafetyLevel.allCases, id: \.self) { level in
                    HStack(alignment: .top, spacing: 8) {
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
        }
    }
}
