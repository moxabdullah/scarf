import Foundation
import ScarfCore
import AppKit
import SwiftTerm
import os

@Observable
final class ChatViewModel {
    private let logger = Logger(subsystem: "com.scarf", category: "ChatViewModel")
    let context: ServerContext
    private let dataService: HermesDataService
    private let fileService: HermesFileService

    init(context: ServerContext = .local) {
        self.context = context
        self.dataService = HermesDataService(context: context)
        self.fileService = HermesFileService(context: context)
        self.richChatViewModel = RichChatViewModel(context: context)
        // Probe hermes binary existence once off-main, then cache. Doing
        // this synchronously inside `hermesBinaryExists`'s getter would
        // block main on every chat-body re-evaluation — for a remote
        // context that's a SSH `test -e` round-trip on every streaming
        // chunk, which manifests as the chat screen flashing or going
        // blank during prompts.
        Task.detached(priority: .userInitiated) { [context] in
            let exists = context.fileExists(context.paths.hermesBinary)
            await MainActor.run { [weak self] in
                self?.hermesBinaryExists = exists
            }
        }
    }


    var recentSessions: [HermesSession] = []
    var sessionPreviews: [String: String] = [:]

    /// Debounce handle for watcher-driven `loadRecentSessions` calls.
    /// During an active ACP conversation the file watcher fires many
    /// times per second (every message Hermes persists writes to
    /// `state.db-wal`); without this, every tick spawned a fresh
    /// reload task whose `recentSessions = …` reassignment re-rendered
    /// the chat sidebar and caused the list to visibly disappear /
    /// reappear during a streaming response. The debounce coalesces
    /// rapid bursts into one trailing fetch ~500 ms after the last
    /// tick. Created/resumed sessions still appear immediately because
    /// `startACPSession` and `autoStartACPAndSend` call
    /// `loadRecentSessions()` directly outside this path.
    @ObservationIgnored
    private var sessionsRefreshTask: Task<Void, Never>?

    /// L2 (v2.8) — in-flight coalescing handle for `loadRecentSessions`.
    /// On a slow remote each load is a 1.5–2.5s SSH round-trip; the
    /// 500 ms `scheduleSessionsRefresh` debounce only suppresses a
    /// pending tick, not one that's already executing. Without this
    /// guard, file-watcher deltas during a stream stack 2–3 parallel
    /// loadRecentSessions tasks (observed at t=305844 in 2026-05-05
    /// dogfooding). The in-flight pointer lets a second caller await
    /// the active task instead of spawning another SSH subprocess.
    @ObservationIgnored
    private var inFlightSessionLoad: Task<Void, Never>?

    /// Per-recent-session project attribution. Keyed by `HermesSession.id`,
    /// value is the project's display name. Populated alongside
    /// `recentSessions` via a single batched read in `loadRecentSessions()`.
    /// Sessions with no entry are unattributed (global / quick chats).
    private(set) var sessionProjectNames: [String: String] = [:]

    /// All registered projects, used to build the project filter menu in
    /// the chat session list pane. Loaded alongside `sessionProjectNames`.
    private(set) var allProjects: [ProjectEntry] = []
    var terminalView: LocalProcessTerminalView?
    var hasActiveProcess = false
    var voiceEnabled = false
    var ttsEnabled = false
    var isRecording = false
    var displayMode: ChatDisplayMode = .richChat
    let richChatViewModel: RichChatViewModel
    private var coordinator: Coordinator?

    /// Capability store the chat surface reads from. Set by `ChatView`
    /// at body-evaluation time via `attachCapabilitiesStore(_:)` —
    /// `@ObservationIgnored` so capability refreshes don't force a
    /// full chat re-render. Forwards into
    /// `RichChatViewModel.capabilitiesGate` whenever the published
    /// snapshot changes; the slash menu reads through that. v2.8 /
    /// Hermes v0.13 — gates `/goal` + `/queue` slash menu rows.
    @ObservationIgnored
    var capabilitiesStore: HermesCapabilitiesStore?

    /// Wire the Mac chat view's environment-injected capabilities store
    /// into both this VM and its child rich-chat VM. Idempotent on the
    /// pointer (re-attaching the same store is a no-op); always
    /// re-publishes the latest snapshot so a refresh that fired before
    /// the chat view became visible still lands.
    @MainActor
    func attachCapabilitiesStore(_ store: HermesCapabilitiesStore?) {
        capabilitiesStore = store
        richChatViewModel.publishCapabilities(store?.capabilities ?? .empty)
    }

    /// `callId` of the tool call currently surfaced in the chat
    /// inspector pane, or nil when nothing is focused. Set by
    /// `ToolCallCard` taps in the transcript; cleared by the inspector's
    /// xmark close. Mac-only state — the inspector is a Mac-target view,
    /// so this lives on the Mac `ChatViewModel` rather than the
    /// cross-platform `RichChatViewModel`.
    var focusedToolCallId: String?

    /// Resolved focus target for the inspector. Walks
    /// `richChatViewModel.messageGroups` to find the matching
    /// `HermesToolCall` and its tool-result message (when present).
    /// Returns nil when nothing is focused or the focused id no longer
    /// resolves (e.g., session reload swept it).
    var focusedToolCall: (call: HermesToolCall, result: HermesMessage?)? {
        guard let id = focusedToolCallId else { return nil }
        for group in richChatViewModel.messageGroups {
            for msg in group.assistantMessages {
                if let call = msg.toolCalls.first(where: { $0.callId == id }) {
                    return (call, group.toolResults[id])
                }
            }
        }
        return nil
    }

    /// Absolute project path for the current session, when the chat is
    /// project-scoped (either started via a project's "New Chat" button
    /// or resumed from a session that was previously attributed via the
    /// v2.3 sidecar). Nil for plain global chats. Drives the project
    /// indicator in SessionInfoBar + the `Chat · <Name>` nav title.
    private(set) var currentProjectPath: String?

    /// Git branch the project's working directory is currently on, or
    /// nil when the dir isn't a git repo / git isn't installed / the
    /// resolution failed. Populated alongside `currentProjectPath`;
    /// surfaced as a small chip after the project name in
    /// `SessionInfoBar`. v2.5.
    private(set) var currentGitBranch: String?

    /// Human-readable name of the active project, resolved from the
    /// projects registry at session-start time. Stored alongside the
    /// path so the view renders without hitting disk on every update.
    /// Nil when `currentProjectPath` is nil OR the path isn't in the
    /// registry (project was removed after the session was attributed).
    private(set) var currentProjectName: String?

