import SwiftUI

struct ProxyManagerConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ProxyManagerStore.shared
    @StateObject private var dockerManager = DockerManager.shared

    @State private var status: ContainerStatus = .notCreated
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(statusLabel)
                            .font(.headline)
                    }
                    Text("Container: \(DockerManager.proxyManagerContainerName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("Open Admin") {
                        if let url = URL(string: "http://localhost:\(store.settings.adminPort)") {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    Button("Start") {
                        Task { await startProxyManager() }
                    }
                    .disabled(isBusy || status == .running || status == .starting)

                    Button("Restart") {
                        Task { await restartProxyManager() }
                    }
                    .disabled(isBusy || status != .running)

                    Button("Stop", role: .destructive) {
                        Task { await stopProxyManager() }
                    }
                    .disabled(isBusy || status == .notCreated || status == .stopped)

                    Button("Update Image") {
                        Task { await updateProxyManagerImage() }
                    }
                    .disabled(isBusy)

                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            Form {
                Section("Ports") {
                    Toggle("Auto-Start with App", isOn: $store.settings.autoStartOnAppLaunch)

                    LabeledContent("HTTP Port") {
                        TextField("HTTP", value: $store.settings.httpPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("HTTPS Port") {
                        TextField("HTTPS", value: $store.settings.httpsPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("Admin Port") {
                        TextField("Admin", value: $store.settings.adminPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Persistence") {
                    Toggle("Use named volumes", isOn: $store.settings.useNamedVolumes)

                    if store.settings.useNamedVolumes {
                        Text("Volumes: \(DockerManager.proxyManagerDataVolumeName), \(DockerManager.proxyManagerLEVolumeName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Data Mount") {
                            HStack {
                                TextField("Path", text: $store.settings.dataMountPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose...") {
                                    selectFolder { path in
                                        store.settings.dataMountPath = path
                                    }
                                }
                            }
                        }

                        LabeledContent("Let's Encrypt Mount") {
                            HStack {
                                TextField("Path", text: $store.settings.letsEncryptMountPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose...") {
                                    selectFolder { path in
                                        store.settings.letsEncryptMountPath = path
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Container Resources") {
                    LabeledContent("CPU Cores (--cpus)") {
                        TextField("e.g. 1.0", text: $store.settings.cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("RAM Limit (--memory)") {
                        TextField("e.g. 512m or 1g", text: $store.settings.memoryLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }
                }

                Section {
                    Button("Save Settings") {
                        store.save()
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Note: Port or mount changes require restarting Proxy Manager.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding()
        }
        .overlay {
            if isBusy {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            await refreshStatus()
        }
    }

    private var statusColor: Color {
        switch status {
        case .running: return .green
        case .starting, .stopping: return .orange
        case .error: return .red
        case .stopped, .notCreated: return .secondary
        }
    }

    private var statusLabel: String {
        switch status {
        case .running: return "Proxy Manager running"
        case .starting: return "Proxy Manager starting"
        case .stopping: return "Proxy Manager stopping"
        case .stopped: return "Proxy Manager stopped"
        case .notCreated: return "Proxy Manager not created"
        case .error: return "Proxy Manager error"
        }
    }

    private func refreshStatus() async {
        status = await dockerManager.getProxyManagerStatus()
    }

    private func startProxyManager() async {
        isBusy = true
        defer { isBusy = false }

        do {
            store.save()
            try await dockerManager.startProxyManager(settings: store.settings)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func stopProxyManager() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await dockerManager.stopProxyManager()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func restartProxyManager() async {
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try? await dockerManager.stopProxyManager()
            try await dockerManager.startProxyManager(settings: store.settings)
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func updateProxyManagerImage() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await dockerManager.updateProxyManagerImage()
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func selectFolder(onSelect: (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select a directory"

        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url.path)
        }
    }
}

#Preview {
    ProxyManagerConfigView()
}
