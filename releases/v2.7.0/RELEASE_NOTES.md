## What's in 2.7.0

A focused release on **project dashboards** — the most "live" surface for users running cron-driven workflows. This release does three things at once:

1. **Auto-refresh now covers the entire project, not just `dashboard.json`.** A widget that points at `<project>/.scarf/reports/uptime.md` refreshes the moment the cron job rewrites it.
2. **Five new widget types** make cron-driven monitoring dashboards much more expressive — render markdown reports from disk, tail log files, surface Hermes cron-job state, embed images, and pack many services into a compact status grid.
3. **`stat` widgets gain inline sparklines.** `list` items get a typed status enum with semantic colors. Unknown widget types render as a structured error card (not a generic "Unknown" placeholder).

**Backwards compatible — no schema bump.** Every existing `dashboard.json` renders byte-identically on v2.7. The catalog manifest format is unchanged. v1, v2, v3 bundles install identically as before. Templates that adopt new widget types still validate against the existing manifest schema — only the catalog validator's vocabulary list was extended.

### Project-wide auto-refresh

[`HermesFileWatcher`](../../scarf/scarf/Core/Services/HermesFileWatcher.swift) used to watch each project's `dashboard.json` file specifically. v2.7 promotes that to a watch on the entire `<project>/.scarf/` directory:

- **Local** — adds a `DispatchSourceFileSystemObject` per project's `.scarf/` dir alongside the existing per-file watch on `dashboard.json`.
- **Remote (SSH)** — folds project `.scarf/` directories into the existing 3-second mtime poll. Closes the explicit "Phase 4 polish item" deferral that landed in v2.3.

Effect: a `markdown_file` or `log_tail` widget pointing at `<project>/.scarf/reports/foo.md` refreshes automatically when a cron job rewrites the file. **By convention, place files the dashboard reads inside `.scarf/`** so the watch picks them up. Files outside `.scarf/` work too but only refresh when `dashboard.json` itself changes.

_Limitation:_ in-place appends to an existing file (`>> file.log`) don't tick the watcher — the cron job should write atomically (write-temp + rename), or `touch dashboard.json` after each run to force a refresh. Per-widget data-source watching (the granular alternative) is deferred to a future release; this project-wide pattern covers the common cron-driven workflow without the extra plumbing.

### Five new widget types

All five additive — pre-v2.7 Scarf renders unknown widget types as a clearly-labeled error card now (not a crash). They share two conventions: file paths are resolved relative to the project root with a hard `..`-escape rejection at [`WidgetPathResolver`](../../scarf/scarf/Features/Projects/Views/Widgets/WidgetPathResolver.swift), and reads happen in `Task.detached` so dashboards never block the main actor.

- **`markdown_file`** — renders a markdown file from disk through the same `MarkdownContentView` pipeline used by inline `text` widgets. Pair with cron jobs that write longer-form reports.
- **`log_tail`** — last `lines` of a file (default 20, max 200), monospaced, ANSI codes stripped. Killer for "what did my cron job print last run?".
- **`cron_status`** — last run / next run / state for one Hermes cron job by `jobId`, plus a small inline log tail. Read-only — Run / Pause / Resume controls stay on the Cron tab so the dashboard isn't a place where you accidentally fire a job.
- **`image`** — local file (`path` relative to project root, via `transport.readFile`) or remote `url` (via `AsyncImage`). Optional `height` cap. Useful for matplotlib/Plotly PNGs the cron job generates.
- **`status_grid`** — compact NxM grid of colored cells, one per service / item, with hover labels. Reuses the typed status enum so colors stay consistent with `list` widgets.

### `stat` widget gains inline sparklines

`stat` widgets now accept an optional `sparkline: [Number]` field — a tiny inline trend line under the big number. SVG-only render, no Chart.js dependency, dozens per dashboard cost nothing. Old `stat` widgets without the field render exactly as before.

### Typed status badges (lenient decode)

`list` items and `status_grid` cells share a typed status enum: `success`, `warning`, `danger`, `info`, `pending`, `done`, `neutral`. Common synonyms map to the canonical case (`ok` / `up` → success, `down` / `error` / `failed` → danger, `active` → info, `complete` → done). Unknown strings render as plain text rather than crashing — the dev's machine alone has dashboards using ad-hoc statuses like `"ok"`, `"up"`, `"info"`, and they all keep working byte-identically. **For new templates, prefer the canonical names** so colors stay predictable across releases.

### Structured widget error card

The legacy "Unknown: \<type\>" placeholder is replaced with a structured error card surfacing the widget's title, the specific reason (unknown type, missing file, parse error, path escapes project root), and a hint. Used by the dispatcher's default branch and by every v2.7 file-reading widget when its underlying data can't be loaded.

### Schema mirror — single source of truth

The widget vocabulary is now defined once at [`tools/widget-schema.json`](../../tools/widget-schema.json) instead of being maintained in three places by hand. The catalog validator ([`tools/build-catalog.py`](../../tools/build-catalog.py)) reads from it and now enforces per-type required fields (e.g. `cron_status` requires `jobId`, `log_tail` requires `path`). Adding a future widget type means editing one JSON file plus implementing a Swift view + a JS renderer; the validator picks up the addition automatically.

### What's deferred

Two items from the design plan stayed deferred:

- **Per-widget data sources + per-widget refresh granularity.** The general "widget points at a typed data source (file / cron / json-path / …)" abstraction is the next-largest win in this area but materially expands the model + JS mirror + validator + authoring skill surface. The project-wide watch covers the common cron-driven workflow without it; revisit when a real-world template wants the granular control.
- **Cross-project health digest sidebar rollup.** Counting attention-needed projects across the registry was scoped for this release but ended up not pulling its weight against the rest of the work; the underlying status enum (B.1) makes a future digest cheap to add.

### Compatibility

- macOS 14+ (unchanged).
- Hermes target: still **v2026.4.30 (v0.12.0)**. No new Hermes capability gates added.
- Existing `dashboard.json` files render unchanged.
- Existing `.scarftemplate` bundles install unchanged. Catalog manifest schemaVersion stays at 1/2/3 — no bump.
- The `awizemann/template-author` bundle was rebuilt to ship the updated `SKILL.md` (Widget Catalog v2.7+ section) so Hermes can scaffold dashboards using the new widget types out of the box.
