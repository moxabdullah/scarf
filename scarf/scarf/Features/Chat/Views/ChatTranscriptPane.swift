import SwiftUI
import ScarfCore
import ScarfDesign

/// Middle pane of the 3-pane chat layout — composes the existing
/// `SessionInfoBar` + `RichChatMessageList` + `RichChatInputBar` with
/// no new state of its own. Pulled out of `RichChatView` so the
/// 3-pane HStack is readable.
struct ChatTranscriptPane: View {
    @Bindable var richChat: RichChatViewModel
    @Bindable var chatViewModel: ChatViewModel
    var onSend: (String, [ChatImageAttachment]) -> Void
    var isEnabled: Bool
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    var body: some View {
        VStack(spacing: 0) {
            SessionInfoBar(
                session: richChat.currentSession,
                isWorking: richChat.isGenerating,
                acpInputTokens: richChat.acpInputTokens,
                acpOutputTokens: richChat.acpOutputTokens,
                acpThoughtTokens: richChat.acpThoughtTokens,
                acpCompressionCount: richChat.acpCompressionCount,
                projectName: chatViewModel.currentProjectName,
                gitBranch: chatViewModel.currentGitBranch,
                activeGoal: richChat.activeGoal,
                onClearGoal: { chatViewModel.sendText("/goal --clear") },
                queuedPrompts: richChat.queuedPrompts,
                capabilities: capabilitiesStore?.capabilities ?? .empty
            )
            Divider()

            // Always mount RichChatMessageList; empty state lives inside it.
            // Swapping between a ContentUnavailableView and the ScrollView
            // hierarchy on first message caused a full view tree rebuild,
            // which manifests as a white flash.
            RichChatMessageList(
                groups: richChat.messageGroups,
                isWorking: richChat.isGenerating,
                isLoadingSession: chatViewModel.isPreparingSession,
                scrollTrigger: richChat.scrollTrigger,
                turnDurations: richChat.turnDurations,
                hasMoreHistory: richChat.hasMoreHistory,
                isLoadingEarlier: richChat.isLoadingEarlier,
                onLoadEarlier: { Task { await richChat.loadEarlier() } }
            )

            Divider()
            if let hint = richChat.transientHint {
                steeringToast(hint)
            }
            // Issue #62: bind composer identity to the active session
            // ID so SwiftUI rebuilds `RichChatInputBar` (and its
            // `@State` `text`/`attachments`) when the user switches
            // conversations. Without this the composer is structurally
            // identical across sessions and SwiftUI happily reuses the
            // instance, leaking the unsent draft into the new session.
            // A stable fallback id covers the brief "no session
            // selected" window — using `UUID()` here would mint a
            // fresh value per render and trash the composer on every
            // body re-eval.
            RichChatInputBar(
                onSend: onSend,
                isEnabled: isEnabled,
                commands: richChat.availableCommands,
                showCompressButton: richChat.supportsCompress && !richChat.hasBroaderCommandMenu,
                isAgentWorking: richChat.isAgentWorking
            )
            .id(richChat.sessionId ?? "scarf.chat.no-session")
        }
        .background(ScarfColor.backgroundPrimary)
    }

    /// Soft pill above the composer that confirms a non-interruptive
    /// command (e.g. `/steer`) was received. Auto-clears after a short
    /// delay (managed by `ChatViewModel`); presence in the model is what
    /// drives this view.
    private func steeringToast(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .foregroundStyle(ScarfColor.accent)
                .scarfStyle(.caption)
            Text(hint)
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundPrimary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ScarfSpace.s3)
        .padding(.vertical, 6)
        .background(ScarfColor.accentTint)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
