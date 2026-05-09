import SwiftUI
import ScarfCore
import ScarfDesign

struct SessionInfoBar: View {
    let session: HermesSession?
    let isWorking: Bool
    /// Fallback token counts from ACP prompt results (DB may have zeros for ACP sessions).
    var acpInputTokens: Int = 0
    var acpOutputTokens: Int = 0
    var acpThoughtTokens: Int = 0
    /// Number of context compactions Hermes has run on this session. v0.13+
    /// surface — capability-gated by the bar so pre-v0.13 hosts never see
    /// the chip even if a stale value somehow trickles through. Defaults
    /// to 0 so existing callers and previews don't need to be updated.
    var acpCompressionCount: Int = 0
    /// Name of the Scarf project this session is attributed to, when
    /// applicable. Nil for plain global chats. Drives the folder-chip
    /// indicator rendered before the session title. Resolved by
    /// `ChatViewModel.currentProjectName` — the view just passes it
    /// through.
    var projectName: String? = nil
    /// Current git branch of the project's working directory, when
    /// resolved (v2.5). Renders as a tinted chip after the project
    /// name. Nil for non-project chats and for projects that aren't
    /// git repos.
    var gitBranch: String? = nil
    /// Active locked goal (Hermes v0.13 `/goal`). Nil hides the pill.
    /// Optimistic — set by `RichChatViewModel.recordActiveGoal(text:)`
    /// when the user sends `/goal …`.
    var activeGoal: HermesActiveGoal? = nil
    /// Invoked when the user picks "Clear goal" from the goal pill's
    /// context menu. Caller dispatches `/goal --clear` so the optimistic
    /// pill clear and the server-side authoritative state stay in sync.
    var onClearGoal: (() -> Void)? = nil
    /// Local mirror of prompts queued via `/queue …` (Hermes v0.13).
    /// Empty list hides the chip.
    var queuedPrompts: [HermesQueuedPrompt] = []
    /// Capability snapshot for v0.13+ surfaces. Defaulted so previews and
    /// pre-v0.13 hosts render the v2.7.5 layout unchanged. Coordinated
    /// with WS-2 — both WSes add `capabilities` to this view.
    var capabilities: HermesCapabilities = .empty

    /// Active Hermes profile name (issue #50). Resolved on each body
    /// re-evaluation; the resolver caches for 5s so this is cheap.
    /// Chip renders only when not "default" so existing (non-profile)
    /// installations see no change in the bar.
    private var activeProfile: String {
        HermesProfileResolver.activeProfileName()
    }

    var body: some View {
        HStack(spacing: 16) {
            if let session {
                // Profile chip leftmost — surfaces which Hermes profile
                // Scarf is reading (issue #50). Without this users couldn't
                // tell whether the visible session list came from the
                // profile they thought they switched to.
                if activeProfile != "default" {
                    Label(activeProfile, systemImage: "person.crop.square")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.warning)
                        .lineLimit(1)
                        .help("Scarf is reading from Hermes profile \"\(activeProfile)\". Switch profiles with `hermes profile use <name>` and relaunch Scarf.")
                }
                // Project indicator first — visually anchors the session
                // as "scoped to project X" before the working dot and
                // title. Hidden for non-project chats so the bar looks
                // identical to v2.2.1 behavior.
                if let projectName {
                    Label(projectName, systemImage: "folder.fill")
                        .scarfStyle(.caption)
                        .foregroundStyle(ScarfColor.accent)
                        .lineLimit(1)
                        .help("Chat is scoped to Scarf project \"\(projectName)\"")
                    if let gitBranch {
                        Label(gitBranch, systemImage: "arrow.triangle.branch")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.accent)
                            .lineLimit(1)
                            .help("Project's current git branch")
                    }
                }

                // Goal pill (v2.8 / Hermes v0.13). `.info` keeps it
                // visually decodable from the rust accent (project /
                // branch) and the warning amber (queue chip). The
                // pill renders only when `activeGoal` is non-nil —
                // pre-v0.13 hosts can't reach the `/goal` send path
                // through the slash menu (it's filtered out in
                // `availableCommands`), so the pill stays absent there
                // by transitive impossibility.
                if let activeGoal {
                    HStack(spacing: 4) {
                        Image(systemName: "scope")
                        Text(Self.truncatedGoal(activeGoal.text))
                    }
                    .scarfStyle(.caption)
                    .padding(.horizontal, ScarfSpace.s2)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(ScarfColor.info.opacity(0.16)))
                    .foregroundStyle(ScarfColor.info)
                    .help("Goal locked: \(activeGoal.text)")
                    .contextMenu {
                        if let onClearGoal {
                            Button("Clear goal", role: .destructive, action: onClearGoal)
                        }
                    }
                }

