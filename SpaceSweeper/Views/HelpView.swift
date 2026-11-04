import SwiftUI

/// In-app guide: how scanning works, what the ratings mean, the kinds of data, common questions and privacy.
struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                stepsCard
                ratingsCard
                kindsCard
                HStack(alignment: .top, spacing: 20) {
                    faqCard
                    privacyCard.frame(width: 300)
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Scan → Rate → Review → Trash.
    private var stepsCard: some View {
        Card(title: "How SpaceSweeper works") {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(HelpContent.steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 8) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Theme.heroGradient))
                        Text("\(index + 1). \(step.title)").font(.headline)
                        Text(step.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 200)
                    }
                    .frame(maxWidth: .infinity)
                    if index < HelpContent.steps.count - 1 {
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).padding(.top, 14)
                    }
                }
            }
        }
    }

    /// The four ratings with an example each.
    private var ratingsCard: some View {
        Card(title: "Safety ratings") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                ForEach(SafetyLevel.allCases, id: \.self) { level in
                    GridRow {
                        SafetyBadge(level: level)
                        Text(level.meaning).fontWeight(.medium)
                        Text(HelpContent.ratingExamples[level] ?? "").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Table of the kinds of data the app shows.
    private var kindsCard: some View {
        Card(title: "Kinds of data") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("")
                    Text("Kind").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Examples").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Rating").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("If you delete it").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Divider().gridCellColumns(5)
                ForEach(HelpContent.dataKinds) { kind in
                    GridRow {
                        Image(systemName: kind.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                        Text(kind.name).fontWeight(.medium)
                        Text(kind.examples).foregroundStyle(.secondary).lineLimit(2)
                        SafetyBadge(level: kind.rating, compact: true)
                        Text(kind.ifDeleted).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .font(.callout)
        }
    }

    /// Short questions with expandable answers.
    private var faqCard: some View {
        Card(title: "Common questions") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(HelpContent.faqs) { faq in
                    DisclosureGroup {
                        Text(faq.answer)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } label: {
                        Text(faq.question).fontWeight(.medium)
                    }
                }
            }
        }
    }

    /// What the app does and doesn't do with your data.
    private var privacyCard: some View {
        Card(title: "Privacy") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(HelpContent.privacy, id: \.self) { line in
                    Label {
                        Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lock.shield").foregroundStyle(Theme.accent)
                    }
                }
            }
        }
    }
}