    // ACP state
    private var acpClient: ACPClient?
    private var acpEventTask: Task<Void, Never>?
    private var acpPromptTask: Task<Void, Never>?
    private var healthMonitorTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var isHandlingDisconnect = false
    var isACPConnected: Bool { acpClient != nil && hasActiveProcess }
    var acpStatus: String = ""

    /// User-facing status strings that all map to "the session is in
    /// the middle of being established." Centralized so the toolbar
    /// status pill, the chat-pane loader, and `ChatSessionListPane`'s
    /// click-gating stay in sync. v2.8 added `loadingHistory` after
    /// the user reported the chat looked engageable while the
    /// 30-second `fetchMessages` was still in flight on a slow remote.
    static let preparingPhases: Set<String> = [
        ACPPhase.spawning,
        ACPPhase.authenticating,
        ACPPhase.creatingSession,
        ACPPhase.creatingNewSession,
        ACPPhase.loadingSession,
        ACPPhase.loadingHistory
    ]

    enum ACPPhase {
        static let spawning = "Spawning hermes acp…"
        static let authenticating = "Authenticating…"
        static let creatingSession = "Creating session…"
        static let creatingNewSession = "Creating new session…"
        static let loadingSession = "Loading session…"
        static let loadingHistory = "Loading history…"
        static let ready = "Ready"
        static let agentWorking = "Agent working…"
        static let cancelled = "Cancelled"
        static let failed = "Failed"
        static let error = "Error"
        static let connectionLost = "Connection lost"
    }

    /// Set true the moment the user kicks off a session-start path
    /// (resume / new / continue), cleared when the ACP session is
    /// fully ready or has failed. Decoupled from `hasActiveProcess`
    /// — that flag only flips true AFTER `client.start()` succeeds,
    /// which on remote contexts is a 5–7s window where the user sees
    /// nothing happening even though they've just clicked. v2.8 —
    /// fixes the gap between row-click and overlay-appears that
    /// the user reported in 2026-05-05 dogfooding.
    var isStartingSession: Bool = false

    /// True while a session is being established or restored — from the user
    /// kicking off "start chat" or "resume session" until the ACP session is
    /// ready for messages. The chat pane uses this to show a loader in place
    /// of the empty-state placeholder; `ChatSessionListPane` uses it to
    /// disable session-row taps so the user can't queue up a second
    /// switch while the first is still mid-boot (v2.8).
    var isPreparingSession: Bool {
        if isStartingSession { return true }
        guard hasActiveProcess else { return false }
        if Self.preparingPhases.contains(acpStatus) { return true }
        return acpStatus.hasPrefix("Reconnecting")
    }
    /// Error triplet moved to RichChatViewModel in M7 #2 so ScarfGo can
    /// share the same banner. These are forwarding accessors to keep
    /// the many existing call sites in this file unchanged.
    var acpError: String? {
        get { richChatViewModel.acpError }
        set { richChatViewModel.acpError = newValue }
    }
    var acpErrorHint: String? {
        get { richChatViewModel.acpErrorHint }
        set { richChatViewModel.acpErrorHint = newValue }
    }
    var acpErrorDetails: String? {
        get { richChatViewModel.acpErrorDetails }
        set { richChatViewModel.acpErrorDetails = newValue }
    }
    var acpErrorOAuthProvider: String? {
        get { richChatViewModel.acpErrorOAuthProvider }
        set { richChatViewModel.acpErrorOAuthProvider = newValue }
    }
    /// True when `hasAnyAICredential()` returned false at last preflight.
    var missingCredentials: Bool = false

    /// `model.default` / `model.provider` mismatch detected by the
    /// last `refreshConfigDiagnostics` pass. Drives the "Configuration
    /// mismatch" banner in `errorBanner`. Nil when config is coherent
    /// or unset. v2.8 — observed in dogfooding when switching OAuth
    /// providers via Credential Pools left a stale model prefix
    /// behind (e.g. `model.default: anthropic/...` with
    /// `model.provider: nous`); chats died with `-32603 Internal error`
    /// at first prompt with no diagnostic.
    var modelProviderMismatch: ModelPreflight.Mismatch?

    /// Set when chat-start is blocked because the active server's
    /// `config.yaml` has no `model.default` / `model.provider`. The chat
    /// view observes this and presents `ChatModelPreflightSheet`; on
    /// successful pick we persist via `setModelAndProvider` and re-attempt
    /// the original `startACPSession` call from `pendingStartArgs`.
    /// Nil when no preflight is pending.
    var modelPreflightReason: String?

    /// Stash of the original `startACPSession` arguments while we wait
    /// for the user to pick a model. Replayed verbatim once
    /// `confirmModelPreflight` writes the chosen model+provider to
    /// config.yaml. Cleared on cancel or after replay.
    private var pendingStartArgs: (sessionId: String?, projectPath: String?, initialPrompt: String?)?

    private static let maxReconnectAttempts = 5
    private static let reconnectBaseDelay: UInt64 = 1_000_000_000 // 1 second
    private static let maxReconnectDelay: UInt64 = 16_000_000_000 // 16 seconds

    /// Cached result of probing for `hermes` on the target server. Updated
    /// once at init by a detached task; defaults to `true` so the chat
    /// view doesn't briefly flash "Hermes not found" while the async
    /// probe runs. Set to `false` only after the probe confirms the
    /// binary really isn't there.
    var hermesBinaryExists: Bool = true

    /// Re-checks env + `~/.hermes/.env` for AI-provider credentials and
    /// updates `missingCredentials`. Cheap — safe to call from view `.task`.
    func refreshCredentialPreflight() {
        missingCredentials = !fileService.hasAnyAICredential()
    }

    /// Re-reads config.yaml and refreshes the
    /// `model.default` / `model.provider` mismatch state. Off-MainActor
    /// because `loadConfig()` is a synchronous file read (and an SSH
    /// round-trip on remote contexts). Safe to call from `.task` or
    /// after a write that would have changed config.
    func refreshConfigDiagnostics() {
        let svc = fileService
        Task.detached { [weak self] in
            let config = svc.loadConfig()
            let mismatch = ModelPreflight.detectMismatch(config)
            await MainActor.run { [weak self] in
                self?.modelProviderMismatch = mismatch
            }
        }
    }

