import Foundation
import ScarfCore

@Observable
final class HermesFileWatcher {
    private(set) var lastChangeDate = Date()
    private var coreSources: [DispatchSourceFileSystemObject] = []
    private var projectSources: [DispatchSourceFileSystemObject] = []
    private var timer: Timer?
    /// Remote polling task. Non-nil only when `context.isRemote`. Cancelled
    /// on `stopWatching()`.
    private var remotePollTask: Task<Void, Never>?
    /// Project directory paths fed to the SSH poller alongside `watchedCorePaths`.
    /// Updated by `updateProjectWatches` so the remote stream restarts whenever
    /// the project list changes.
    private var remoteProjectPaths: [String] = []

    let context: ServerContext
    private let transport: any ServerTransport

    nonisolated init(context: ServerContext = .local) {
        self.context = context
        self.transport = context.makeTransport()
    }

    /// Canonical list of paths we observe. Used for both FSEvents (local)
    /// and mtime polling (remote).
    private var watchedCorePaths: [String] {
        let paths = context.paths
        return [
            paths.stateDB,
            paths.stateDB + "-wal",
            paths.configYAML,
            paths.home + "/.env",
            paths.memoryMD,
            paths.userMD,
            paths.cronJobsJSON,
            paths.gatewayStateJSON,
            paths.agentLog,
            paths.errorsLog,
            paths.gatewayLog,
            paths.projectsRegistry,
            // v2.3: sidecar attributing Hermes session IDs to Scarf project
            // paths. Written by SessionAttributionService when a chat
            // starts with a project context; read by
            // ProjectSessionsViewModel to filter the session list. Without
            // watching this file, the per-project Sessions tab would only
            // pick up new sessions when the user re-entered the tab
            // (triggering .task(id:) re-fire) — switching directly back
            // to the project's Sessions tab after a chat left the tab
            // stale.
            paths.sessionProjectMap,
            paths.mcpTokensDir
        ]
    }

    func startWatching() {
        if context.isRemote {
            startRemotePoller()
            return
        }

        for path in watchedCorePaths {
            if let source = makeSource(for: path) {
                coreSources.append(source)
            }
        }
        // No heartbeat timer: every observing view runs its `.onChange`
        // refresh whenever `lastChangeDate` ticks, so a 5s unconditional
        // tick was triggering wasted reloads across many subscribers
        // (Dashboard, Memory, Cron, Gateway, Platforms, Projects, Chat).
        // FSEvents reliably fires on real changes; menu-bar Start/Stop
        // touches `gateway_state.json` which the watcher catches.
    }

    /// (Re)start the SSH polling stream over the union of `watchedCorePaths`
    /// and the current `remoteProjectPaths`. Called on initial start and
    /// whenever `updateProjectWatches` changes the project set.
    private func startRemotePoller() {
        remotePollTask?.cancel()
        let stream = transport.watchPaths(watchedCorePaths + remoteProjectPaths)
        remotePollTask = Task { [weak self] in
            for await _ in stream {
                await MainActor.run { [weak self] in
                    self?.lastChangeDate = Date()
                }
            }
        }
    }

    func stopWatching() {
        for source in coreSources + projectSources {
            source.cancel()
        }
        coreSources.removeAll()
        projectSources.removeAll()
        timer?.invalidate()
        timer = nil
        remotePollTask?.cancel()
        remotePollTask = nil
    }

    /// Watch each project's `dashboard.json` AND its enclosing `.scarf/`
    /// directory. Watching both is what lets file-reading widgets
    /// (markdown_file, log_tail, image) refresh when a cron job rewrites
    /// a sidecar file: dir-level FSEvents fire on add/remove/rename inside
    /// `.scarf/`, file-level FSEvents fire on dashboard.json content
    /// changes. In-place writes to an existing sidecar file (e.g., `>>` log
    /// append) are NOT detected — by convention the cron job should write
    /// atomically (write-then-rename) or `touch dashboard.json` after each
    /// run.
    func updateProjectWatches(dashboardPaths: [String], scarfDirs: [String]) {
        if context.isRemote {
            // Restart the SSH poller with the union of core + project dir
            // paths. `stat -c %Y` on a directory tracks mtime, which ticks
            // on add/remove/rename inside the dir — same coverage as the
            // local FSEvents directory watch below.
            let union = Array(Set(dashboardPaths + scarfDirs))
            remoteProjectPaths = union.sorted()
            startRemotePoller()
            return
        }
        for source in projectSources {
            source.cancel()
        }
        projectSources.removeAll()
        for path in dashboardPaths {
            if let source = makeSource(for: path) {
                projectSources.append(source)
            }
        }
        for dir in scarfDirs {
            if let source = makeSource(for: dir) {
                projectSources.append(source)
            }
        }
    }

    private func makeSource(for path: String) -> DispatchSourceFileSystemObject? {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.lastChangeDate = Date()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return source
    }

    deinit {
        stopWatching()
    }
}
