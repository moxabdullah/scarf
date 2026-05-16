import SwiftUI
import ScarfCore
import ScarfDesign

struct MCPServerEditorView: View {
    @State var viewModel: MCPServerEditorViewModel
    let onSave: (Bool) -> Void
    let onCancel: () -> Void
    @Environment(\.hermesCapabilities) private var capabilitiesStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit \(viewModel.server.name)")
                        .scarfStyle(.headline)
                    Text(viewModel.server.transport.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    viewModel.save { changed in
                        if changed { onSave(true) }
                    }
                } label: {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(ScarfPrimaryButton())
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isSaving)
            }
            .padding()
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let error = viewModel.saveError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if viewModel.server.transport == .stdio {
                        envSection
                    } else {
                        headersSection
                    }
                    toolsSection
                    timeoutsSection
                    if capabilitiesStore?.capabilities.hasMCPParallelToolCalls == true {
                        parallelToolCallsSection
                    }
                    if viewModel.server.hasOAuthToken {
                        oauthSection
                    }
                }
                .padding()
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var envSection: some View {
        sectionBox(title: "Environment Variables") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.envDraft.isEmpty {
                    Text("No env vars. Add one with the button below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($viewModel.envDraft) { $row in
                    HStack(spacing: 8) {
                        TextField("KEY", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 240)
                        if viewModel.showSecrets {
                            TextField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("value", text: $row.value)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(role: .destructive) {
                            viewModel.removeEnvRow(id: row.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button {
                        viewModel.appendEnvRow()
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                    }
                    Spacer()
                    Toggle("Show values", isOn: $viewModel.showSecrets)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
        }
    }

    private var headersSection: some View {
        sectionBox(title: "Headers") {
            VStack(alignment: .leading, spacing: 8) {
                if viewModel.headersDraft.isEmpty {
                    Text("No headers. Add one with the button below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach($viewModel.headersDraft) { $row in
                    HStack(spacing: 8) {
                        TextField("Header", text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                        TextField("value", text: $row.value)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            viewModel.removeHeaderRow(id: row.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    viewModel.appendHeaderRow()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
            }
        }
    }

    private var toolsSection: some View {
        sectionBox(title: "Tool Filters") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Include (comma-separated — if set, only these are exposed)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("tool_a, tool_b", text: $viewModel.includeDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exclude")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("tool_c", text: $viewModel.excludeDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                Toggle("Expose resources", isOn: $viewModel.resourcesEnabled)
                Toggle("Expose prompts", isOn: $viewModel.promptsEnabled)
            }
        }
    }

    private var timeoutsSection: some View {
        sectionBox(title: "Timeouts (seconds)") {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connect timeout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("default", text: $viewModel.connectTimeoutDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Call timeout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("default", text: $viewModel.timeoutDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 140)
                }
                if viewModel.server.transport == .sse {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SSE read timeout")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("default 300", text: $viewModel.sseReadTimeoutDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                    }
                }
                Spacer()
            }
        }
    }

    /// v0.14 — tri-state picker for `supports_parallel_tool_calls`.
    /// "Default (Hermes decides)" maps to nil and drops the YAML key
    /// entirely; "Enabled" / "Disabled" write the explicit bool. The
    /// section is hidden on pre-v0.14 hosts via the capability gate
    /// in `body`.
    private var parallelToolCallsSection: some View {
        sectionBox(title: "Parallel tool calls") {
            VStack(alignment: .leading, spacing: 8) {
                Picker(
                    "supports_parallel_tool_calls",
                    selection: Binding<Int>(
                        get: {
                            switch viewModel.parallelToolCallsDraft {
                            case .none: return 0
                            case .some(true): return 1
                            case .some(false): return 2
                            }
                        },
                        set: { newValue in
                            switch newValue {
                            case 1: viewModel.parallelToolCallsDraft = true
                            case 2: viewModel.parallelToolCallsDraft = false
                            default: viewModel.parallelToolCallsDraft = nil
                            }
                        }
                    )
                ) {
                    Text("Default (Hermes decides)").tag(0)
                    Text("Enabled").tag(1)
                    Text("Disabled").tag(2)
                }
                .pickerStyle(.segmented)
                Text("When enabled, Hermes can batch concurrent tool calls to this MCP server instead of serializing them. Requires Hermes v0.14+.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var oauthSection: some View {
        sectionBox(title: "OAuth Token") {
            HStack {
                Text("Token on disk. Clear to re-authenticate next time the gateway connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear Token", role: .destructive) {
                    viewModel.clearOAuthToken { _ in }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionBox<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.bold())
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