    /// Persist a one-click mismatch fix. Aligns `model.provider` to the
    /// prefix carried in `model.default` (the user's "I just authed
    /// against this provider, that's what the prefix means" intent).
    /// Triggers a config-diagnostics refresh on completion to clear the
    /// banner if the write took. Failures fall through to the existing
    /// `acpError` banner so the user sees something happened.
    func alignProviderToModelPrefix(_ mismatch: ModelPreflight.Mismatch) {
        let svc = fileService
        Task.detached { [weak self] in
            // We pass the bare model so config.yaml ends up with a
            // clean (provider-prefix-free) model name alongside the
            // matching provider — matches what `confirmModelPreflight`
            // writes for a fresh setup.
            let ok = svc.setModelAndProvider(
                model: mismatch.bareModel,
                provider: mismatch.prefixProvider
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't write the new provider to config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// Persist the inverse mismatch fix — strip the provider prefix
    /// off `model.default` and keep `model.provider` as the active
    /// authoritative value. Use case: the user genuinely intended to
    /// switch their active provider and the stale prefix is the bug.
    func stripPrefixFromModelDefault(_ mismatch: ModelPreflight.Mismatch) {
        let svc = fileService
        Task.detached { [weak self] in
            let ok = svc.setModelAndProvider(
                model: mismatch.bareModel,
                provider: mismatch.activeProvider
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    self.modelProviderMismatch = nil
                } else {
                    self.acpError = "Couldn't rewrite model.default in config.yaml. Open Settings to fix manually."
                }
            }
        }
    }

    /// Forwarders to the ScarfCore implementation so the error-banner
    /// state lives in one place (M7 #2). The per-site logging label
    /// stays here — only the storage is shared.
    private func clearACPErrorState() {
        richChatViewModel.clearACPErrorState()
    }

    /// Auto-clear the chat composer's transient hint after 4 s. Shared
    /// helper for `/steer`, `/goal`, and `/queue` so the toast lifetime
    /// stays consistent across non-interruptive commands.
    @MainActor
    private func scheduleHintClear() {
        let snapshot = richChatViewModel.transientHint
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.richChatViewModel.transientHint == snapshot {
                self?.richChatViewModel.transientHint = nil
            }
        }
    }

    /// Pull the slash command name + raw argument tail out of the
    /// composer text. Returns `(name: nil, args: "")` for non-slash
    /// input. Mirrors the parser shape `RichChatViewModel.parseGoalArgument`
    /// expects; kept on `ChatViewModel` (not promoted to ScarfCore)
    /// because the Mac and iOS chat surfaces compose this with their
    /// own per-platform send paths.
    static func parseSlashName(_ text: String) -> (name: String?, args: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return (nil, "") }
        let withoutSlash = trimmed.dropFirst()
        if let space = withoutSlash.firstIndex(of: " ") {
            return (
                name: String(withoutSlash[..<space]),
                args: String(withoutSlash[withoutSlash.index(after: space)...])
            )
        }
        return (name: String(withoutSlash), args: "")
    }

    /// Cap goal text in transient toasts so a 1 KB user-typed goal
    /// doesn't blow out the hint pill. The header pill applies its
    /// own 33-char cap; the toast is shorter so the hint stays
    /// glanceable.
    static func truncatedToastGoal(_ text: String) -> String {
        text.count <= 60 ? text : String(text.prefix(57)) + "…"
    }

    @MainActor
    private func recordACPFailure(_ error: Error, client: ACPClient?, context: String) async {
        logger.error("\(context): \(error.localizedDescription)")
        await richChatViewModel.recordACPFailure(error, client: client)
    }

    // MARK: - Session Lifecycle

    func startNewSession(projectPath: String? = nil) {
        startNewSession(projectPath: projectPath, initialPrompt: nil)
    }

