import SwiftUI
import ScarfCore
import ScarfDesign

/// Web Tools tab — search + extract backend pickers. Pre-v0.13 hosts
/// see a single "Combined backend" row writing to the legacy
/// `web_tools.backend` key. v0.13+ hosts see two rows writing to the
/// per-capability split keys (`web_tools.search.backend` +
/// `web_tools.extract.backend`); SearXNG appears in the search picker
/// only because Hermes registers it as a search-only backend.
struct WebToolsTab: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    private var split: Bool {
        capabilitiesStore?.capabilities.hasWebToolsBackendSplit ?? false
    }

    // TODO(WS-7-Q6): Backend lists are curated inline based on the v0.13
    // release notes ("SearXNG joined search-only"). The exact dispatch
    // table lives in `~/.hermes/hermes-agent/hermes_cli/web_tools.py` —
    // verify during integration. A wrong entry just produces a
    // `hermes config set` failure on save (recoverable, not silent).
    private static let searchBackends: [String] = [
        "duckduckgo", "tavily", "brave", "exa", "you", "searxng"
    ]
    private static let extractBackends: [String] = [
        "reader", "browserless", "trafilatura", "firecrawl"
    ]
    /// v0.12 combined-backend list — superset of the v0.13 search list
    /// minus SearXNG (which only dispatches as search) plus the v0.13
    /// extract-only entries that pre-v0.13 hosts handled under the
    /// combined key.
    private static let combinedBackends: [String] = [
        "duckduckgo", "tavily", "brave", "exa", "you",
        "reader", "browserless", "trafilatura", "firecrawl"
    ]

    var body: some View {
        if split {
            SettingsSection(title: "Web Tools", icon: "globe.americas") {
                PickerRow(
                    label: "Search backend",
                    selection: viewModel.config.webToolsSearchBackend,
                    options: Self.searchBackends
                ) { viewModel.setWebToolsSearchBackend($0) }
                PickerRow(
                    label: "Extract backend",
                    selection: viewModel.config.webToolsExtractBackend,
                    options: Self.extractBackends
                ) { viewModel.setWebToolsExtractBackend($0) }
            }
            Text("SearXNG joined v0.13 as a search-only backend. Backend-specific tuning (host URLs, API keys) lives in the raw YAML editor for now.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundMuted)
                .padding(.horizontal, ScarfSpace.s4)
        } else {
            // TODO(WS-7-Q7): Pre-v0.13 hosts fall back to the legacy single
            // backend. v0.13 may or may not honour `web_tools.backend` as a
            // fallback when the split keys are absent — verify with Hermes
            // and consider a one-time migration prompt in a follow-up if
            // upgrading from v0.12 silently resets the user's backend.
            SettingsSection(title: "Web Tools", icon: "globe.americas") {
                PickerRow(
                    label: "Backend",
                    selection: viewModel.config.webToolsBackend,
                    options: Self.combinedBackends
                ) { viewModel.setWebToolsBackend($0) }
            }
            Text("Hermes v0.13 splits search and extract into separate backends. Update Hermes to access the per-capability picker.")
                .scarfStyle(.caption)
                .foregroundStyle(ScarfColor.foregroundFaint)
                .padding(.horizontal, ScarfSpace.s4)
        }
    }
}
