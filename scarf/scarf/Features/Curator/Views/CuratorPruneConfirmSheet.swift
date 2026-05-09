import SwiftUI
import ScarfCore
import ScarfDesign

/// Destructive-confirm sheet for `hermes curator prune` (bulk).
///
/// Pattern matches `TemplateUninstallSheet`: enumerate every entry that
/// will be removed, surface the total count + bytes, and require an
/// explicit click on a red `ScarfDestructiveButton` ("Prune
/// permanently") before kicking off the destructive call. Cancel owns
/// the keyboard default action so an accidental Enter-press doesn't
/// nuke the archive.
struct CuratorPruneConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let summary: CuratorPruneSummary
    let isPruning: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, ScarfSpace.s2)
            ScarfDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: ScarfSpace.s2) {
                    ForEach(summary.wouldRemove) { skill in
                        row(skill: skill)
                    }
                    if summary.wouldRemove.isEmpty {
                        Text("Nothing currently archived. Nothing to prune.")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.foregroundMuted)
                            .padding(.vertical, ScarfSpace.s2)
                    }
                }
                .padding(.vertical, ScarfSpace.s2)
            }
            ScarfDivider()
            footer
                .padding(.top, ScarfSpace.s2)
        }
        .frame(minWidth: 520, minHeight: 380)
        .padding(ScarfSpace.s4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s1) {
            HStack(alignment: .firstTextBaseline) {
                Text("Prune Archived Skills")
                    .scarfStyle(.title2)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                Spacer()
                if summary.totalCount > 0 {
                    ScarfBadge("\(summary.totalCount)", kind: .danger)
                }
            }
            Text("This permanently deletes every archived skill from disk. Restoring an archived skill is no longer possible after pruning.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .fixedSize(horizontal: false, vertical: true)
            if summary.totalBytes > 0 {
                Text("Total to remove: \(summary.totalBytesLabel)")
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundFaint)
            }
        }
    }

    private func row(skill: HermesCuratorArchivedSkill) -> some View {
        HStack(spacing: ScarfSpace.s2) {
            Image(systemName: "minus.circle")
                .foregroundStyle(ScarfColor.danger)
                .font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .scarfStyle(.body)
                    .foregroundStyle(ScarfColor.foregroundPrimary)
                    .lineLimit(1)
                if let reason = skill.reason, !reason.isEmpty {
                    Text(reason)
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.foregroundMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(skill.archivedAtLabel)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .frame(width: 96, alignment: .trailing)
            Text(skill.sizeLabel)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .buttonStyle(ScarfGhostButton())
            // Cancel owns .defaultAction so accidental Enter-presses
            // don't trigger the destructive button (template-uninstall
            // pattern recommended in the WS-4 plan).
            .keyboardShortcut(.defaultAction)
            .disabled(isPruning)
            Spacer()
            if isPruning {
                ProgressView().controlSize(.small)
            }
            Button("Prune permanently") {
                onConfirm()
            }
            .buttonStyle(ScarfDestructiveButton())
            .disabled(isPruning || summary.wouldRemove.isEmpty)
            .accessibilityIdentifier("curatorPrune.confirm")
        }
    }
}