    /// Variant that auto-sends `initialPrompt` once the ACP session
    /// has connected. Used by the "New Project from Scratch" wizard
    /// (v2.8) to kick the conversation off with a message the agent
    /// recognizes as a `scarf-template-author` invocation, so the user
    /// doesn't have to type anything to begin the interview.
    /// Terminal mode ignores the prompt — the wizard runs in rich-chat
    /// only.
    func startNewSession(projectPath: String?, initialPrompt: String?) {
        // Flip the loading flag synchronously on the user's tap so
        // SwiftUI paints the session-list overlay on the same tick
        // — `startACPSession` won't reach `acpStatus = .spawning`
        // until the Task body runs, which on remote contexts is
        // multiple seconds after the click. v2.8.
        isStartingSession = true
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: nil, projectPath: projectPath, initialPrompt: initialPrompt)
        } else {
            // Terminal mode doesn't surface project attribution today —
            // `hermes chat` uses the shell's cwd, so starting a terminal
            // chat from a project button would require changing the
            // shell's cwd too. Out of scope for v2.3 — Rich Chat is
            // the primary surface for project-scoped sessions.
            launchTerminal(arguments: ["chat"])
        }
    }

    /// Start a new project-scoped ACP session and send `text` as the
    /// first prompt once connected. Thin wrapper named for the
    /// wizard's call site to make intent obvious; behaves identically
    /// to `startNewSession(projectPath:initialPrompt:)`.
    func startNewSessionAndSend(projectPath: String, text: String) {
        // Force rich-chat — the wizard handoff doesn't make sense in
        // terminal mode, and we'd silently swallow the initial prompt
        // if the user happened to be on the terminal segment.
        displayMode = .richChat
        startNewSession(projectPath: projectPath, initialPrompt: text)
    }

    func resumeSession(_ sessionId: String) {
        isStartingSession = true
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            startACPSession(resume: sessionId)
        } else {
            richChatViewModel.setSessionId(sessionId)
            launchTerminal(arguments: ["chat", "--resume", sessionId])
        }
    }

    func continueLastSession() {
        isStartingSession = true
        voiceEnabled = false
        ttsEnabled = false
        isRecording = false
        richChatViewModel.reset()

        if displayMode == .richChat {
            // Find most recent session and resume via ACP
            Task { @MainActor in
                let opened = await dataService.open()
                if !opened {
                    isStartingSession = false
                    acpError = context.isRemote
                        ? "Couldn't reach \(context.displayName). Check the SSH connection and try again."
                        : "Couldn't open the Hermes state database."
                    acpErrorHint = nil
                    acpErrorDetails = nil
                    return
                }
                let sessionId = await dataService.fetchMostRecentlyActiveSessionId()
                await dataService.close()
                if let sessionId {
                    startACPSession(resume: sessionId)
                } else {
                    startACPSession(resume: nil)
                }
            }
        } else {
            launchTerminal(arguments: ["chat", "--continue"])
        }
    }

    // MARK: - Send Message

    func sendText(_ text: String) {
        sendText(text, images: [])
    }

    /// v0.12+ overload: forward image attachments alongside the text.
    /// Empty `images` keeps the legacy v0.11 wire shape; non-empty images
    /// only flow when `HermesCapabilities.hasACPImagePrompts` is true
    /// (the input bar gates the attachment UI on the same flag, so a
    /// non-empty array reaching here means we've already verified the
    /// agent supports it).
    ///
    /// Terminal mode silently drops attachments — there's no way to
    /// pipe binary content through the TTY. Surface a one-shot warning
    /// so the user knows.
    func sendText(_ text: String, images: [ChatImageAttachment]) {
        if displayMode == .richChat {
            if let client = acpClient {
                sendViaACP(client: client, text: text, images: images)
            } else {
                // Auto-start ACP and send the queued message
                autoStartACPAndSend(text: text, images: images)
            }
        } else if let tv = terminalView {
            if !images.isEmpty {
                logger.warning("Terminal-mode chat dropped \(images.count) image attachment(s) — image input only works in ACP rich-chat mode")
                acpError = "Image attachments require ACP mode (rich chat)."
            }
            sendToTerminal(tv, text: text + "\r")
        }
    }

    /// Start ACP for the current session (or create a new one), then send the
    /// queued prompt. Typing into a blank Chat screen ALWAYS creates a new
    /// session — the "Continue from Last Session" button is the explicit path
    /// for resuming. The previous behavior (falling back to the most recently
    /// active session in the DB) would pick up cron/background sessions the
    /// user never interacted with; those can be garbage-collected by Hermes
    /// between the DB read and ACP `session/load`, producing a silent prompt
    /// failure with no UI feedback.
    private func autoStartACPAndSend(text: String, images: [ChatImageAttachment] = []) {
        isStartingSession = true
        // Show the user message immediately
        richChatViewModel.addUserMessage(text: text)

        Task { @MainActor in
            let sessionToResume = richChatViewModel.sessionId

            let client = ACPClient.forMacApp(context: context)
            self.acpClient = client

            do {
                acpStatus = ACPPhase.spawning
                try await client.start()
                acpStatus = ACPPhase.authenticating
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                let cwd = await context.resolvedUserHome()

                hasActiveProcess = true

                let resolvedSessionId: String
                if let existing = sessionToResume {
                    acpStatus = ACPPhase.loadingSession
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: existing)
                    } catch {
                        logger.info("Session \(existing) not found in ACP, creating new session")
                        acpStatus = ACPPhase.creatingNewSession
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = ACPPhase.ready
                isStartingSession = false

                // Surface the freshly-created session in the chat
                // sidebar immediately. We can't lean on the file
                // watcher to do this — it fires unconditionally
                // through `scheduleSessionsRefresh` which has a
                // 500 ms debounce. An explicit call here keeps the
                // "type → see new chat in the list" feedback prompt.
                await loadRecentSessions()

                // Now send the queued prompt
                sendViaACP(client: client, text: text, images: images)
            } catch {
                acpStatus = ACPPhase.failed
                isStartingSession = false
                await recordACPFailure(error, client: client, context: "Auto-start ACP failed")
                hasActiveProcess = false
                acpClient = nil
            }
        }
    }

    /// If `text` is a `/<name> [args]` invocation matching a project-
    /// scoped slash command currently loaded into the view model, return
    /// the expanded prompt body (with `{{argument}}` substituted). Otherwise
    /// return the input unchanged.
    ///
    /// ACP commands and `quick_commands:` keep going to Hermes literally —
    /// only project-scoped commands get the client-side expansion treatment
    /// because Hermes has no concept of them.
    private func expandIfProjectScoped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return text }
        let withoutSlash = String(trimmed.dropFirst())
        let name: String
        let argument: String
        if let space = withoutSlash.firstIndex(of: " ") {
            name = String(withoutSlash[..<space])
            argument = String(withoutSlash[withoutSlash.index(after: space)...])
        } else {
            name = withoutSlash
            argument = ""
        }
        guard !name.isEmpty,
              let cmd = richChatViewModel.projectScopedCommand(named: name)
        else { return text }
        return ProjectSlashCommandService(context: context).expand(cmd, withArgument: argument)
    }

    private func sendViaACP(client: ACPClient, text: String, images: [ChatImageAttachment] = []) {
        ScarfMon.event(.chatStream, "mac.sendViaACP", count: 1, bytes: text.utf8.count)
        guard let sessionId = richChatViewModel.sessionId else {
            clearACPErrorState()
            acpError = "No session ID — cannot send"
            return
        }

        // Don't duplicate user message if autoStartACPAndSend already added it
        if richChatViewModel.messages.last?.isUser != true
            || richChatViewModel.messages.last?.content != text {
            richChatViewModel.addUserMessage(text: text)
        }

        // Project-scoped slash commands expand client-side: the user
        // sees the literal `/<name> args` they typed (already in the
        // transcript as their bubble), but Hermes receives the expanded
        // prompt template. The literal slash is meaningless to Hermes
        // for project-scoped commands; this is what makes them portable
        // and Hermes-version-independent. v2.5.
        let wireText = expandIfProjectScoped(text)

        // Non-interruptive slash commands keep the "Agent working…"
        // indicator off and surface a transient toast confirming the
        // command was accepted. v2.5 added `/steer`; v2.8 / Hermes
        // v0.13 adds `/goal` (lock the agent on a target across turns)
        // and `/queue` (queue a prompt for after the current turn).
        // Each gets its own optimistic side-effect on RichChatViewModel
        // so the chat header pill / queue chip update synchronously
        // without waiting for a server round-trip.
        let isNonInterruptive = richChatViewModel.isNonInterruptiveSlash(text)
        let parsed = Self.parseSlashName(text)
        switch parsed.name {
        case "goal":
            // TODO(WS-2-Q7): once a v0.13 host confirms the
            // wire-shape, this branch fires only when the host
            // advertises `hasGoals`; pre-v0.13 hosts hide the menu
            // row, but a power-user typing `/goal` directly still
            // lands here. We keep the optimistic write so the pill
            // appears synchronously — the agent's "unknown command"
            // reply on a pre-v0.13 host paints the inconsistency in
            // user-visible chat content (acceptable v1 behavior;
            // see WS-2 plan "Inconsistency caveat").
            let arg = RichChatViewModel.parseGoalArgument(parsed.args)
            switch arg {
            case .set(let goalText):
                richChatViewModel.recordActiveGoal(text: goalText)
                richChatViewModel.transientHint = "Goal locked: \(Self.truncatedToastGoal(goalText))"
            case .clear:
                richChatViewModel.recordActiveGoal(text: nil)
                richChatViewModel.transientHint = "Goal cleared."
            case .empty:
                richChatViewModel.transientHint = "Sent /goal — see the agent reply for current goal."
            }
            scheduleHintClear()
        case "queue":
            // TODO(WS-2-Q5): verify against a real v0.13 ACP host
            // that the verbatim "/queue <text>" wire shape is what
            // Hermes accepts (versus a structured arg shape). The
            // optimistic mirror logic below assumes verbatim text.
            let queuedText = parsed.args.trimmingCharacters(in: .whitespacesAndNewlines)
            if !queuedText.isEmpty {
                richChatViewModel.recordQueuedPrompt(text: queuedText)
            }
            richChatViewModel.transientHint = "Queued — runs after current turn."
            scheduleHintClear()
        case "steer" where isNonInterruptive:
            richChatViewModel.transientHint = "Guidance queued — applies after the next tool call."
            scheduleHintClear()
        default:
            // Regular interruptive prompt (or an unrecognized slash).
            // Don't flip "Agent working…" for any other
            // non-interruptive command (defensive; matches the
            // legacy contract).
            if !isNonInterruptive { acpStatus = ACPPhase.agentWorking }
        }
        acpPromptTask = Task { @MainActor in
            do {
                let result = try await ScarfMon.measureAsync(.chatStream, "mac.sendPrompt") {
                    try await client.sendPrompt(sessionId: sessionId, text: wireText, images: images)
                }
                acpStatus = ACPPhase.ready
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: result)
                )
                // Re-fetch session from DB to pick up cost/token data Hermes may have written
                await richChatViewModel.refreshSessionFromDB()
                // Issue #64 — notify the user that Hermes has
                // finished if Scarf isn't the foreground app. The
                // notifier handles the foreground/disabled gating;
                // we just hand it the latest assistant text and
                // session title for the body line.
                if !isNonInterruptive {
                    let preview = richChatViewModel.messages
                        .last(where: { $0.isAssistant })?
                        .content ?? ""
                    let title = richChatViewModel.currentSession?.title
                    ChatNotificationService.shared.postPromptCompleted(
                        sessionTitle: title,
                        preview: preview
                    )
                }
            } catch is CancellationError {
                acpStatus = ACPPhase.cancelled
            } catch {
                acpStatus = ACPPhase.error
                await recordACPFailure(error, client: client, context: "ACP prompt failed")
                richChatViewModel.handleACPEvent(
                    .promptComplete(sessionId: sessionId, response: ACPPromptResult(
                        stopReason: "error",
                        inputTokens: 0, outputTokens: 0,
                        thoughtTokens: 0, cachedReadTokens: 0
                    ))
                )
            }
        }
    }

    // MARK: - ACP Session Management

    private func startACPSession(
        resume sessionId: String?,
        projectPath: String? = nil,
        initialPrompt: String? = nil
    ) {
        ScarfMon.event(.sessionLoad, "mac.startACPSession", count: 1)
        stopACP()
        clearACPErrorState()
        // stopACP() clears `isStartingSession` (it's a generic teardown
        // helper used by disconnect paths too). Re-arm it here so the
        // session-list overlay stays up through the entire boot.
        isStartingSession = true

        // Pre-flight: bail before opening any ACP plumbing if the
        // active server's `config.yaml` has no primary model or
        // provider. Hermes would otherwise let `session/new` succeed
        // and only fail at first prompt with an opaque
        // "Model parameter is required" 400. Stashing the start
        // arguments here lets `confirmModelPreflight` replay them
        // unchanged after the user picks a model.
        let preflight = ModelPreflight.check(fileService.loadConfig())
        if !preflight.isConfigured {
            pendingStartArgs = (sessionId, projectPath, initialPrompt)
            modelPreflightReason = preflight.reason
            acpStatus = ""
            hasActiveProcess = false
            isStartingSession = false
            return
        }

        acpStatus = ACPPhase.spawning

        let client = ACPClient.forMacApp(context: context)
        self.acpClient = client
        let attribution = SessionAttributionService(context: context)

        // If the caller passed a project path, refresh the Scarf-
        // managed block in the project's AGENTS.md BEFORE starting
        // ACP — Hermes auto-reads AGENTS.md at session boot, so the
        // block has to land on disk first. Non-blocking on failure:
        // we log and proceed without the block. Safe on bare
        // projects (creates AGENTS.md with just the block); safe on
        // template-installed projects (splices the block into
        // existing AGENTS.md without touching template content).
        let contextForPrep = context
        let prepLogger = logger
        Task { @MainActor in
            if let projectPath {
                // Synchronous file I/O (ProjectDashboardService.loadRegistry +
                // ProjectAgentContextService.refresh, which itself walks the
                // slash-commands directory) must run off the MainActor — the
                // detached task runs the work on the cooperative pool and we
                // await it here so the AGENTS.md block lands before client.start().
                await Task.detached {
                    let registry = ProjectDashboardService(context: contextForPrep).loadRegistry()
                    guard let project = registry.projects.first(where: { $0.path == projectPath }) else {
                        return
                    }
                    do {
                        try ProjectAgentContextService(context: contextForPrep).refresh(for: project)
                    } catch {
                        prepLogger.warning("couldn't refresh project context block for \(project.name): \(error.localizedDescription)")
                    }
                }.value
            }

            do {
                // Start ACP process and event loop FIRST
                try await client.start()
                acpStatus = ACPPhase.authenticating
                startACPEventLoop(client: client)
                startHealthMonitor(client: client)

                // Project-scoped chats pass the project's absolute path
                // as cwd so Hermes tool calls and subsequent ACP ops
                // resolve relative paths against the project's files.
                // Falls back to the user's home (existing v2.2 behavior)
                // when the caller didn't request a project scope.
                // `??` can't wrap an async autoclosure, so we
                // materialize the fallback with an if-let.
                let cwd: String
                if let projectPath {
                    cwd = projectPath
                } else {
                    cwd = await context.resolvedUserHome()
                }

                // Mark active BEFORE setting session ID so .task(id:) sees isACPMode=true
                // and doesn't wipe messages with a DB refresh
                hasActiveProcess = true

                let resolvedSessionId: String
                if let sessionId {
                    acpStatus = ACPPhase.loadingSession
                    do {
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        logger.info("Session \(sessionId) not found in ACP, creating new session with history")
                        acpStatus = ACPPhase.creatingNewSession
                        resolvedSessionId = try await client.newSession(cwd: cwd)
                    }
                    // Surface "Loading history…" before the (potentially
                    // 30s) message-history fetch fires. Pre-fix the user
                    // saw "Loading session…" through start(), then jump
                    // straight to "Ready" the moment the bytes hit the
                    // pane — but the actual hydrate is the slowest step
                    // on a remote and the pane looked engageable while
                    // the SQLite query was still pending. v2.8.
                    acpStatus = ACPPhase.loadingHistory
                    await richChatViewModel.loadSessionHistory(
                        sessionId: sessionId,
                        acpSessionId: resolvedSessionId
                    )
                } else {
                    acpStatus = ACPPhase.creatingSession
                    resolvedSessionId = try await client.newSession(cwd: cwd)
                }

                richChatViewModel.setSessionId(resolvedSessionId)
                acpStatus = ACPPhase.ready
                isStartingSession = false

                // Attribute this session to the project it was started
                // under, so the per-project Sessions tab can surface it
                // without a user action. No-op when projectPath is nil.
                // Idempotent: re-attribution of the same pair is free.
                if let projectPath {
                    attribution.attribute(
                        sessionID: resolvedSessionId,
                        toProjectPath: projectPath
                    )
                }

                // Resolve which project (if any) this session belongs
                // to, so SessionInfoBar + nav title can surface it.
                // Two inputs — use whichever is non-nil:
                //   * `projectPath` — the caller asked for a project
                //     scope (fresh project chat). Just-attributed;
                //     definitely in the sidecar.
                //   * `attribution.projectPath(for: resolvedSessionId)`
                //     — the resumed session was previously attributed.
                //     Covers "click an old project-attributed session
                //     from the global Sessions sidebar / Resume menu"
                //     where projectPath isn't known at the call site.
                let attributedPath = projectPath
                    ?? attribution.projectPath(for: resolvedSessionId)
                if let path = attributedPath {
                    // Look up a human-readable name from the projects
                    // registry. Missing project (path in the sidecar,
                    // project since removed) → show the path as a
                    // fallback label so the chip still renders and the
                    // user sees *something* rather than silently losing
                    // the indicator.
                    let registry = ProjectDashboardService(context: context).loadRegistry()
                    let name = registry.projects.first(where: { $0.path == path })?.name
                    self.currentProjectPath = path
                    self.currentProjectName = name ?? path
                    // Pull any project-scoped slash commands the user has
                    // authored at <path>/.scarf/slash-commands/ so the
                    // chat slash menu surfaces them. Async + non-fatal —
                    // the menu degrades to ACP + quick commands only on
                    // any failure (logged inside the service).
                    self.richChatViewModel.loadProjectScopedCommands(at: path)
                    // Resolve the project's current git branch (v2.5)
                    // for the chat header chip. Async + nil on failure
                    // (not a git repo / git missing / SSH error) — the
                    // chip just doesn't render.
                    let svc = GitBranchService(context: context)
                    Task { @MainActor [weak self] in
                        let branch = await svc.branch(at: path)
                        self?.currentGitBranch = branch
                    }
                } else {
                    // Explicit clear on non-project sessions so the
                    // indicator doesn't leak from a previous chat.
                    self.currentProjectPath = nil
                    self.currentProjectName = nil
                    self.currentGitBranch = nil
                    self.richChatViewModel.loadProjectScopedCommands(at: nil)
                }

                // Refresh session list so the new ACP session appears in the Resume menu
                await loadRecentSessions()

                logger.info("ACP session ready: \(resolvedSessionId)")

                // v2.8 wizard handoff: auto-send the kickoff prompt now
                // that the session is connected. Renders as a normal user
                // bubble (matches the user's intent — they triggered this
                // flow via the New Project sheet) and routes through the
                // same `sendViaACP` path that typed messages use, so the
                // event loop, attribution, and streaming are identical.
                if let prompt = initialPrompt,
                   !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    richChatViewModel.addUserMessage(text: prompt)
                    sendViaACP(client: client, text: prompt, images: [])
                }
            } catch {
                acpStatus = ACPPhase.failed
                isStartingSession = false
                await recordACPFailure(error, client: client, context: "Failed to start ACP session")
                hasActiveProcess = false
                acpClient = nil
            }
        }
    }

    private func startACPEventLoop(client: ACPClient) {
        acpEventTask = Task { @MainActor [weak self] in
            let eventStream = await client.events
            for await event in eventStream {
                guard !Task.isCancelled else { break }
                ScarfMon.event(.chatStream, "mac.acpEvent", count: 1)
                ScarfMon.measure(.chatStream, "mac.handleACPEvent") {
                    self?.richChatViewModel.handleACPEvent(event)
                }
                // Don't overwrite a phase-typed acpStatus with the
                // ACP-side "Connected" string mid-stream; we promote
                // to ready/agentWorking from the call sites that own
                // the lifecycle. The event-loop side-effect is
                // the heartbeat — leave acpStatus alone here.
                _ = await client.statusMessage
            }
            // Stream ended — if we weren't cancelled, the connection died
            if !Task.isCancelled {
                self?.handleConnectionDied()
            }
        }
    }

    private func startHealthMonitor(client: ACPClient) {
        healthMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                let healthy = await client.isHealthy
                if !healthy {
                    self?.handleConnectionDied()
                    break
                }
            }
        }
    }

    private func handleConnectionDied() {
        guard acpClient != nil, !isHandlingDisconnect else { return }
        isHandlingDisconnect = true
        logger.warning("ACP connection died")

        // Finalize any in-progress streaming message before reconnection
        richChatViewModel.finalizeOnDisconnect()

        // Save session ID for reconnection before cleaning up
        let savedSessionId = richChatViewModel.sessionId

        // Clean up the dead client
        acpPromptTask?.cancel()
        acpPromptTask = nil
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task { await client.stop() }
        }
        acpClient = nil
        hasActiveProcess = false

        // Attempt auto-reconnect if we have a session to restore
        guard let savedSessionId else {
            showConnectionFailure()
            isHandlingDisconnect = false
            return
        }
        attemptReconnect(sessionId: savedSessionId)
    }

    private func attemptReconnect(sessionId: String) {
        reconnectTask?.cancel()
        clearACPErrorState()

        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...Self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }

                acpStatus = "Reconnecting (\(attempt)/\(Self.maxReconnectAttempts))…"
                logger.info("Reconnect attempt \(attempt)/\(Self.maxReconnectAttempts) for session \(sessionId)")

                // Backoff delay (skip on first attempt for fast recovery)
                if attempt > 1 {
                    let delay = min(
                        Self.reconnectBaseDelay * UInt64(1 << (attempt - 1)),
                        Self.maxReconnectDelay
                    )
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let client = ACPClient.forMacApp(context: context)
                do {
                    try await client.start()

                    let cwd = await context.resolvedUserHome()
                    let resolvedSessionId: String

                    // Try resumeSession first (designed for reconnection), then loadSession.
                    // NEVER fall back to newSession — that loses all conversation context.
                    do {
                        resolvedSessionId = try await client.resumeSession(cwd: cwd, sessionId: sessionId)
                    } catch {
                        logger.info("session/resume failed, trying session/load: \(error.localizedDescription)")
                        resolvedSessionId = try await client.loadSession(cwd: cwd, sessionId: sessionId)
                    }

                    // Success — wire up the new client
                    self.acpClient = client
                    self.hasActiveProcess = true
                    richChatViewModel.setSessionId(resolvedSessionId)

                    // Reconcile in-memory messages with what Hermes persisted to DB
                    await richChatViewModel.reconcileWithDB(sessionId: resolvedSessionId)

                    acpStatus = ACPPhase.ready
                    clearACPErrorState()

                    startACPEventLoop(client: client)
                    startHealthMonitor(client: client)

                    isHandlingDisconnect = false
                    logger.info("Reconnected successfully on attempt \(attempt)")
                    return
                } catch {
                    logger.warning("Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                    await client.stop()
                    continue
                }
            }

            // All attempts exhausted
            guard !Task.isCancelled else { return }
            showConnectionFailure()
            isHandlingDisconnect = false
        }
    }

    private func showConnectionFailure() {
        richChatViewModel.handleACPEvent(.connectionLost(reason: "The ACP process terminated unexpectedly"))
        acpStatus = ACPPhase.connectionLost
        clearACPErrorState()
        acpError = "Connection lost. Use the Session menu to reconnect."
    }

    func stopACP() {
        reconnectTask?.cancel()
        reconnectTask = nil
        acpPromptTask?.cancel()
        acpPromptTask = nil
        acpEventTask?.cancel()
        acpEventTask = nil
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        if let client = acpClient {
            Task { await client.stop() }
        }
        acpClient = nil
        hasActiveProcess = false
        isHandlingDisconnect = false
        isStartingSession = false
    }

    // MARK: - Model preflight

    /// Called by `ChatModelPreflightSheet` once the user has picked a
    /// model in the embedded `ModelPickerSheet`. Persists the choice via
    /// `hermes config set` (transport-aware — works on remote droplets
    /// too) and replays the pending `startACPSession` call so the chat
    /// the user originally tried to open finally lands.
    @MainActor
    func confirmModelPreflight(model: String, provider: String) {
        let pending = pendingStartArgs
        modelPreflightReason = nil
        pendingStartArgs = nil

        let svc = fileService
        Task.detached { [weak self] in
            let ok = svc.setModelAndProvider(model: model, provider: provider)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if ok {
                    if let pending {
                        self.startACPSession(
                            resume: pending.sessionId,
                            projectPath: pending.projectPath,
                            initialPrompt: pending.initialPrompt
                        )
                    }
                } else {
                    self.acpError = "Couldn't save model+provider to config.yaml. Open Settings to retry."
                }
            }
        }
    }

    /// User dismissed the preflight sheet without picking a model. Drop
    /// the stashed start arguments and leave the chat in its idle state
    /// — no error banner, since this isn't a failure, just a deferral.
    @MainActor
    func cancelModelPreflight() {
        modelPreflightReason = nil
        pendingStartArgs = nil
    }

    /// Respond to a permission request from the ACP agent.
    func respondToPermission(optionId: String) {
        guard let client = acpClient,
              let permission = richChatViewModel.pendingPermission else { return }
        Task {
            await client.respondToPermission(requestId: permission.requestId, optionId: optionId)
        }
        richChatViewModel.pendingPermission = nil
    }

    // MARK: - Recent Sessions

    /// Coalesce rapid `loadRecentSessions` triggers into one trailing
    /// fetch. Hooked up to the file-watcher tick in `ChatView`; during
    /// an ACP message stream the watcher fires 5–10 times per second
    /// as Hermes appends to `state.db-wal`, and an unconditional
    /// reload on each tick would visibly flicker the chat sidebar
    /// while the response streams in.
    ///
    /// The 500 ms window is short enough that idle external changes
    /// (a session created from another `hermes` invocation, a rename
    /// from another window) still appear "soon" without explicit user
    /// action, and long enough to absorb a streaming-response burst.
    /// Newly created / resumed sessions in *this* window don't depend
    /// on the debounce — `startACPSession` and `autoStartACPAndSend`
    /// call `loadRecentSessions()` synchronously after the session id
    /// resolves, so the chat sidebar updates immediately.
    func scheduleSessionsRefresh() {
        // Track every file-watcher-driven debounce entry. During an ACP
        // stream this fires many times per second; the count helps us see
        // how often the watcher fires vs. how often a real reload executes.
        ScarfMon.event(.sessionLoad, "mac.scheduleSessionsRefresh", count: 1)
        sessionsRefreshTask?.cancel()
        sessionsRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await self?.loadRecentSessions()
        }
    }

    func loadRecentSessions() async {
        // L2 (v2.8) — coalesce against an in-flight load. If one's
        // already running, await its completion instead of spawning a
        // parallel one. Drops the 2-3× contention seen during file-
        // watcher streams.
        if let existing = inFlightSessionLoad {
            ScarfMon.event(.sessionLoad, "mac.loadRecentSessions.coalesced", count: 1)
            await existing.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoadRecentSessions()
        }
        inFlightSessionLoad = task
        await task.value
        inFlightSessionLoad = nil
    }

    private func performLoadRecentSessions() async {
        // Measure the full wall-clock cost of a sessions sidebar reload,
        // from DB open through the off-main attribution read to the final
        // observable assignment. Surfaces fetch regressions and SQLite
        // latency spikes in the ScarfMon trace.
        await ScarfMon.measureAsync(.sessionLoad, "mac.loadRecentSessions") {
            let opened = await dataService.open()
            guard opened else { return }
            // Bumped from 10 → 50 so the project filter has enough data to
            // surface attributed sessions (older attributed sessions were
            // getting truncated out of the original limit). Sessions feature
            // loads 500; the chat sidebar doesn't need that, but 50 keeps
            // the project filter useful without measurable cost.
            //
            // v2.7: folded sessions + previews into one queryBatch round
            // trip via sessionListSnapshot. Pre-fix the two awaits below
            // were serialized SSH calls, paying the 420 ms RTT twice
            // every time the file watcher fired (~2.2 s baseline reload).
            // sessionListSnapshot halves the round-trips for every
            // sidebar refresh.
            let snapshot = await dataService.sessionListSnapshot(limit: 50)
            let fetchedSessions = snapshot.sessions
            let fetchedPreviews = snapshot.previews
            await dataService.close()

            // Project attribution + registry — single batched off-main read.
            let ctx = context
            let bundle: (names: [String: String], projects: [ProjectEntry]) = await Task.detached {
                let attribution = SessionAttributionService(context: ctx)
                let registry = ProjectDashboardService(context: ctx).loadRegistry()
                let pathToName = Dictionary(
                    uniqueKeysWithValues: registry.projects.map { ($0.path, $0.name) }
                )
                let map = attribution.load().mappings
                var names: [String: String] = [:]
                for (sessionID, path) in map {
                    if let name = pathToName[path] {
                        names[sessionID] = name
                    }
                }
                return (names: names, projects: registry.projects)
            }.value

            // Single batched commit — assigning all four observables at once
            // means SwiftUI sees one update rather than four staggered ones.
            // Eliminates the brief "list flashes / project chips appear
            // late" reload artifact during session switches.
            recentSessions = fetchedSessions
            sessionPreviews = fetchedPreviews
            sessionProjectNames = bundle.names
            allProjects = bundle.projects

            // Record the sidebar size after each reload so we can correlate
            // list-length growth with reload latency in the ScarfMon trace.
            ScarfMon.event(.sessionLoad, "mac.recentSessions.count", count: recentSessions.count)
        }
    }

    /// Resolved project display name for a recent session, or nil for
    /// unattributed (global / quick) sessions.
    func projectName(for session: HermesSession) -> String? {
        sessionProjectNames[session.id]
    }

    /// Rename a session via `hermes sessions rename`. Updates local
    /// caches in-place on success so the chat sidebar reflects the new
    /// title without a full reload. Same shell command path the
    /// SessionsView feature uses.
    func renameSession(_ sessionId: String, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let result = context.runHermes(["sessions", "rename", sessionId, trimmed])
        guard result.exitCode == 0 else { return }
        if let idx = recentSessions.firstIndex(where: { $0.id == sessionId }) {
            recentSessions[idx] = recentSessions[idx].withTitle(trimmed)
        }
        sessionPreviews[sessionId] = trimmed
    }

    /// Delete a session via `hermes sessions delete --yes`. Removes the
    /// row from local caches on success and resets the live chat
    /// transcript when the deleted session was the active one (so the
    /// user isn't left looking at orphaned content).
    func deleteSession(_ sessionId: String) {
        let result = context.runHermes(["sessions", "delete", "--yes", sessionId])
        guard result.exitCode == 0 else { return }
        recentSessions.removeAll { $0.id == sessionId }
        sessionPreviews.removeValue(forKey: sessionId)
        sessionProjectNames.removeValue(forKey: sessionId)
        if richChatViewModel.sessionId == sessionId {
            richChatViewModel.reset()
            focusedToolCallId = nil
        }
    }

    func previewFor(_ session: HermesSession) -> String {
        if let title = session.title, !title.isEmpty { return title }
        if let preview = sessionPreviews[session.id], !preview.isEmpty { return preview }
        return session.id
    }

    // MARK: - Voice (terminal mode only)

    func toggleVoice() {
        guard let tv = terminalView else { return }
        if voiceEnabled {
            sendToTerminal(tv, text: "/voice off\r")
            voiceEnabled = false
            isRecording = false
        } else {
            sendToTerminal(tv, text: "/voice on\r")
            voiceEnabled = true
            ttsEnabled = fileService.loadConfig().autoTTS
        }
    }

    func toggleTTS() {
        guard let tv = terminalView, voiceEnabled else { return }
        sendToTerminal(tv, text: "/voice tts\r")
        ttsEnabled.toggle()
    }

    func pushToTalk() {
        guard let tv = terminalView, voiceEnabled else { return }
        let ctrlB: [UInt8] = [0x02]
        tv.send(source: tv, data: ctrlB[0..<1])
        isRecording.toggle()
    }

    // MARK: - Terminal Mode

    private func sendToTerminal(_ tv: LocalProcessTerminalView, text: String) {
        let bytes = Array(text.utf8)
        tv.send(source: tv, data: bytes[0..<bytes.count])
    }

    private func launchTerminal(arguments: [String]) {
        stopACP()

        if let existing = terminalView {
            existing.terminate()
            existing.removeFromSuperview()
        }

        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.85, green: 0.87, blue: 0.91, alpha: 1.0)

        let coord = Coordinator(onTerminated: { [weak self] in
            self?.hasActiveProcess = false
            self?.voiceEnabled = false
            self?.isRecording = false
            Task { await self?.richChatViewModel.refreshMessages() }
        })
        terminal.processDelegate = coord
        self.coordinator = coord

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        // Inherit ssh-agent socket for remote so password-less auth works.
        if context.isRemote {
            let shellEnv = HermesFileService.enrichedEnvironment()
            for key in ["SSH_AUTH_SOCK", "SSH_AGENT_PID"] {
                if env[key] == nil, let v = shellEnv[key], !v.isEmpty {
                    env[key] = v
                }
            }
        }
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // For remote: wrap the invocation in `ssh -t host -- hermes <args>`
        // so the embedded terminal opens a pty against the remote and the
        // hermes TUI gets the bytes it expects. `-t` requests a pty (the
        // SwiftTerm view is one).
        let exe: String
        let argv: [String]
        if context.isRemote, case .ssh(let cfg) = context.kind {
            let host = cfg.user.map { "\($0)@\(cfg.host)" } ?? cfg.host
            exe = "/usr/bin/ssh"
            var sshArgs: [String] = ["-t"]
            if let port = cfg.port { sshArgs += ["-p", String(port)] }
            if let id = cfg.identityFile, !id.isEmpty { sshArgs += ["-i", id] }
            sshArgs += ["-o", "StrictHostKeyChecking=accept-new"]
            sshArgs += ["-o", "BatchMode=yes"]
            sshArgs.append(host)
            sshArgs.append("--")
            sshArgs.append(context.paths.hermesBinary)
            sshArgs.append(contentsOf: arguments)
            argv = sshArgs
        } else {
            exe = context.paths.hermesBinary
            argv = arguments
        }

        terminal.startProcess(
            executable: exe,
            args: argv,
            environment: envArray,
            execName: nil
        )

        self.terminalView = terminal
        self.hasActiveProcess = true
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onTerminated: () -> Void

        init(onTerminated: @escaping () -> Void) {
            self.onTerminated = onTerminated
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let terminal = source.getTerminal()
            terminal.feed(text: "\r\n[Process exited with code \(exitCode ?? -1). Use the toolbar to start or resume a session.]\r\n")
            DispatchQueue.main.async { self.onTerminated() }
        }
    }
}
