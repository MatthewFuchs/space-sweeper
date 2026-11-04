import SwiftUI

/// Security Check: items that are unusual for legitimate software, grouped by where they were found.
struct SecurityView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SecurityFinding.ID?
    @State private var showIgnored = false

    private var visible: [SecurityFinding] {
        state.securityFindings.filter { showIgnored || !state.securityIgnored.contains($0.path) }
    }

    var body: some View {
        let findings = visible
        let suspicious = findings.filter { $0.level == .suspicious && !state.securityIgnored.contains($0.path) }.count
        let unusual = findings.filter { $0.level == .unusual && !state.securityIgnored.contains($0.path) }.count
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                SummaryHeader(value: state.lastSecurityCheck == nil ? "—" : "\(suspicious)",
                              caption: state.lastSecurityCheck == nil ? "Check for startup items, apps and downloads that look unusual"
                                  : "suspicious · \(unusual) unusual",
                              help: "Flags things that are unusual for legitimate software using macOS's own signature checks: broken app signatures, programs disguised as documents, hidden programs that start automatically. It is not an antivirus: a flag isn't proof of malware. Nothing leaves your Mac.") {
                    HStack(spacing: 8) {
                        if state.isCheckingSecurity { ProgressView().controlSize(.small) }
                        Button(state.lastSecurityCheck == nil ? "Run Check" : "Check Again") { state.runSecurityCheck() }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isCheckingSecurity)
                    }
                }
                Label("Not an antivirus. A flag means “take a look”, not “malware”.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()
            content(findings)
            footer
        }
        .task { if state.lastSecurityCheck == nil { state.runSecurityCheck() } }
    }

    @ViewBuilder
    private func content(_ findings: [SecurityFinding]) -> some View {
        if state.isCheckingSecurity && state.lastSecurityCheck == nil {
            LoadingView(message: "Checking startup items, apps and downloads…")
        } else if findings.isEmpty {
            ContentUnavailableView {
                Label("Nothing unusual found", systemImage: "checkmark.shield")
            } description: {
                Text("Startup items, apps and downloads look normal.")
            }
        } else {
            List(selection: $selection) {
                ForEach(SecurityCategory.allCases, id: \.self) { category in
                    let items = findings.filter { $0.category == category }
                    if !items.isEmpty {
                        Section {
                            ForEach(items) { finding in
                                SecurityRow(finding: finding, isIgnored: state.securityIgnored.contains(finding.path))
                                    .tag(finding.id)
                                    .contextMenu { menu(for: finding) }
                            }
                        } header: {
                            Label(category.rawValue, systemImage: category.symbol)
                                .font(.headline)
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private func menu(for finding: SecurityFinding) -> some View {
        Button("Reveal in Finder") { AppState.revealInFinder([finding.path]) }
        if let program = finding.program {
            Button("Reveal Program in Finder") { AppState.revealInFinder([program]) }
        }
        Divider()
        if state.securityIgnored.contains(finding.path) {
            Button("Stop Ignoring") { state.setSecurityIgnored(finding.path, ignored: false) }
        } else {
            Button("Ignore (I Trust This)") { state.setSecurityIgnored(finding.path, ignored: true) }
        }
        Button("Move to Trash…") { state.requestDeletion(paths: [finding.path]) }
    }

    private var footer: some View {
        let selected = state.securityFindings.first { $0.id == selection }
        return HStack(spacing: 10) {
            Toggle("Show ignored (\(state.securityIgnored.count))", isOn: $showIgnored)
                .toggleStyle(.checkbox)
                .disabled(state.securityIgnored.isEmpty)
            if let checked = state.lastSecurityCheck {
                Text("Checked \(checked.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reveal in Finder") { if let selected { AppState.revealInFinder([selected.path]) } }
                .disabled(selected == nil)
            Button(selected.map { state.securityIgnored.contains($0.path) } == true ? "Stop Ignoring" : "Ignore") {
                if let selected { state.setSecurityIgnored(selected.path, ignored: !state.securityIgnored.contains(selected.path)) }
            }
            .disabled(selected == nil)
            Button("Move to Trash…") { if let selected { state.requestDeletion(paths: [selected.path]) } }
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// Level badge, name, reasons, and signer / program / download source.
struct SecurityRow: View {
    let finding: SecurityFinding
    let isIgnored: Bool

    private var color: Color { finding.level == .suspicious ? .red : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            LazyIcon(path: finding.program ?? finding.path, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.name).fontWeight(.medium).lineLimit(1)
                    if isIgnored { Text("Ignored").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(finding.reasons, id: \.self) { reason in
                    Text(reason).font(.callout).foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Group {
                    if let program = finding.program { Text("Runs: \(PathUtil.abbreviate(program))") }
                    if let signer = finding.signer { Text(signer) }
                    if let source = finding.source { Text("Downloaded from \(source)") }
                    Text(PathUtil.abbreviate(finding.path))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            Label(finding.level.title, systemImage: finding.level.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
                .fixedSize()
                .accessibilityLabel("Flagged \(finding.level.title)")
        }
        .padding(.vertical, 4)
        .opacity(isIgnored ? 0.55 : 1)
    }
}
