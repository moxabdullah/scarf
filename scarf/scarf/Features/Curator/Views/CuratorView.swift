import SwiftUI
import ScarfCore
import ScarfDesign

/// Mac UI for Hermes v0.12's autonomous skill curator.
///
/// Surfaces the running state (enabled / paused / disabled), last-run
/// metadata, agent-created skill counts, and the most/least-active /
/// least-recently-active leaderboards. Pin-and-restore actions hit
/// `hermes curator pin/unpin/restore` via CuratorViewModel.
///
/// Capability-gated upstream: AppCoordinator only wires the sidebar
/// item when `HermesCapabilities.hasCurator` is true. This view assumes
/// it's reachable on a v0.12+ host.
struct CuratorView: View {
    @State private var viewModel: CuratorViewModel
    @State private var showRestoreSheet = false

    init(context: ServerContext) {
        _viewModel = State(initialValue: CuratorViewModel(context: context))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ScarfSpace.s4) {
                ScarfPageHeader(
                    "Curator",
                    subtitle: "Autonomous skill maintenance — Hermes v0.12+"
                ) {
                    HStack(spacing: ScarfSpace.s2) {
                        if viewModel.isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Button("Run Now") {
                            Task { await viewModel.runNow() }
                        }
                        .buttonStyle(ScarfPrimaryButton())
                        .disabled(viewModel.isLoading)
                        Menu {
                            switch viewModel.status.state {
                            case .paused:
                                Button("Resume") { Task { await viewModel.resume() } }
                            case .enabled:
                                Button("Pause") { Task { await viewModel.pause() } }
                            default:
                                EmptyView()
                            }
                            Button("Restore Archived…") {
                                showRestoreSheet = true
                            }
                            .disabled(viewModel.status.archivedSkills == 0)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }

                if let toast = viewModel.transientMessage {
                    transientToast(toast)
                }

                statusSummary
                skillCountsSection
                pinnedSection
                activityTables

                if let report = viewModel.lastReportMarkdown {
                    lastReportSection(markdown: report)
                }
            }
            .padding(ScarfSpace.s4)
        }
        .background(ScarfColor.backgroundPrimary)
        .task { await viewModel.load() }
        .sheet(isPresented: $showRestoreSheet) {
            CuratorRestoreSheet(viewModel: viewModel)
        }
    }

    private var statusSummary: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                HStack {
                    statusBadge
                    Spacer()
                    Text("\(viewModel.status.runCount) runs")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                }
                ScarfDivider()
                infoRow(label: "Last run", value: viewModel.status.lastRunISO ?? "Never")
                if let summary = viewModel.status.lastSummary {
                    infoRow(label: "Last summary", value: summary)
                }
                infoRow(label: "Interval", value: viewModel.status.intervalLabel)
                infoRow(label: "Stale after", value: viewModel.status.staleAfterLabel)
                infoRow(label: "Archive after", value: viewModel.status.archiveAfterLabel)
            }
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

    private var skillCountsSection: some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader("Agent-created skills")
                HStack(spacing: ScarfSpace.s4) {
                    countCell(value: viewModel.status.totalSkills, label: "Total")
                    countCell(value: viewModel.status.activeSkills, label: "Active")
                    countCell(value: viewModel.status.staleSkills, label: "Stale")
                    countCell(value: viewModel.status.archivedSkills, label: "Archived")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var pinnedSection: some View {
        if !viewModel.status.pinnedNames.isEmpty {
            ScarfCard {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    ScarfSectionHeader("Pinned")
                    Text("Pinned skills are never auto-archived or rewritten by the curator.")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                    FlowLayout(spacing: ScarfSpace.s2) {
                        ForEach(viewModel.status.pinnedNames, id: \.self) { name in
                            HStack(spacing: 4) {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 10))
                                Text(name)
                                    .scarfStyle(.caption)
                                Button {
                                    Task { await viewModel.unpin(name) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(ScarfColor.foregroundMuted)
                                }
                                .buttonStyle(.plain)
                                .help("Unpin")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: ScarfRadius.md)
                                    .fill(ScarfColor.accentTint)
                            )
                        }
                    }
                }
            }
        }
    }

    private var activityTables: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s4) {
            if !viewModel.status.leastRecentlyActive.isEmpty {
                skillTable(title: "Least recently active", rows: viewModel.status.leastRecentlyActive)
            }
            if !viewModel.status.mostActive.isEmpty {
                skillTable(title: "Most active", rows: viewModel.status.mostActive)
            }
            if !viewModel.status.leastActive.isEmpty {
                skillTable(title: "Least active", rows: viewModel.status.leastActive)
            }
        }
    }

    private func skillTable(title: String, rows: [HermesCuratorSkillRow]) -> some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader(title)
                ForEach(rows) { row in
                    HStack(alignment: .center, spacing: ScarfSpace.s2) {
                        Text(row.name)
                            .scarfStyle(.body)
                            .foregroundStyle(ScarfColor.foregroundPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        counterChip(label: "use", value: row.useCount)
                        counterChip(label: "view", value: row.viewCount)
                        counterChip(label: "patch", value: row.patchCount)
                        Text(row.lastActivityLabel)
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundFaint)
                            .frame(width: 92, alignment: .trailing)
                        Button {
                            Task { await viewModel.pin(row.name) }
                        } label: {
                            Image(systemName: viewModel.status.pinnedNames.contains(row.name)
                                  ? "pin.fill" : "pin")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.status.pinnedNames.contains(row.name) ? "Pinned" : "Pin skill")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func counterChip(label: String, value: Int) -> some View {
        Text("\(label) \(value)")
            .font(ScarfFont.monoSmall)
            .foregroundStyle(ScarfColor.foregroundMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: ScarfRadius.sm)
                    .fill(ScarfColor.backgroundTertiary)
            )
    }

    private func lastReportSection(markdown: String) -> some View {
        ScarfCard {
            VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                ScarfSectionHeader("Last report")
                Text(markdown)
                    .scarfStyle(.mono)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .scarfStyle(.body)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
    }

    private func countCell(value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .scarfStyle(.title2)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Text(label)
                .scarfStyle(.captionUppercase)
                .foregroundStyle(ScarfColor.foregroundMuted)
        }
        .frame(minWidth: 64, alignment: .leading)
    }

    private func transientToast(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(ScarfColor.success)
            Text(text)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: ScarfRadius.md))
    }
}

/// Simple `FlowLayout` for the pinned-skill chips. Custom layout
/// keeps the chip wrap behaviour predictable across DynamicType
/// scales without resorting to LazyVGrid (which forces fixed columns).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