                // Queue chip (v2.8 / Hermes v0.13). Local mirror only —
                // Hermes is the authoritative owner of the actual
                // queue. Per-entry deletion isn't exposed (Hermes has
                // no remove-by-id verb), and the v2.8.0 plan drops the
                // global "Clear all" button to avoid lying about
                // server-side state. The popover is read-only.
                if !queuedPrompts.isEmpty {
                    ChatQueueIndicator(queuedPrompts: queuedPrompts)
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(isWorking ? ScarfColor.success : ScarfColor.foregroundFaint)
                        .frame(width: 6, height: 6)
                        .opacity(isWorking ? 1 : 0.6)
                    if isWorking {
                        Text("Working")
                            .scarfStyle(.caption)
                            .foregroundStyle(ScarfColor.success)
                    }
                }

                if let title = session.title, !title.isEmpty {
                    Text(title)
                        .scarfStyle(.captionStrong)
                        .foregroundStyle(ScarfColor.foregroundPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if let model = session.model {
                    Label(model, systemImage: "cpu")
                }

                let inputToks = session.inputTokens > 0 ? session.inputTokens : acpInputTokens
                let outputToks = session.outputTokens > 0 ? session.outputTokens : acpOutputTokens
                Label("\(formatTokens(inputToks)) in / \(formatTokens(outputToks)) out", systemImage: "number")
                    .contentTransition(.numericText())

                let reasonToks = session.reasoningTokens > 0 ? session.reasoningTokens : acpThoughtTokens
                if reasonToks > 0 {
                    Label("\(formatTokens(reasonToks)) reasoning", systemImage: "brain")
                }

                // v0.13: Hermes surfaces a running count of automatic
                // context compactions. Render only when the host is on
                // v0.13+ AND the count is non-zero, so a pre-v0.13 host
                // (which always reports 0) sees no chip, and a v0.13 host
                // sees the chip the first time the agent compacts.
                if capabilities.hasContextCompressionCount && acpCompressionCount > 0 {
                    Label(
                        "×\(acpCompressionCount)",
                        systemImage: "arrow.down.right.and.arrow.up.left"
                    )
                    .scarfStyle(.caption)
                    .foregroundStyle(ScarfColor.foregroundMuted)
                    .help("Hermes auto-compacted this session's context \(acpCompressionCount) time\(acpCompressionCount == 1 ? "" : "s")")
                }

                if let cost = session.displayCostUSD {
                    let formattedCost = cost.formatted(.currency(code: "USD").precision(.fractionLength(4)))
                    Label(session.costIsActual ? formattedCost : "\(formattedCost) est.", systemImage: "dollarsign.circle")
                        .contentTransition(.numericText())
                }

                if let start = session.startedAt {
                    Label {
                        Text(start, style: .relative)
                            .monospacedDigit()
                    } icon: {
                        Image(systemName: "clock")
                    }
                }

                Spacer()

                Label(session.source, systemImage: session.sourceIcon)
            } else {
                Text("No active session")
                    .foregroundStyle(ScarfColor.foregroundFaint)
                Spacer()
            }
        }
        .scarfStyle(.caption)
        .foregroundStyle(ScarfColor.foregroundMuted)
        .padding(.horizontal, ScarfSpace.s4)
        .padding(.vertical, 6)
        .background(ScarfColor.backgroundSecondary)
        .overlay(
            Rectangle().fill(ScarfColor.border).frame(height: 1),
            alignment: .bottom
        )
    }

    private func formatTokens(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    /// Cap goal text in the chip to keep the SessionInfoBar from
    /// wrapping when the user locks a long goal. Full goal text is
    /// available in the tooltip via `.help(...)`.
    static func truncatedGoal(_ text: String) -> String {
        text.count <= 36 ? text : String(text.prefix(33)) + "…"
    }
}
