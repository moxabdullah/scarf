# Scarf — macOS GUI for the Hermes AI Agent

## Project Structure

```
scarf/scarf/           Xcode project root (PBXFileSystemSynchronizedRootGroup — auto-discovers files)
  scarf/               Main app target source
    Core/Services/     HermesDataService, HermesFileService, HermesLogService, ACPClient, HermesFileWatcher
    Core/Models/       Plain structs: HermesSession, HermesMessage, HermesConfig, etc.
    Features/          MVVM-F feature modules (Dashboard, Sessions, Activity, Chat, Memory, Skills, Cron, Logs, Settings)
    Navigation/        AppCoordinator, SidebarView
  docs/                PRD, Architecture, Discovery notes
  standards/           Copied development standards (read-only reference)
```

## Architecture Rules

- **MVVM-F**: Features never import sibling features. Cross-feature goes through services.
- **AppCoordinator**: Single `@Observable` coordinator for all navigation state, injected via `.environment()`.
- **No external dependencies**: System SQLite3, Foundation JSON, AttributedString markdown.
- **Read-only DB access**: Never write to `~/.hermes/state.db`. Only write to memory files and cron jobs.
- **Sandbox disabled**: App reads `~/.hermes/` directly.
- **Swift 6 concurrency**: `@MainActor` default. Services use `nonisolated` + async/await.

## Design System (ScarfDesign)

All app UI uses the typed token bundle in [scarf/Packages/ScarfDesign/](scarf/Packages/ScarfDesign/) — both the `scarf` and `scarf mobile` targets `import ScarfDesign`. Reach for these tokens before inventing new colors, fonts, or spacings.

- **Colors**: `ScarfColor.accent`, `.foregroundPrimary/Muted/Faint`, `.backgroundPrimary/Secondary/Tertiary`, `.border/.borderStrong`, `.success/.danger/.warning/.info`, `.Tool.bash/edit/search/web/think`. All resolve from `ScarfBrand.xcassets` and adapt light/dark automatically.
- **Typography**: `.scarfStyle(.title2)`, `.scarfStyle(.body)`, `.scarfStyle(.captionUppercase)`, etc. Use these instead of `.font(.system(...))`. Eleven preset styles cover the type scale.
- **Spacing / radius / shadow**: `ScarfSpace.s1...s10` (4/8/12/16/20/24/32/40), `ScarfRadius.sm/md/lg/xl/xxl/pill`, `.scarfShadow(.sm/.md/.lg/.xl)`. Hardcoded `.padding(12)` or `cornerRadius: 8` is a code smell — convert.
- **Components**: `ScarfPageHeader("Title", subtitle: "...") { trailing }`, `ScarfCard { ... }`, `ScarfBadge("text", kind: .success)`, `ScarfTextField`, `ScarfSectionHeader`, `ScarfDivider`, `ScarfPrimaryButton/SecondaryButton/GhostButton/DestructiveButton` (apply with `.buttonStyle(...)`).
- **App icon + accent**: `Assets.xcassets/AppIcon.appiconset/` is the rust set; `Assets.xcassets/AccentColor.colorset` resolves `Color.accentColor` to rust so any unmigrated SwiftUI control still tints correctly.
- **Reference**: full screen mockups live at `design/static-site/ui-kit/*.jsx` (open `design/static-site/index.html` in a browser). The `ScarfChatView.ChatRootView` reference component in the package is a 3-pane chat redesign target — usable for previews but not yet swapped into the live chat (the existing `RichChatView` machinery still owns the real ACP pipeline).
- **Don't**: introduce purple/violet tones (we shifted to rust); use yellow `#F0AD4E` for success (that's `.warning` — `.success` is green); bypass the type scale with `.font(.system(size: 13.5))`; ship terminal/syntax-highlight palettes through ScarfColor (those are content semantics, keep them inline).

### iOS Dynamic Type policy

iOS users can scale text via Settings → Accessibility → Display & Text Size. ScarfFont uses fixed point sizes; adopting it blanket on iOS would regress accessibility on `.accessibility2` / `.xSmall` users. iOS-specific rule:

