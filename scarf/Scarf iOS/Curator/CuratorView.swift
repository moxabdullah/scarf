import SwiftUI
import ScarfCore
import ScarfDesign

#if canImport(SQLite3)

/// iOS Curator surface — read-mostly view of `hermes curator status`
/// with Run Now / Pause / Resume actions and inline pin toggles on
/// the leaderboard rows. Mirrors the Mac surface visually but folds
/// into a single SwiftUI List for thumb-friendly scrolling.
///
/// Capability-gated upstream: only routed when
/// `HermesCapabilities.hasCurator` is true.
struct CuratorView: View {
    @State private var viewModel: CuratorViewModel

    init(context: ServerContext) {
        _viewModel = State(initialValue: CuratorViewModel(context: context))
    }

    var body: some View {
        List {
            Section {
                statusRow
                LabeledContent("Last run", value: viewModel.status.lastRunISO ?? "Never")
                if let summary = viewModel.status.lastSummary {
                    LabeledContent("Summary", value: summary)
                }
                LabeledContent("Interval", value: viewModel.status.intervalLabel)
                LabeledContent("Stale after", value: viewModel.status.staleAfterLabel)
                LabeledContent("Archive after", value: viewModel.status.archiveAfterLabel)
                LabeledContent("Runs", value: "\(viewModel.status.runCount)")
            } header: {
                Text("Status")
            } footer: {
                actionFooter
            }

            Section("Skills") {
                LabeledContent("Total", value: "\(viewModel.status.totalSkills)")
                LabeledContent("Active", value: "\(viewModel.status.activeSkills)")
                LabeledContent("Stale", value: "\(viewModel.status.staleSkills)")
                LabeledContent("Archived", value: "\(viewModel.status.archivedSkills)")
            }

            if !viewModel.status.pinnedNames.isEmpty {
                Section("Pinned") {
                    ForEach(viewModel.status.pinnedNames, id: \.self) { name in
                        HStack {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(ScarfColor.accent)
                            Text(name)
                            Spacer()
                            Button("Unpin") {
                                Task { await viewModel.unpin(name) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if !viewModel.status.leastRecentlyActive.isEmpty {
                rowsSection(title: "Least recently active", rows: viewModel.status.leastRecentlyActive)
            }
            if !viewModel.status.mostActive.isEmpty {
                rowsSection(title: "Most active", rows: viewModel.status.mostActive)
            }
            if !viewModel.status.leastActive.isEmpty {
                rowsSection(title: "Least active", rows: viewModel.status.leastActive)
            }

            if let report = viewModel.lastReportMarkdown {
                Section("Last report") {
                    Text(report)
                        .font(ScarfFont.monoSmall)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Curator")
        .navigationBarTitleDisplayMode(.large)
        .refreshable {
            await viewModel.load()
        }
        .overlay(alignment: .bottom) {
            if let toast = viewModel.transientMessage {
                toastView(toast)
            }
        }
        .task { await viewModel.load() }
    }

    private var statusRow: some View {
        HStack {
            Text("Curator")
            Spacer()
            statusBadge
        }
    }

    private var statusBadge: some View {
        let kind: ScarfBadgeKind
        let label: String
        switch viewModel.status.state {
        case .enabled:  kind = .success; label = "Enabled"
        case .paused:   kind = .warning; label = "Paused"
        case .disabled: kind = .neutral; label = "Disabled"
        case .unknown:  kind = .neutral; label = "Unknown"
        }
        return ScarfBadge(label, kind: kind)
    }

    private var actionFooter: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.runNow() }
            } label: {
                Label("Run now", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(viewModel.isLoading)

            if viewModel.status.state == .enabled {
                Button {
                    Task { await viewModel.pause() }
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if viewModel.status.state == .paused {
                Button {
                    Task { await viewModel.resume() }
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.top, 6)
    }

    private func rowsSection(title: String, rows: [HermesCuratorSkillRow]) -> some View {
        Section(title) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(row.name)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            Task { await viewModel.pin(row.name) }
                        } label: {
                            Image(systemName: viewModel.status.pinnedNames.contains(row.name) ? "pin.fill" : "pin")
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 6) {
                        Text("use \(row.useCount) · view \(row.viewCount) · patch \(row.patchCount)")
                            .font(ScarfFont.monoSmall)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.lastActivityLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ScarfColor.success)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .padding(.bottom, 12)
        .transition(.opacity)
    }
}

#endif
