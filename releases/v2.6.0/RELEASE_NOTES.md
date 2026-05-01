## What's in 2.6.0

A major release tracking **Hermes v2026.4.30 (v0.12.0)** — the largest single Hermes update Scarf has had to follow since v0.10's Tool Gateway. Headline additions: the autonomous **Curator**, **multimodal image input** in chat, **5 new inference providers**, **Microsoft Teams + Yuanbao** gateway platforms, a **read-only Kanban** view, and ScarfGo gains read-only Webhooks/Plugins/Profiles plus a Hermes-version banner.

Pre-v0.12 Hermes hosts are fully supported. Every new surface is gated on a runtime capability detector (`hermes --version` → semver), so users on older Hermes installs see the v2.5 surface unchanged. UI doesn't appear until the underlying CLI subcommand exists.

### Curator (Mac + iOS)

Hermes v0.12's autonomous skill curator prunes / consolidates / archives agent-created skills on a 7-day schedule. Scarf adds a dedicated **Curator** sidebar item under Interact (Mac) and a Curator nav row under the System tab (iOS).

- **Status panel** — enabled/paused/disabled badge, last-run timestamp, last summary, run count, scheduling cadence (interval / stale-after / archive-after).
- **Run Now** button triggers `hermes curator run`; pause/resume from the kebab menu.
- **Three leaderboards** — least-recently-active, most-active, least-active. Each row carries activity / use / view / patch counters and an inline pin toggle.
- **Pin / unpin** — pinned skills are protected from auto-archive and rewrites. State pulled from `~/.hermes/skills/.curator_state` and surfaced as a pin glyph everywhere skills appear (Curator screen, Skills sidebar/list, SkillDetailView).
- **Restore archived** sheet calls `hermes curator restore <name>` to bring a previously-archived skill back.
- **Last report Markdown** — when present, the previous run's REPORT.md renders inline in mono.

Capability-gated; sidebar item disappears on pre-v0.12 hosts.

### Multimodal image input in chat (Mac + iOS)

Hermes v0.12 advertises `prompt_capabilities.image = true` on ACP and accepts image content blocks in `session/prompt`. Scarf wires the producer side on both targets:

- **Mac**: paperclip toolbar button on the chat composer opens NSOpenPanel multi-pick. Drag-and-drop and paste also work — drop an image (or a Finder file URL) onto the composer and it attaches. Capability-gated; the entire attachment surface is hidden on pre-v0.12 hosts.
- **iOS**: paperclip button opens PhotosPicker (multi-select up to 5 photos). Same byte-for-byte capability gate.
- **ImageEncoder** downsamples to 1568px long-edge (Anthropic's recommended ceiling) at JPEG q=0.85, so a 12 MP screenshot lands under ~300 KB on the wire. Detached only — never blocks MainActor.
- **Image-only sends are valid** — once at least one attachment is queued, the send button enables even with empty text. Vision models accept "describe this" with no caption.
- **Per-attachment chips** above the input field with thumbnail + filename tooltip + X to remove. 5-image-per-message cap; total payload stays under ~2 MB so cellular sends don't time out.

Hermes routes the resulting prompt to a vision-capable model automatically — no extra Scarf-side work to pick the right aux model.

### 5 new inference providers (Mac + iOS)

Five overlay-only providers added to `ModelCatalogService.overlayOnlyProviders`. The model picker reaches all of them; provider IDs match `HERMES_OVERLAYS` in `hermes_cli/providers.py` exactly so a typo here doesn't strand users with an unreachable provider.

- **GMI Cloud** (api_key) — `https://api.gmi-serving.com/v1`
- **Azure AI Foundry** (api_key) — base URL resolved from `AZURE_FOUNDRY_BASE_URL` per tenant
- **LM Studio** (api_key, first-class) — promoted from custom-endpoint alias to a real provider; defaults to `http://127.0.0.1:1234/v1`
- **MiniMax (OAuth)** (oauth_external) — `https://api.minimax.io/anthropic`
- **Tencent TokenHub** (api_key) — base URL resolved from `TOKENHUB_BASE_URL`

### `auxiliary.curator` aux task (Mac)

Hermes removed `auxiliary.flush_memories` entirely in v0.12 (the underlying memory pipeline was rewritten) and added `auxiliary.curator` so the curator's review fork can run on a separate model from the main agent. Settings → Auxiliary now surfaces a Curator row when the active host is v0.12+ (gated on `HermesCapabilities.hasCuratorAux`); the obsolete Flush Memories panel is gone.

The Tool Gateway health view in HealthView lost the flushMemories-routes-through-Nous row and gained a curator row, matching the new aux task list.

### Skills v0.12 surface (Mac + iOS)

Three new capabilities Scarf can now reach:

- **Direct-URL install** — `hermes skills install <https-url>` lets users pull a one-off skill without going through a registry. Mac SkillsView gains an "Install from URL…" toolbar button (capability-gated) opening a sheet with the URL field plus optional `--category` / `--name` overrides.
- **Reload** — `hermes skills audit` rescans the skills directory and refreshes the agent's view without a session restart. Wired to a "Reload" toolbar button next to the install button on Mac.
- **Enabled / disabled state** — `skills.disabled` in config.yaml is read at scan time. Disabled skills render strikethrough + an "OFF" pill on Mac and iOS rows; iOS detail view explains the state in plain text.
- **Curator pin badge** — pinned-skill names from `~/.hermes/skills/.curator_state` surface as a pin glyph on each row across Mac sidebar and iOS list, plus an explanatory chip on iOS detail view.

The disable-toggle write path is deferred to v2.7 — Hermes only exposes `hermes skills config` as an interactive verb today, and we'd rather read accurately than risk clobbering the user's list with a half-tested write.

### Cron — `--workdir` flag (Mac)

Hermes v0.12 cron jobs accept `--workdir <absolute-path>` to inject AGENTS.md / CLAUDE.md / .cursorrules from that directory and pin cwd for terminal/file/code_exec tools. Scarf's CronJobEditor now has a Workdir field; both create and edit paths forward the flag. Existing v0.11 jobs keep the no-cwd behaviour by leaving the field blank.

The `context_from` chaining field is read-only from Scarf this round (Hermes hasn't exposed a `--context-from` CLI flag yet, only YAML).

### Microsoft Teams + Yuanbao (Mac)

Two new gateway platforms. Microsoft Teams (the 19th platform) ships as a plugin; Yuanbao 元宝 (the 18th) is a native gateway adapter. Both surface in the Platforms tab with read-only setup panels — the OAuth dance for Yuanbao and the plugin install for Teams happen outside Scarf.

### Read-only Kanban (Mac)

Hermes v0.12 ships a SQLite-backed multi-tenant task board with a full CLI (`hermes kanban create / list / claim / dispatch / …`). The multi-profile *collaboration* layer was reverted upstream while the design is reworked, so v2.6 ships a **read-only** Kanban view: paginated table of `hermes kanban list --json` filtered by status, with status badges, meta chips (id / assignee / workspace / skills), and per-row metadata. 5-second polling while the view is foregrounded; suspended on disappear.

Create / claim / dispatch UI is deferred until upstream stabilizes — building the editor now would risk rework on a quarter-out timeline.

### Settings deltas (Mac)

A new **Caching & Redaction** section under Settings → Advanced with three v0.12 knobs (gated on capability):

- **Prompt cache TTL** picker — 5m default / 1h opt-in. Reduces cache writes on long agent loops with stable system prompts.
- **Redact secrets in patches** toggle — Hermes flipped this off by default in v0.12 because the substitution corrupted patches; security-sensitive users can flip it back on here.
- **Runtime metadata footer** toggle — opt-in compact footer on each final reply (provider/model/cost/turn count).

TTS provider list gains **piper** (native local TTS engine new in v0.12). Terminal backend list gains **vercel** (Vercel Sandbox backend for execute_code/terminal). Both ride along unconditionally — Hermes silently falls back when an older host doesn't recognize the value.

### iOS catch-up — Webhooks / Plugins / Profiles (read-only)

Three new System-tab nav rows in ScarfGo, all read-only:

- **Webhooks** — list of `hermes webhook list` output with description / deliver / events / route per row. "Platform not enabled" detection so a freshly-installed Hermes shows setup guidance instead of error noise.
- **Plugins** — filesystem-first scan over `~/.hermes/plugins/` with manifest reads (plugin.json or plugin.yaml). Enabled/disabled badge, version, source, path.
- **Profiles** — `hermes profile list` with active-profile highlighting from `~/.hermes/active_profile`. Tolerant of both Rich box-drawn and plain-text outputs.

None of the three are capability-gated — the underlying list verbs work on both v0.11 and v0.12. Create / edit / delete remain Mac-only since they touch enough state we keep them off the phone.

### Hermes-version banner (iOS)

Yellow banner at the top of the Dashboard tab when the active server is pre-v0.12. Lists the v0.12 capabilities the user is missing out on (curator, multimodal image input, new providers); one-tap session-dismiss; reappears on next app open. Hidden entirely on v0.12+ hosts.

### Internal — version-aware capability detection

The foundation of every gated surface above:

- `HermesCapabilities` value type parses `Hermes Agent v0.12.0 (2026.4.30)` from `hermes --version` output. Exposes booleans for each release-gated UI surface (`hasCurator`, `hasACPImagePrompts`, `hasKanban`, `hasOneShot`, `hasSkillURLInstall`, `hasFallbackCommand`, `hasUpdateCheck`, `hasPiperTTS`, `hasVercelTerminal`, `hasCuratorAux`, `hasTeamsPlatform`, `hasYuanbaoPlatform`, `hasCronWorkdir`, `hasPromptCacheTTL`, `hasRedactionToggle`, `hasFlushMemoriesAux`).
- `HermesCapabilitiesStore` (`@Observable @MainActor`) caches per-server capabilities. Injected on `ContextBoundRoot` (Mac) and `ScarfGoTabRoot` (iOS) via `.environment(_:)` and `.hermesCapabilities(_:)`.
- 12 parser tests + 6 curator-output parser tests lock the v0.12 / v0.11 / fallback flag matrices.

### Bug fixes

- **Test target compile** — `M5FeatureVMTests.ScriptedTransport` had drifted off the `ServerTransport` protocol after `cachedSnapshotPath` landed in v2.5.2; added the missing stub. `M0dViewModelsTests` got the `ConnectionStatusViewModel.Status.degraded` argument-name update. `CredentialPoolsGatingTests` got the missing `import ScarfCore`. The full `swift test` suite now runs (and passes — 215 tests across 17 suites).
- **iOS package compile** — `RemoteBackupService.zipDirectory` and `RemoteRestoreService.unzipArchive` used `Foundation.Process` unconditionally, breaking the iOS build entirely (Process is unavailable on the iOS SDK). Wrapped in `#if !os(iOS)` with iOS stubs that throw — backup/restore is Mac-only by design.

### Hermes version

Targets Hermes **v2026.4.30 (v0.12.0)**. v2026.4.23 (v0.11.0) hosts continue to work — every v0.12 surface is gated on capability detection, so Scarf v2.6 against v0.11 looks identical to Scarf v2.5.2 against v0.11. Update Hermes (`hermes update`) to unlock the new surfaces.

### Compatibility

- macOS 14+ (unchanged)
- iOS 17+ (unchanged)
- Hermes v0.11+ for the v2.5 surface; v0.12+ for the new features above.
- No data migrations.