- **Use `ScarfFont` only for**: status badges, chip labels, intentional-display elements (e.g., onboarding step titles, header chrome that's meant to be a fixed visual size).
- **Keep `.font(.headline)` / `.body` / `.caption` semantic tokens for**: list-row primary + secondary text, body copy, error messages, chat content — anything the user reads.

Decision tree per text element: "is this read for content?" → semantic token. "Is this chrome / a label / a badge?" → ScarfFont.

Mac doesn't have this constraint and adopts ScarfFont everywhere. The iOS app already clamps Dynamic Type at the scene root (`ScarfIOSApp.swift`: `.dynamicTypeSize(.xSmall ... .accessibility2)`) — keep that.

### iOS page chrome

Don't retrofit `ScarfPageHeader` over iOS tab roots. iOS uses `.navigationTitle(...)` + `.navigationBarTitleDisplayMode(.large)` as its native page-header pattern; stacking ScarfPageHeader on top creates double titles. Use ScarfPageHeader only on iOS sub-views without a native large-title bar (rare).

iOS button styling: only swap `.borderedProminent` → `ScarfPrimaryButton`. **Leave `.bordered` native** — it's the iOS convention and inherits rust through `AccentColor.colorset` automatically. Same for `.plain` (used as compact tap targets in lists).

## Key Paths

- Hermes home: `~/.hermes/`
- SQLite DB: `~/.hermes/state.db` (WAL mode, read-only)
- Config: `~/.hermes/config.yaml`
- Memory: `~/.hermes/memories/MEMORY.md`, `~/.hermes/memories/USER.md`
- Sessions: `~/.hermes/sessions/session_*.json`
- Cron: `~/.hermes/cron/jobs.json`
- Logs: `~/.hermes/logs/errors.log`, `~/.hermes/logs/gateway.log`
- ACP: `hermes acp` subprocess (stdio JSON-RPC)

## Build

```bash
xcodebuild -project scarf/scarf.xcodeproj -scheme scarf -configuration Debug build
```

## Releases

Shipped via a single local script. **Never run manual `xcodebuild archive` / `notarytool` / `gh release create` steps — use the script so nothing is skipped or misordered.**

```bash
./scripts/release.sh <version>           # full release: notarize → appcast → gh-pages → tag
./scripts/release.sh <version> --draft   # draft: everything builds + notarizes, but appcast/tag are skipped
```

The script bumps version, archives Universal (arm64 + x86_64) + ARM64-only variants, signs with Developer ID, notarizes via `xcrun notarytool` (keychain profile `scarf-notary`), staples, EdDSA-signs the appcast entry with Sparkle's key, pushes the appcast to `gh-pages`, and creates a GitHub release with both zips attached. Draft mode stops after the release is uploaded so the current version stays "latest" until explicitly promoted.

**Release notes convention:** write them to `releases/v<version>/RELEASE_NOTES.md` BEFORE running the script — it's auto-included in the version-bump commit and used as the GitHub release body. If absent, a placeholder is used.

**Canonical prompts (any of these trigger the flow):**
- "Release v1.6.2" — full release
- "Release v1.6.2 as draft" — draft mode
- "Prepare v1.6.2 release notes from recent commits, then release" — generate notes first, then run

**Prerequisites (one-time, already set up on Alan's machine):** Developer ID Application cert in login Keychain (team `3Q6X2L86C4`), notarytool keychain profile `scarf-notary`, Sparkle EdDSA private key in Keychain item `https://sparkle-project.org`, `gh-pages` branch + GitHub Pages enabled. See the header of [scripts/release.sh](scripts/release.sh) and the Releases section in [README.md](README.md) for details.

## Wiki

Public documentation lives in the GitHub wiki at https://github.com/awizemann/scarf/wiki. The wiki is a separate git repo cloned to `.wiki-worktree/` in the repo root (gitignored, sibling to `.gh-pages-worktree/`). Internal dev notes stay in `scarf/docs/`; the wiki is for public-facing reference.

**Update the wiki when:**
- A new feature module is added under `scarf/scarf/scarf/Features/` → extend the relevant User Guide page.
- A new core service is added under `Core/Services/` → extend `Core-Services.md`.
- Architecture changes (AppCoordinator, transport, MVVM-F rule, sandbox) → `Architecture-Overview.md` + the specific sub-page.
- Hermes version bumps in this file → `Hermes-Version-Compatibility.md`.
- `scripts/release.sh` completes a full (non-draft) release → bump latest-version on `Home.md` + append to `Release-Notes-Index.md`.
- Keyboard shortcut or sidebar section changes → `Keyboard-Shortcuts.md` / `Sidebar-and-Navigation.md`.

**Skip for:** bug fixes with no user-observable change, pure refactors, typos, test-only changes, internal cleanups.

```bash
./scripts/wiki.sh pull                         # always first
# edit .wiki-worktree/*.md with normal tools
./scripts/wiki.sh commit "docs: describe X"   # runs secret-scan
./scripts/wiki.sh push                         # runs secret-scan again, then push
```

**Never** commit API keys, tokens, `.env` files, private keys, or real hostnames/IPs to the wiki. The script's two-pass secret-scan blocks common token patterns and a user-maintained blocklist at `scripts/wiki-blocklist.txt` (gitignored). Do not bypass without explicit approval. Full workflow on the wiki itself at `.wiki-worktree/Wiki-Maintenance.md`.

## Hermes Version

Targets Hermes v2026.5.16 (v0.14.0). Log lines may carry an optional `[session_id]` tag between the level and logger name — `HermesLogService.parseLine` treats the session tag as an optional capture group, so older untagged lines still parse.

**Capability gating.** Scarf detects the target's Hermes version once per server connection via [HermesCapabilities](scarf/Packages/ScarfCore/Sources/ScarfCore/Services/HermesCapabilities.swift) (`hermes --version` → semver + `YYYY.M.D` parse). The resulting `HermesCapabilitiesStore` is injected on `ContextBoundRoot` (Mac) and `ScarfGoTabRoot` (iOS) via `.environment(_:)` and `.hermesCapabilities(_:)`; UI that depends on a release-gated surface reads it through the typed environment key. Pre-target hosts gracefully hide the new affordances rather than throwing on unknown CLI subcommands. Add a new flag at the top of `HermesCapabilities` whenever Scarf gains a release-gated UI surface — group flags by the Hermes release that introduced them (`MARK: v0.14 (v2026.5.16) flags`, etc.).

**v2026.5.16 (v0.14.0)** added (Scarf-relevant subset; v2.9.0 implementation lands across WS-1 through WS-12):

- **`/subgoal` slash command** — extra success criteria layered onto an active `/goal` loop. Forms: `<text>`, `remove N`, `clear`. Joins `/goal`, `/queue`, `/steer` in `RichChatViewModel.nonInterruptiveCommands`. Optimistic mirror on `activeSubgoals: [String]`; SessionInfoBar renders a "+N" badge inside the goal pill with the full list in the tooltip. Gated on `hasSubgoal`.
- **New chat config slash commands** — `/yolo` (toggle dangerous-command approvals), `/sessions` (browse + resume), `/codex-runtime` (toggle Codex app-server runtime for OpenAI/Codex models). All append to `alwaysAvailableCommands` when their capability flag is on (`hasYOLOSlashCommand`, `hasSessionsSlashCommand`, `hasCodexRuntimeSlashCommand`).
- **`/handoff` is NOT a model handoff** — verified against Hermes's command catalog: `/handoff <platform>` is `cli_only=True` and hands a session to a *messaging platform* (Telegram, Discord, etc.), not to a different model. Scarf intentionally does **not** add it to the ACP slash menu. Mid-chat model switching continues to use the existing `session/set_model` RPC path under `hasACPSetSessionModel` (v0.13).
- **xAI Grok OAuth (SuperGrok)** — subscription-gated overlay provider. Wire ID `xai-oauth` (canonical; `x-ai-oauth` / `grok-oauth` / `xai-grok-oauth` are accepted aliases server-side). Base URL `https://api.x.ai/v1`, `oauthExternal` auth. Gated on `hasGrokOAuthProvider`.
- **NovitaAI** — API-key overlay provider. Wire ID `novita` (canonical; `novita-ai` / `novitaai` are aliases). Gated on `hasNovitaProvider`.
- **Alibaba Cloud → Qwen Cloud rename** — display-only. Hermes's `ProviderEntry("alibaba", "Qwen Cloud", …)` in `hermes_cli/models.py` flipped the picker label; the wire ID stayed `alibaba`. Scarf mirrors via a new unconditional `providerDisplayNameOverrides` map in ModelCatalogService — applied in `loadProviders()` and `loadModels(for:)`. No alias entry is needed (existing `alibaba-cloud` / `qwen` aliases still resolve server-side). Gated cosmetically on `hasQwenCloudDisplayName`, but the override fires unconditionally (matches what users will read about in the world).
- **LINE Messaging API** + **SimpleX Chat** — 21st + 22nd gateway platforms. Wire IDs `line` and `simplex` (per `plugins/platforms/{line,simplex}/adapter.py`). Auto-appear in PlatformsView since it's data-driven. Gated on `hasLINEPlatform` / `hasSimpleXPlatform`.
- **Brave Search (free tier)** + **DuckDuckGo (DDGS)** web-search backends. Wire IDs `brave-free` and `ddgs`. Replaces stale v0.13-era `"duckduckgo"` / `"brave"` / `"you"` entries that never matched Hermes's actual wire IDs. Canonical v0.13 search set is `exa, parallel, firecrawl, tavily, searxng`; v0.14 appends `brave-free, ddgs`. Brave Search honors `BRAVE_SEARCH_API_KEY` for higher quotas; DDGS uses the `ddgs` Python package (lazy-installed). Gated on `hasBraveFreeSearchBackend` / `hasDDGSearchBackend`.
- **MCP `supports_parallel_tool_calls`** — optional bool field on MCP server entries. Tri-state picker in MCPServerEditorView ("Default (Hermes decides)" → nil, drops key; "Enabled"/"Disabled" → explicit bool). YAML reader in `HermesFileService.parseMCPServersBlock` parses `true`/`false`; writer is `setMCPServerParallelToolCalls(name:enabled:)`. Gated on `hasMCPParallelToolCalls`.
- **`terminal.docker_extra_args`** — extra flags forwarded verbatim to `docker run`. List of strings; default empty. Comma-separated input on the TerminalTab Docker section; setter serializes to a YAML list. Gated on `hasDockerExtraArgs`.
- **`display.timestamps`** — per-message timestamps toggle for the TUI. ACP-relayed chat in Scarf already shows turn-duration chips, so this only affects the CLI. Surfaced in Settings → Display → Output. Gated on `hasDisplayTimestamps`. Also fixed a pre-existing v0.13 oversight: the YAML parser wasn't reading `display.language` back at load time (the field was in DisplaySettings with a default but the parser never populated it).
- **Cron `deliver=all`** — fan-out routing intent. Deliver field is free-form text so the user can type `all` on any host; v0.14 just updates the placeholder + adds a helper line clarifying the new value. Gated on `hasCronDeliverAll`.
- **Discord channel-history backfill** — when joining a thread, Hermes reads recent history so the agent knows what was said. Default-on in v0.14. Surfaced as a toggle in `DiscordSetupView`'s Behavior section; written to `discord.history_backfill`. Gated on `hasDiscordHistoryBackfill`.
- **Plugin `tool_override` badge** — plugins can advertise `tool_override: true` in their manifest (plugin.json or plugin.yaml). PluginsView renders a "tool-override" ScarfBadge next to such plugins. Gated on `hasPluginToolOverride`; the manifest read accepts both `tool_override` (snake_case) and `toolOverride` (camelCase).
- **Hermes Proxy** — new Configure → Hermes Proxy sidebar destination (`.proxy` SidebarSection case). Wraps `hermes proxy start --provider <p> --host 127.0.0.1 --port 8645` via [HermesProxyService](scarf/scarf/Core/Services/HermesProxyService.swift), a `@MainActor @Observable` service that owns the long-running child Process. Reads stderr into a capped (200-line) log buffer; `listAvailableProviders()` probes `hermes proxy providers`. Local server only in v1 (SSH would need port-forward wiring); the view shows an explanatory notice on non-local contexts. Hermes v0.14 ships with `nous` as the only adapter; the picker auto-refreshes when more land. Gated on `hasHermesProxy`.
- **ACP `--setup-browser`** — `hermes acp --setup-browser --assume-yes` runs the chromium + playwright provisioning verb. Surfaced as a "Set up browser tools" button on the HealthView header. Inline status strip shows progress + tail-of-output on failure (no alert sheet). 10-minute timeout since chromium download is slow. Gated on `hasACPSetupBrowser`.
- **YOLO mode warning** — `approvals.mode = yolo` opts out of dangerous-command approvals. SessionInfoBar adds a `ScarfBadge` warning chip next to the session title when (a) the mode is yolo AND (b) the host advertises `hasYOLOWarning`. Wired through `ChatViewModel.approvalMode`, populated by `refreshConfigDiagnostics` off MainActor.
- **Per-turn file-mutation verifier footer** — Hermes v0.14 appends a verifier block to assistant turns that wrote files (configurable via `file_mutation_verifier: True`). The footer flows through Scarf chat as plain agent output today; bespoke card-style rendering is deferred until the upstream format stabilizes (no explicit Scarf code change in v2.9.0, but `hasFileMutationVerifier` is reserved for the follow-up).
- **Cross-session 1h Claude prefix cache** — server-side; Scarf gets the benefit automatically. `hasCrossSessionClaudeCache` is reserved for any future informational hint in Settings → Prompt Caching.
- **Server-side automatic gains** — native Windows beta, PyPI install (`pip install hermes-agent`), ~19s cold-start reduction, 180x faster `browser_console` evaluations, supply-chain advisory checker. None require Scarf surface changes — Scarf benefits transparently when the user upgrades Hermes.
- **Schema is unchanged from v0.11/v0.12/v0.13** — same state.db columns. No migration needed.

**v2026.5.7 (v0.13.0)** added (Scarf-relevant subset; full v2.8.0 implementation lands across WS-2 through WS-9):

- **Persistent Goals** — `/goal <text>` slash command locks the agent onto a target across turns. Checkpoints v2 single-store rewrite + auto-resume after gateway restart. Surfaced in Scarf chat as a non-interruptive command + a "🎯 Goal locked: <text>" pill in the chat header. Gated on `HermesCapabilities.hasGoals`.
- **ACP `/queue` slash command** — queues a prompt to run after the current turn completes. Joins `/steer` in `RichChatViewModel.nonInterruptiveCommands` with a transient "Queued" toast. Gated on `hasACPQueue`. `/steer` now also runs as a regular prompt on idle sessions (`hasACPSteerOnIdle`).
- **Kanban v0.13 reliability + recovery UX** — hallucination gate on worker-created cards, generic diagnostics engine (per-task distress signals), per-task `max_retries` override, multiline title/body create, `auto_blocked_reason` rendered in the inspector banner, darwin zombie detection, unify failure counter across spawn/timeout/crash. New fields decode through tolerant `HermesKanbanRun` / `HermesKanbanTaskDetail` extensions; pre-v0.13 hosts ignore unknown keys. Gated on `hasKanbanDiagnostics`.
- **Curator archive + prune** — `hermes curator archive <skill>` + `prune` + `list-archived` subcommands. The synchronous manual `hermes curator run` blocks until done (pre-v0.13 returned immediately). Surfaced as an "Archived" tab in CuratorView with per-row Restore + Prune actions and a destructive prune-confirm sheet. Gated on `hasCuratorArchive`.
- **Messaging Gateway expansion** — Google Chat (20th platform; `hasGoogleChatPlatform`), cross-platform allowlists (`allowed_channels` / `allowed_chats` / `allowed_rooms` per platform; `hasGatewayAllowlists`), per-platform `gateway_restart_notification` (`hasGatewayRestartNotification`), `busy_ack_enabled` toggle (`hasGatewayBusyAckToggle`), slash-command auto-delete TTL, `[[as_document]]` skill media routing directive, `hermes gateway list` cross-profile status verb (`hasGatewayList`).
- **Provider catalog refresh** — new models on Nous Portal + OpenRouter: `deepseek/deepseek-v4-pro`, `x-ai/grok-4.3`, `openrouter/owl-alpha` (free), `tencent/hy3-preview`, `arcee/trinity-large-thinking` (with temperature + compression overrides). `x-ai/grok-4.20-beta` renamed to `x-ai/grok-4.20` — keep alias map. Vercel AI Gateway demoted to bottom of the picker. `image_gen.model` from `config.yaml` now honored by Hermes (was advertised but ignored pre-v0.13); surfaced in `Settings → Auxiliary` (`hasImageGenModel`). OpenRouter response caching toggle (`hasOpenRouterResponseCache`).
- **MCP SSE transport** — MCP servers can be configured with SSE transport + `sse_read_timeout`. Surfaced in MCPServersView add-server flow alongside stdio/pipe. Gated on `hasMCPSSETransport`.
- **Cron `--no-agent` mode** — script-only watchdog jobs that skip the AI call. Surfaced in CronView edit sheet. Gated on `hasCronNoAgent`.
- **Web Tools per-capability backends** — `web_search` and `web_extract` can use distinct backends; SearXNG joined as a search-only backend. Surfaced in the Web Tools settings tab. Gated on `hasWebToolsBackendSplit`.
- **Profiles `--no-skills`** — `hermes profile create --no-skills` for empty-profile creation. Surfaced as a toggle in the create-profile flow. Gated on `hasProfileNoSkills`.
- **CLI / UX additions** — context compression count in the status feed (rendered next to the token count in chat status bar; `hasContextCompressionCount`), `/new <name>` slash-command argument (`hasNewWithSessionName`), `hermes update --yes` non-interactive (`hasUpdateNonInteractive`), `display.language` static-message translation (zh / ja / de / es / fr / uk / tr; `hasDisplayLanguage`), xAI Custom Voices (voice-cloning badge next to xAI TTS provider; `hasXAIVoiceCloning`).
- **Server-side defaults flipped** — secret redaction defaults back to ON in v0.13 (was off by default in v0.12). The Settings redaction toggle remains for opt-out; the default-state hint reflects the v0.13 semantics when the host advertises v0.13+.
- **`video_analyze` tool** — native video understanding on Gemini-class models. Hermes handles transparently inside the agent loop; Scarf has no UI surface yet but `hasVideoAnalyze` is reserved for future widget gating.
- **`transform_llm_output` plugin hook** — plugin-author concern; surfaced indirectly through PluginsView when a plugin advertises the hook. `hasTransformLLMOutputHook` gates the metadata badge.
- **Schema is unchanged from v0.11/v0.12** — same state.db columns. No migration needed.

**v2026.4.30 (v0.12.0)** added (Scarf-relevant subset):

**v2026.4.30 (v0.12.0)** added (Scarf-relevant subset):

- **Autonomous Curator** — `hermes curator` self-prunes / -consolidates the skill library on a 7-day cycle. Reports land at `~/.hermes/logs/curator/run.json` + `REPORT.md`; paths exposed via `HermesPathSet.curatorLogsDir` (`logs/curator`) + `curatorStateFile` (`skills/.curator_state`), with the per-cycle `run.json` / `REPORT.md` resolved at runtime from the `last_report_path` field on the state file. Surfaced in Scarf as a dedicated "Curator" sidebar item under Interact (between Memory and Skills) on Mac, plus a read-mostly iOS panel with Run Now / Pause / Resume actions and inline pin toggles; both gated on `HermesCapabilities.hasCurator`.
- **5 new inference providers** — GMI Cloud, Azure AI Foundry, LM Studio (upgraded to first-class), MiniMax OAuth, Tencent Tokenhub. Mirrored in `ModelCatalogService.overlayOnlyProviders`; the model picker reaches all of them automatically.
- **`flush_memories` aux task removed (server side)** — `auxiliary.flush_memories` is gone from v0.12 Hermes config but remains alive on pre-v0.12 hosts. Scarf preserves `AuxiliarySettings.flushMemories: AuxiliaryModel`, the YAML reader still emits an `aux("flush_memories")` row, and `AuxiliaryTab` only renders the row when `HermesCapabilities.hasFlushMemoriesAux` is `true` (inverse semantics — pre-v0.12 only). v0.12 users never see the row; v0.11 users keep their edit surface.
- **`auxiliary.curator` aux task added** — Curator's review model is configurable independently of the main model. Surfaced in `Settings → Auxiliary` next to the other aux rows.
- **Multimodal ACP `session/prompt`** — ACP advertises and forwards image content blocks. Scarf chat composers (Mac drag/drop + paste; iOS PhotosPicker) attach images that flow through `ACPClient.sendPrompt(sessionId:text:images:)` as `[{"type":"text","text":...}, {"type":"image","data":"<base64>","mimeType":"image/jpeg"}]` — wire shape matches `acp.schema.ImageContentBlock`. `ImageEncoder` downsamples to 1568px long-edge JPEG q=0.85 detached (never blocks MainActor). Gated on `HermesCapabilities.hasACPImagePrompts`.
- **CLI additions:** `hermes -z <prompt>` (non-interactive one-shot), `hermes update --check` (preflight), `hermes fallback` (manage fallback providers), `hermes curator` (status / run / pause / resume / pin / unpin / restore), `hermes kanban` (full 27-verb task-board CLI). All capability-gated. **v2.7.5 lifts Kanban from a read-only list to a full drag-and-drop board.** See the dedicated [Kanban v3](#kanban-v3-drag-and-drop-board--per-project-tenants-v275) section below for the complete architecture.
- **Skills surface:** `hermes skills install <https-url>` direct-URL install (SkillsView "Install from URL…" toolbar button), reload via `hermes skills audit` (Skills "Reload" button — equivalent to the `/reload-skills` slash command for non-ACP contexts), enabled/disabled state read from `skills.disabled` in config.yaml (rendered as strikethrough + "OFF" pill), Curator pin badge from `~/.hermes/skills/.curator_state` (rendered as a pin glyph). The disable-toggle write path is deferred to v2.7 — Hermes only exposes `hermes skills config` as an interactive verb, and Scarf prefers reading accurately to risking a clobbered list.
- **Two new gateway platforms:** Microsoft Teams (19th, plugin-shipped) + Tencent 元宝 / Yuanbao (18th, native). Surfaced in the Mac Platforms tab.
- **Cron upgrades:** per-job `--workdir <abs-path>` (project-aware cwd that pulls AGENTS.md / CLAUDE.md / .cursorrules) is exposed in the editor sheet, gated on `HermesCapabilities.hasCronWorkdir` so pre-v0.12 hosts don't see the field (and a defensive override in `CronView` strips the value before calling `createJob`/`updateJob` even if it was hydrated from a pre-existing job). Pass an empty string on edit to clear an existing workdir, mirroring the `--script` shape. Hermes also added a `context_from` field for chaining cron outputs but only via YAML so far — Scarf reads it (HermesCronJob.contextFrom) but doesn't write it.
- **Settings deltas:** `prompt_caching.cache_ttl` (5m/1h picker), `redaction.enabled` toggle (off-by-default in v0.12 — toggle restores it), `agent.runtime_metadata_footer` toggle, Piper added to TTS provider list, `vercel` added to terminal backend list.
- **Bundled plugins:** Spotify, Google Meet, Langfuse observability, hermes-achievements (visible in Plugins tab).
- **iOS catch-up (Phase H):** read-only Webhooks / Plugins / Profiles tabs (`Scarf iOS/Webhooks/WebhooksView.swift`, `Plugins/PluginsView.swift`, `Profiles/ProfilesView.swift`) parity-match the Mac surfaces but skip mutating CLI verbs. `Scarf iOS/Components/HermesVersionBanner.swift` nudges pre-v0.12 hosts to upgrade (renders only when the connected target is below v0.12).
- **`hermes memory` providers:** honcho, openviking, mem0, hindsight, holographic, retaindb, byterover. `Settings → Memory` lists all providers in the picker; the existing "Run `hermes memory setup` in Terminal" hint stays — `hermes memory setup` is interactive (asks for tokens) so an in-app shellout would surface a frozen UI.
- **Schema is unchanged from v0.11** — same state.db columns (`messages.reasoning_content`, `sessions.api_call_count` introduced in v0.11 remain). No migration needed.

**v2026.4.23 (v0.11.0)** added (historical context, still consumed by Scarf when running against a pre-v0.12 host):

- `/steer <prompt>` — non-interruptive mid-run guidance slash command. Surfaced in Scarf chat menus via `RichChatViewModel.nonInterruptiveCommands`; `ChatViewModel.sendViaACP` (Mac) and `ChatController.send` (iOS) skip the "Agent working…" status flip and show a transient toast instead.
- New CLI subcommands: `hermes plugins` / `profile` / `webhook` / `insights` / `logs` / `memory reset` / `completion` / `dashboard`. Scarf v2.5 adopts **`hermes memory reset`** (toolbar button on MemoryView with destructive confirmation). The other CLIs are documented here for v2.6 — Scarf still reads `~/.hermes/plugins/`, `~/.hermes/profiles/` etc directly today; switching those paths to the canonical CLI is a forward-compatible change to make when bandwidth permits.
- New state.db columns: `messages.reasoning_content` + `sessions.api_call_count`. `HermesDataService.detectSchema` flips `hasV011Schema` only when both are present (partial migrations stay on v0.7 path). Surfaced as the "API" chip on session rows + a network-icon counter in DashboardView. `HermesMessage.preferredReasoning` picks the newer column when both reasoning channels are populated.
- New skills: `design-md` (Google's DESIGN.md authoring; needs `npx`/Node 18+ on host — checked via `SkillPrereqService` and surfaced as a yellow banner) and `spotify` (OAuth via `hermes auth spotify` — driven by `SpotifyAuthFlow` + `SpotifySignInSheet`, mirroring v2.3 Nous Portal pattern).
- Updated skills: `research-paper-writing` 1.1.0 (+SciencePlots dep), `segment-anything-model` (expanded docs), `google-workspace` (gws CLI prefer + granular OAuth scopes), `hermes-agent` (in-tree).
- SKILL.md frontmatter gains `allowed_tools` / `related_skills` / `dependencies` lists. `HermesSkill` carries them as optional fields; `SkillsView` (Mac) + `SkillDetailView` (iOS) render them as chip rows when populated.

v0.10.0 introduced the **Tool Gateway** — paid Nous Portal subscribers route web search, image generation, TTS, and browser automation through their subscription without separate API keys. In Scarf:

- **Provider picker** ([ModelCatalogService.swift](scarf/scarf/Core/Services/ModelCatalogService.swift)) merges Hermes's `HERMES_OVERLAYS` so Nous Portal and other overlay-only providers (OpenAI Codex, Qwen OAuth, Google Gemini CLI, GitHub Copilot ACP, Arcee) appear alongside the models.dev catalog. Subscription-gated providers sort first and render a "Subscription" pill.
- **Subscription detection** ([NousSubscriptionService.swift](scarf/scarf/Core/Services/NousSubscriptionService.swift)) reads `~/.hermes/auth.json` → `providers.nous`. Read-only; Hermes owns the write path.
- **Per-task routing** (Auxiliary tab) toggles `auxiliary.<task>.provider` between `nous` and `auto`. Hermes derives gateway routing from provider selection — there is no separate `use_gateway` key.
- **Health surface** ([HealthViewModel.swift](scarf/scarf/Features/Health/ViewModels/HealthViewModel.swift)) adds a synthetic "Tool Gateway" section showing subscription state + `platform_toolsets` mappings + which aux tasks are routed through Nous.
- **Scarf's existing `Gateway` feature is renamed to "Messaging Gateway"** everywhere user-facing to disambiguate from the new Tool Gateway. The `SidebarSection.gateway` enum case and `gateway_state.json` / `gateway.log` paths are unchanged (not user-facing strings).

**Keep `ModelCatalogService.overlayOnlyProviders` in sync** with `HERMES_OVERLAYS` in `~/.hermes/hermes-agent/hermes_cli/providers.py`. When Hermes adds a new overlay-only provider, mirror the entry (display name, base URL, auth type, subscription-gated flag, doc URL) or the picker won't reach it.

**Keep `ModelCatalogService.modelAliases` in sync** with Hermes's deprecated-model-ID map (currently release-notes-only upstream; the canonical successor lives in `hermes_cli/providers.py` if/when upstream tracks it in code). Drift here means a user's old model ID stops resolving in the picker even though Hermes still accepts it at runtime.

**Keep `ModelCatalogService.demotedProviders` in sync** with the deprioritized-provider list in `hermes-agent/hermes_cli/providers.py`. Drift means Vercel AI Gateway (or any future demoted provider) sorts in the wrong position in Scarf's picker.

## Model Presets

Lightweight Scarf-owned overlay that lets users save named model+provider presets and bind one to a project (or switch live mid-chat). Sits alongside the global `config.yaml` default — projects without a binding inherit unchanged.

**Data model.** A `ModelPreset` is `{id: UUID, name, modelID, providerID, notes?, createdAt, updatedAt}` ([scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ModelPreset.swift](scarf/Packages/ScarfCore/Sources/ScarfCore/Models/ModelPreset.swift)). Records live in `~/.hermes/scarf/model_presets.json` under a versioned `ModelPresetStore` envelope — mirrors `SessionProjectMap`'s file shape. New `HermesPathSet.modelPresetsJSON` keeps the path centralized.

**Service.** [ModelPresetService](scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ModelPresetService.swift) is a Sendable `actor` in ScarfCore — pure file I/O (`list/get/upsert/delete`). Missing file → empty list (not an error); corrupt JSON throws `ModelPresetServiceError.corruptStore` so the UI can show a real diagnostic. Every method dispatches through `Task.detached(priority: .utility)` so MainActor stays off the read path.

**Per-project binding.** `ProjectTemplateManifest` gains an optional `modelPresetID: String?` field (UUID-as-string) at `<project>/.scarf/manifest.json`. Bound by **id**, not name — renames don't break bindings. The Mac-side writer is [ProjectModelPresetBinding](scarf/scarf/Core/Services/ProjectModelPresetBinding.swift), which mirrors `KanbanTenantResolver.persist` exactly (bare-project sentinel manifest creation, idempotent rebinds skip writes). The cross-platform read-only counterpart is [ProjectModelPresetReader](scarf/Packages/ScarfCore/Sources/ScarfCore/Services/ProjectModelPresetReader.swift) — iOS uses this projection without linking the full manifest model.

**Application — primary surface is the ACP `session/set_model` RPC, not env vars.** Pre-coding verification showed `HERMES_INFERENCE_MODEL` is only read by `oneshot.py` for `-z` mode; ACP's `_make_agent` in `acp_adapter/session.py` reads model from kwargs → falls back to `config.yaml`'s `model.default` without consulting env. The env-var path would have silently no-op'd. Instead, immediately after `client.newSession(cwd:)` returns a sessionId in `ChatViewModel.startACPSession`, the new helper `applyProjectModelPreset(client:sessionId:projectPath:)` resolves the project binding → looks up the preset → calls `ACPClient.setSessionModel(sessionId:modelID:)` (which wraps the `session/set_model` JSON-RPC method, payload `{sessionId, modelId}`) BEFORE unlocking the prompt. From the user's perspective the chat boots on the chosen model. Provider is re-derived server-side by `_resolve_model_selection`. All non-fatal: missing preset, RPC error, pre-v0.13 host → silent fallback to `config.yaml` default with a logger.info trail.

**Mid-chat switcher.** `ChatModelBadge` in the chat header (rendered by `SessionInfoBar`) shows the active preset name or "Default". Tap opens a popover listing every preset + "Use global default" — tapping a row fires `ChatViewModel.switchModelPreset(_:)` which calls `setSessionModel` against the live session. Optimistic UI: badge flips immediately, reverts on RPC failure with an inline banner. "Use global default" mid-chat resolves the config.yaml model name and sends that (Hermes has no "clear override" verb on `session/set_model`).

**Capability gating.** Single new flag `HermesCapabilities.hasACPSetSessionModel` (>= v0.13.0 — verified against `acp/schema.py: SetSessionModelRequest`). Pre-v0.13 hosts hide:
- The `.models` Models sidebar entry in the Configure section
- The "Set Model…" context-menu item in `ProjectsSidebar`
- The `ChatModelBadge` in `SessionInfoBar`
- The "Model: …" line on iOS `ProjectDetailView`

Existing global-model behaviour stays unchanged when no binding is set, so v0.12 users on Scarf are unaffected.

**CRUD UI (Mac).** [ModelPresetsView](scarf/scarf/Features/Models/Views/ModelPresetsView.swift) is the sidebar destination — list with per-row usage count (count of projects binding each preset), edit / delete actions, "in use" warning in the destructive confirm dialog. [ModelPresetEditSheet](scarf/scarf/Features/Models/Views/ModelPresetEditSheet.swift) reuses the existing `ModelPickerRow` (Settings → General's catalog-backed picker) for the model + provider field, so any provider mirrored in `ModelCatalogService` is bindable as a preset. [ModelPresetsViewModel](scarf/scarf/Features/Models/ViewModels/ModelPresetsViewModel.swift) snapshots presets + usage counts; counting walks `ProjectDashboardService.loadRegistry()` once per refresh — `O(projects)`, fine for typical counts.

**Per-project picker (Mac).** [ProjectModelPresetSheet](scarf/scarf/Features/Models/Views/ProjectModelPresetSheet.swift) presents from the project list's context-menu "Set Model…" action (added to `ProjectsSidebar` as a new `onSetModel` callback, capability-gated by `ProjectsView`). Reads the current binding from manifest, lets user pick "Use global default" or any saved preset, writes back via `ProjectModelPresetBinding`.

**iOS surface.** Read-only — [ProjectDetailView](Scarf%20iOS/Projects/ProjectDetailView.swift) shows a compact "Model: <preset name>" line above the tab picker when a binding exists. iOS doesn't get preset CRUD or per-project re-binding in v1 (Mac-only); the resolved name is fetched via `ProjectModelPresetReader` + `ModelPresetService.get(id:)` off MainActor.

**Cron per-job override — deferred.** `hermes cron create` / `hermes cron edit` don't accept `--model` flags (verified against v0.13.0 CLI). The top-level `hermes -m` only applies to `-z`/`--tui`, not to cron. The `HermesCronJob.model: String?` data field exists but the CLI write path doesn't. Surfacing a per-cron picker would require a Hermes-side flag addition; revisit when that lands.

**Don't:** invent a new env-var injection in `ACPClient+Mac.swift` — Hermes's ACP session-create path doesn't consult `HERMES_INFERENCE_MODEL`, so it'd silently no-op. Don't pass `-m` to `hermes acp` as a subcommand flag — it's a top-level flag and ACP doesn't accept it (verified via `hermes acp --help`). Don't bind by preset name — renames break references. Don't try to "clear" a session model via the RPC; resolve the config.yaml default and pass that instead.

## Kanban v3: drag-and-drop board + per-project tenants (v2.7.5)

Scarf v2.7.5 promotes Kanban from a read-only list to a full board with drag-and-drop, every Hermes write verb wired up, and per-project boards bound to a Scarf-minted tenant slug. The list view is preserved as a `Board | List` toggle for accessibility / narrow-window fallback.

**Sidebar move.** `.kanban` moved from *Manage* → *Monitor* in `SidebarView` (between `.activity` and the remaining Monitor entries). Kanban is runtime work-in-progress, not configuration. Position kept inside the same enum case — only the section bucket changed.

**Hermes constraints that drive design.**

1. **No `update` verb.** `priority`, `title`, `body`, `tenant` are write-once at `kanban create`. Mutations after create are state transitions (`assign` / `claim` / `complete` / `block` / `unblock` / `archive`) or new comments. Inline-edit on a card title is impossible at the wire level.
2. **No `project_id` column.** Hermes Kanban is one global SQLite DB at `~/.hermes/kanban.db`. Closest namespace is the optional `tenant TEXT` column. Scarf hijacks it: each project gets a `scarf:<slug>` tenant minted on first kanban interaction.
3. **No within-column position field.** Drag-to-reorder inside a column has no Hermes persistence path and is **disabled** in v2.7.5. Sort key is `priority DESC, created_at DESC` — matches dispatcher's actual run order. Cross-column drag is the only persisted gesture.
4. **No file-watch / webhooks.** Polling at 5s while foregrounded; live `watch` streaming deferred to a later release (a `hasKanbanWatch` flag will gate it).
5. **Status enum has 7 values, board collapses to 5 columns:** Triage / **Up Next** (`todo` + `ready`) / Running / Blocked / Done. Triage hides when empty; Archived hides behind a toolbar toggle.

**Service layer.** [KanbanService](scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanService.swift) is a Sendable `actor` in ScarfCore — pure I/O, no UI state. Wraps every v0.12 verb (`list / show / runs / stats / assignees / create / assign / claim / comment / complete / block / unblock / archive / dispatch / link / unlink`). Every method dispatches its CLI invocation through `Task.detached(priority: .utility)`, matching the existing `KanbanViewModel.load` pattern (re: Swift 6 rules in `~/.claude/CLAUDE.md`). Errors land in [KanbanError](scarf/Packages/ScarfCore/Sources/ScarfCore/Models/KanbanError.swift) and surface as inline banners (not modal alerts) since the board is high-frequency. The "no matching tasks" stdout sentinel is normalized to `[]`.

**Drag-drop transition planner.** `KanbanService.plan(for: KanbanTransition)` is a pure function that maps `(from, to)` columns to the right verb sequence — `(.upNext, .running) → [.claim]`, `(.blocked, .running) → [.unblock, .claim]`, etc. Disallowed transitions throw `KanbanError.forbiddenTransition` with a user-facing reason: drop on Done from anywhere triggers "Done is terminal — create a follow-up task to continue work."; drop on Triage from outside triggers "Triage tasks are promoted by a specifier agent." The view's drop handler short-circuits forbidden transitions with red-stroke target feedback.

**Per-project tenant.** [KanbanTenantResolver](scarf/scarf/Core/Services/KanbanTenantResolver.swift) (Mac) mints `scarf:<slug>` on first kanban interaction inside a project, persisting to `<project>/.scarf/manifest.json`'s new optional `kanbanTenant: String?` field. Tenants are **immutable across rename** (existing tasks already carry the old slug). Bare projects (no manifest) get a sentinel manifest written with `id: scarf/<project-id>` + `version: 0.0.0` + just the `kanbanTenant` set; `ProjectAgentContextService` recognizes the sentinel and refuses to surface it as a "Template" line. The cross-platform read-only counterpart is [KanbanTenantReader](scarf/Packages/ScarfCore/Sources/ScarfCore/Services/KanbanTenantReader.swift) in ScarfCore — iOS uses it to filter the per-project board without linking the full manifest model.

**Agent-side tenant injection.** `ProjectAgentContextService.renderBlock` adds a "Kanban tenant" line to the AGENTS.md scarf-managed block whenever a tenant exists. Since `ChatViewModel.startACPSession` calls `refresh(for:)` before opening every project chat, the agent sees the tenant on every session start and is told to pass `--tenant scarf:<slug>` on `hermes kanban create`. Agents are imperfect at flag discipline; misuse just sends the task to the global "Untagged" group on the global board, which is acceptable v2.7.5 behavior. A dedicated retag UX is a follow-up.

**View model.** [KanbanBoardViewModel](scarf/scarf/Features/Kanban/ViewModels/KanbanBoardViewModel.swift) is `@MainActor + @Observable`, holds the column-grouped task array, and applies optimistic-merge logic around drag-drops: an in-flight move records `optimisticOverrides[taskId] = newStatus`, mutates the local array immediately, and clears the override only when the polled response confirms the new status. Without this, a stale poll response can clobber a card the user just dragged. On CLI failure the override is removed and an error message lands in the inline banner.

**Mac surface.** [KanbanBoardView](scarf/scarf/Features/Kanban/Views/KanbanBoardView.swift) is the orchestrator (header + columns + side-pane inspector + create/block/complete sheets). [KanbanColumnView](scarf/scarf/Features/Kanban/Views/KanbanColumnView.swift) owns its `dropDestination(for: KanbanTaskRef.self)`. [KanbanCardView](scarf/scarf/Features/Kanban/Views/KanbanCardView.swift) handles the `.draggable` source, status-specific chrome (running edge accent + shimmer; blocked warning glyph; done dim 0.7/0.55), and a custom drag preview. [KanbanInspectorPane](scarf/scarf/Features/Kanban/Views/KanbanInspectorPane.swift) is a 420pt side-pane (not modal) so the user can keep dragging cards after inspecting one. [KanbanCreateSheet](scarf/scarf/Features/Kanban/Views/KanbanCreateSheet.swift) maps form state to a `KanbanCreateRequest`; the Workspace picker locks to "Project Dir" on per-project boards. [KanbanBlockReasonSheet](scarf/scarf/Features/Kanban/Views/KanbanBlockReasonSheet.swift) and [KanbanCompleteResultSheet](scarf/scarf/Features/Kanban/Views/KanbanCompleteResultSheet.swift) prompt for optional `--reason` / `--result` text on those transitions.

**Per-project surface.** New `DashboardTab.kanban` case in `ProjectsView.swift`, dispatched to [ProjectKanbanTab](scarf/scarf/Features/Projects/Views/ProjectKanbanTab.swift) which mints the tenant on appearance and wraps `KanbanBoardView` with `tenantFilter` + `projectPath` pre-applied. Capability-gated on `HermesCapabilities.hasKanban` so pre-v0.12 hosts don't see a broken destination. Plus a new `kanban_summary` widget — top 3 tasks by priority across `running` + `blocked` + `todo` for the project's tenant, with stats glance footer. Mirror in `tools/widget-schema.json`, `tools/build-catalog.py`, and `site/widgets.js`. Templates can reference it as `{ kind: kanban_summary, max_rows: 3 }` in dashboard.json.

**iOS surface.** Read-only board on the project Kanban tab ([ScarfGoKanbanView](Scarf%20iOS/Kanban/ScarfGoKanbanView.swift) + [ScarfGoKanbanDetailSheet](Scarf%20iOS/Kanban/ScarfGoKanbanDetailSheet.swift)). Renders the 5 columns as a horizontally-paged `Picker` of single-column lists — HIG-friendly on iPhone. No mutations, no drag-drop in v2.7.5 (deferred to a later release). Card titles use semantic `.headline` (not `ScarfFont`) so Dynamic Type works; chrome (badges) keeps `ScarfBadge` for fixed visual weight. Gated on `HermesCapabilities.hasKanban`; pre-v0.12 hosts don't see the segment.

**Capability gating.** Kept the single `HermesCapabilities.hasKanban` flag (`>= 0.12.0`). All 27 verbs shipped together; finer-grained gating is YAGNI. A `hasKanbanWatch` flag will land in a later release if `watch` semantics drift between point releases.

**Don't:** introduce within-column reorder via a client-side ordering sidecar — sort order would diverge from dispatcher's actual run order, which is worse than no manual order. Use `priority` on `kanban create` to set initial order; revisit when Hermes ships an `update --priority` verb. Don't try to mutate `priority` / `title` / `body` post-create — there's no verb. Don't drop cards from `done` into anything — Done is terminal. Don't call `transport.runProcess` directly from view bodies; route through `KanbanService` (the actor) so polling and writes share the same concurrency model.

## Project Templates

Scarf ships a `.scarftemplate` format (v1 as of 2.2.0) for sharing pre-packaged projects across users and machines. A bundle is a zip containing:

- `template.json` — manifest (id, name, version, `contents` claim)
- `README.md` — shown in the install preview sheet
- `AGENTS.md` — required; the [Linux Foundation cross-agent instructions standard](https://agents.md/) — every template is agent-portable out of the box
- `dashboard.json` — copied to `<project>/.scarf/dashboard.json`
- `instructions/…` — optional per-agent shims (`CLAUDE.md`, `GEMINI.md`, `.cursorrules`, `.github/copilot-instructions.md`)
- `skills/<name>/…` — optional; installed to `~/.hermes/skills/templates/<slug>/` (namespaced so uninstall is `rm -rf` on one folder)
- `cron/jobs.json` — optional; registered via `hermes cron create` with a `[tmpl:<id>] …` name prefix and immediately paused
- `memory/append.md` — optional; appended to `~/.hermes/memories/MEMORY.md` between `<!-- scarf-template:<id>:begin/end -->` markers

Key services: [ProjectTemplateService.swift](scarf/scarf/Core/Services/ProjectTemplateService.swift) (inspect + validate + plan), [ProjectTemplateInstaller.swift](scarf/scarf/Core/Services/ProjectTemplateInstaller.swift) (execute a plan), [ProjectTemplateExporter.swift](scarf/scarf/Core/Services/ProjectTemplateExporter.swift) (build a bundle from a project), [ProjectTemplateUninstaller.swift](scarf/scarf/Core/Services/ProjectTemplateUninstaller.swift) (reverse an install using the lock file). UI in [Features/Templates/](scarf/scarf/Features/Templates/). The `scarf://install?url=<https URL>` deep link + `file://` URLs for `.scarftemplate` files are handled by [TemplateURLRouter.swift](scarf/scarf/Core/Services/TemplateURLRouter.swift) and `onOpenURL` in `scarfApp.swift`. A `<project>/.scarf/template.lock.json` uninstall manifest is written after every install and drives the uninstall flow.

**Uninstall semantics:** driven by the lock file. Only files listed in `lock.projectFiles` are removed from the project dir; user-added files (e.g. a `sites.txt` created on first run) are preserved. If every file in the dir was installed by the template, the dir is removed too; otherwise the dir stays with just the user's files. Skills namespace is always removed wholesale (it's isolated). Cron jobs are removed via `hermes cron remove <id>` after resolving each lock-recorded name. Memory block is stripped between the `begin`/`end` markers, leaving the rest of MEMORY.md intact. No "undo" — uninstall is destructive; to re-install, run the install flow again. Uninstall UI lives on the project-list context menu and the dashboard header (only shown when the selected project has a lock file).

**Never** let a template write to `config.yaml`, `auth.json`, sessions, or any credential path — the v1 installer refuses. If you extend the format, treat the preview sheet as load-bearing: the user's only trust boundary is that the sheet is honest about everything that's about to be written.

### Template configuration (v2.3, schemaVersion 2)

Templates can declare a typed configuration schema in `template.json`'s new `config` block. The installer renders a **Configure** step between the parent-directory pick and the preview sheet; values land at `<project>/.scarf/config.json` (non-secret) and in the login Keychain (secret). A post-install **Configuration** button on the dashboard header (shown when `<project>/.scarf/manifest.json` exists) opens the same form pre-filled for editing.

Manifest shape:

```json
{
  "schemaVersion": 2,
  "contents": { "dashboard": true, "agentsMd": true, "config": 2 },
  "config": {
    "schema": [
      {"key": "site_url", "type": "string", "label": "Site URL", "required": true},
      {"key": "api_token", "type": "secret", "label": "API Token", "required": true}
    ],
    "modelRecommendation": {
      "preferred": "claude-sonnet-4.5",
      "rationale": "Tool-heavy workload — reasoning helps."
    }
  }
}
```

Supported field types: `string`, `text`, `number`, `bool`, `enum` (with `options: [{value, label}]`), `list` (itemType `"string"` only in v1), `secret`. Type-specific constraints (`pattern`, `min`/`max`, `minLength`/`maxLength`, `minItems`/`maxItems`) are optional. `secret` fields **must not** declare a `default` — the validator refuses.

Key services: [TemplateConfig.swift](scarf/scarf/Core/Models/TemplateConfig.swift) (schema + value models + Keychain ref helpers), [ProjectConfigKeychain.swift](scarf/scarf/Core/Services/ProjectConfigKeychain.swift) (thin `SecItemAdd`/`Copy`/`Delete` wrapper; the only Keychain user in Scarf today), [ProjectConfigService.swift](scarf/scarf/Core/Services/ProjectConfigService.swift) (load/save config.json, resolve secrets, cache manifest, validate schema + values). UI in [Features/Templates/ViewModels/TemplateConfigViewModel.swift](scarf/scarf/Features/Templates/ViewModels/TemplateConfigViewModel.swift) + [Features/Templates/Views/TemplateConfigSheet.swift](scarf/scarf/Features/Templates/Views/TemplateConfigSheet.swift).

**Secret storage.** Keychain service name is `com.scarf.template.<slug>`, account is `<fieldKey>:<project-path-hash-short>`. The path-hash suffix means two installs of the same template in different dirs don't collide on Keychain entries. Values in `config.json` are `"keychain://service/account"` URIs — never plaintext. The bytes hit the Keychain only on form commit, so cancelling never leaves orphan entries.

**Uninstall.** `TemplateLock` v2 gains `config_keychain_items` and `config_fields` arrays. The uninstaller iterates each URI through `SecItemDelete` before removing the lock file. Absent items (user hand-cleaned) are no-ops.

**Exporter.** Carries the *schema* from `<project>/.scarf/manifest.json` through into exported bundles, never values. Exporting never leaks anyone's secrets. `schemaVersion` bumps to 2 only when a schema is forwarded; schema-less exports stay at 1.

**Catalog site.** [tools/build-catalog.py](tools/build-catalog.py) mirrors the Swift schema validator. Each v2 template's `template.json` is copied into `.gh-pages-worktree/templates/<slug>/manifest.json` and the site's `widgets.js` calls `ScarfWidgets.renderConfigSchema` to display the schema on the detail page (display-only — the form lives in-app).

**Schema is Swift-primary.** If `TemplateConfigField.FieldType` gains a new case, update in order: `TemplateConfig.swift` (model + validation), `tools/build-catalog.py` (`SUPPORTED_CONFIG_FIELD_TYPES` + type-specific rules), `widgets.js` (`summariseConstraint`), `TemplateConfigSheet.swift` (new control subview), tests on both sides. Schema drift between validator + installer is the kind of bug users only notice after shipping.

### Project-scoped chat + Scarf-managed AGENTS.md context (v2.3)

v2.3 adds a per-project Sessions tab and a "New Chat" button that spawns `hermes acp` with `cwd = project.path`. Session-to-project attribution is persisted in a Scarf-owned sidecar at `~/.hermes/scarf/session_project_map.json` — the ACP wire protocol has no project-metadata hook (extra params are silently dropped), and `state.db` has no cwd column, so the sidecar is Scarf's source of truth for "which project does this session belong to?" Managed by [SessionAttributionService.swift](scarf/scarf/Core/Services/SessionAttributionService.swift); read by the per-project [ProjectSessionsView.swift](scarf/scarf/Features/Projects/Views/ProjectSessionsView.swift).

**Giving the agent project awareness.** Hermes auto-reads a context file from the session's cwd at startup — priority order `.hermes.md` → `HERMES.md` → `AGENTS.md` → `CLAUDE.md` → `.cursorrules`, first match wins, 20KB cap. We lean on that by writing a Scarf-managed block into `<project>/AGENTS.md` before opening the session. Service: [ProjectAgentContextService.swift](scarf/scarf/Core/Services/ProjectAgentContextService.swift). Block shape:

```
<!-- scarf-project:begin -->
## Scarf project context
_Auto-generated by Scarf — do not edit between the begin/end markers._

You are operating inside a Scarf project named **"<Project Name>"**. …

- **Project directory:** `<absolute path>`
- **Dashboard:** `<path>/.scarf/dashboard.json`
- **Template:** `<author/id>` v<version>    <!-- template-installed only -->
- **Configuration fields:** `field_a`, `field_b (secret — name only, value stored in Keychain)`
- **Registered cron jobs:** `[tmpl:<id>] <name>` — schedule …, currently paused|enabled
- **Uninstall manifest:** `<path>/.scarf/template.lock.json`  <!-- when present -->

Any content below this block is template- or user-authored; preserve and defer to it.
<!-- scarf-project:end -->
```

**Invariants.**

- **Secret-safe.** Block surfaces field NAMES, never VALUES. A project with a Keychain-stored secret shows `api_token (secret — name only, …)`; the Keychain ref URI and any plaintext value never appear. Auditable by `refreshListsFieldNamesNotValues` in `ProjectAgentContextServiceTests`.
- **Idempotent.** Two refreshes with unchanged state produce byte-identical output. The write is skipped entirely when no delta, avoiding file-watcher churn.
- **Bounded.** Everything outside the markers is preserved on every refresh. Template-author AGENTS.md content lives safely below the block.
- **Non-fatal.** `ChatViewModel.startACPSession` calls refresh with `try?` + log — a failed write doesn't block the chat from starting; worst case is the session loses project awareness.
- **Refresh timing.** Called BEFORE `client.start()` so the block lands before Hermes's session-boot context scan. Skipping this ordering = the agent sees stale context from the previous refresh (or nothing, on fresh projects).

**Template-author contract.** A template shipped via the catalog should include an `AGENTS.md` with the template's operational instructions. Authors leave the `<!-- scarf-project -->` region alone — Scarf populates it at chat-start time. Everything below is template-owned and preserved.

**Known caveat.** If any parent directory of the project contains `.hermes.md` or `HERMES.md`, those shadow the project's `AGENTS.md` (higher in Hermes's priority order). No fix in v2.3 — deferred to v2.4 pending user input on how to handle authored `.hermes.md` files.

## Template Catalog

Shipped community templates live at `templates/<author>/<name>/` (one level down — `templates/CONTRIBUTING.md` explains the submission flow for authors). The catalog site is generated from this directory and served at `awizemann.github.io/scarf/templates/` alongside the Sparkle appcast — the two coexist on the `gh-pages` branch but touch completely disjoint paths.

Pipeline:

- **Validator + regenerator:** [tools/build-catalog.py](tools/build-catalog.py) is stdlib-only Python (3.9+). It walks `templates/*/*/`, validates every `.scarftemplate` against its manifest claim (mirrors the Swift `ProjectTemplateService.verifyClaims` invariants), enforces a 5 MB bundle-size cap, scans for high-confidence secret patterns, checks `staging/` matches the built bundle byte-for-byte, and emits `templates/catalog.json`. Tested by [tools/test_build_catalog.py](tools/test_build_catalog.py) — 16 tests covering every validation path.
- **Wrapper:** [scripts/catalog.sh](scripts/catalog.sh) mirrors the `scripts/wiki.sh` shape with `check / build / preview / serve / publish` subcommands. `publish` runs a second-pass secret-scan against the rendered site before committing + pushing `gh-pages`.
- **Site source:** `site/index.html.tmpl` + `site/template.html.tmpl` are `{{TOKEN}}`-substitution templates. `site/widgets.js` (~300 lines of vanilla JS) is the dogfood — renders a `ProjectDashboard` JSON into HTML using the same widget vocabulary the Swift app uses, so each template's detail page shows a live preview of its post-install dashboard.
- **Install-URL hosting:** raw-served from `main` at `https://raw.githubusercontent.com/awizemann/scarf/main/templates/<author>/<name>/<name>.scarftemplate`. No per-template Releases ceremony.
- **CI gate:** [.github/workflows/validate-template-pr.yml](.github/workflows/validate-template-pr.yml) runs the Python validator + its own test suite on every PR that touches `templates/`, the validator, or its tests. Failures post a comment on the PR with the last 3 KB of the validator log.

Maintainer workflow on merge to main:

```bash
./scripts/catalog.sh build       # regenerate templates/catalog.json + .gh-pages-worktree/templates/
./scripts/catalog.sh publish     # secret-scan rendered output + commit + push gh-pages
```

Same cadence as `scripts/release.sh` (manual, auditable, no auto-deploy). Runs stay isolated: release.sh only touches `appcast.xml` on gh-pages; catalog.sh only touches `templates/` on gh-pages. Never push catalog output on a release cadence or vice versa.

**Schema is Swift-primary.** When `ProjectDashboardWidget.type` gains a new case or `ProjectTemplateManifest` adds a field, update Swift first, then mirror into `tools/build-catalog.py` (`SUPPORTED_WIDGET_TYPES`, `_validate_manifest`, `_validate_contents_claim`) so the web validator stays honest. The Python test suite's real-bundle test catches drift on the example template but not on the full widget vocabulary — add a synthetic fixture to `test_build_catalog.py` for any new widget type.
