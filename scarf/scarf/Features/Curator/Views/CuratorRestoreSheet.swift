import SwiftUI
import ScarfCore
import ScarfDesign

/// Modal that lists archived skills (state ≠ active) and exposes a
/// one-click "Restore" action per row. v0.12 archives are recoverable —
/// `hermes curator restore <name>` brings the skill back into
/// `~/.hermes/skills/<category>/<name>/` and re-marks it active.
///
/// The Curator's `status` text doesn't enumerate archived skills with
/// names; we surface what's available (counts + pinned list) and rely
/// on the user knowing the names. Hermes ergo does an interactive
/// `--name` arg if missing — but Scarf prefers explicit selection so
/// users don't have to remember names. For v2.6 we render a free-form
/// text field; once Hermes ships a `curator list-archived` (tracked
/// upstream), swap to a pickable list.
struct CuratorRestoreSheet: View {
    let viewModel: CuratorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var skillName: String = ""
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: ScarfSpace.s3) {
            Text("Restore Archived Skill")
                .scarfStyle(.headline)
                .foregroundStyle(ScarfColor.foregroundPrimary)

            Text("Hermes archives skills the curator decides are stale or redundant. Restoring brings the original SKILL.md back into place — no data lost.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)

            VStack(alignment: .leading, spacing: ScarfSpace.s1) {
                Text("Skill name")
                    .scarfStyle(.captionUppercase)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                ScarfTextField("e.g. legacy-helper", text: $skillName)
            }

            Text("\(viewModel.status.archivedSkills) archived skill(s) available — list them with `hermes curator status`.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(ScarfGhostButton())
                Button("Restore") {
                    let trimmed = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    isRestoring = true
                    Task {
                        await viewModel.restore(trimmed)
                        isRestoring = false
                        dismiss()
                    }
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(isRestoring || skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(ScarfSpace.s5)
        .frame(width: 420)
    }
}
