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
                    Text(store.settings.mode == .internal ? "Container: \(DockerManager.proxyManagerContainerName)" : "External Proxy Manager")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("Open Admin") {
                        if let url = adminURL {
                            NSWorkspace.shared.open(url)
                        }
                    }

                    if store.settings.mode == .internal {
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
                    }

                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            Form {
                Section("Proxy Manager") {
                    Picker("Mode", selection: $store.settings.mode) {
                        ForEach(ProxyManagerMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if store.settings.mode == .external {
                        LabeledContent("Admin IP / Host") {
                            TextField(defaultAdminHost, text: $store.settings.adminIp)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                    }

                    LabeledContent("Admin Port") {
                        TextField("Admin", value: $store.settings.adminPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    if store.settings.mode == .external {
                        Text("Open Admin uses the external host and admin port. DockAMP will not start or stop the internal proxy container in this mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if store.settings.mode == .internal {
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
                }

                Section {
                    Button("Save Settings") {
                        store.save()
                    }
                    .buttonStyle(.borderedProminent)

                    Text(store.settings.mode == .internal ? "Note: Port or mount changes require restarting Proxy Manager." : "External mode only saves the admin connection.")
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
        if store.settings.mode == .external {
            return "External Proxy Manager"
        }

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
        guard store.settings.mode == .internal else {
            status = .notCreated
            return
        }
        status = await dockerManager.getProxyManagerStatus()
    }

    private var defaultAdminHost: String {
        "localhost"
    }

    private var adminURL: URL? {
        if store.settings.mode == .internal {
            return URL(string: "http://localhost:\(store.settings.adminPort)")
        }
        return externalAdminURL(from: store.settings.adminIp, fallbackPort: store.settings.adminPort)
    }

    private func externalAdminURL(from value: String, fallbackPort: Int) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return URL(string: "http://\(defaultAdminHost):\(fallbackPort)")
        }

        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed), let host = url.host else {
                return nil
            }
            if url.port != nil || url.path != "" {
                return url
            }
            return URL(string: "\(url.scheme ?? "http")://\(host):\(fallbackPort)")
        }

        let host = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let colonCount = host.filter { $0 == ":" }.count
        if host.hasPrefix("[") || colonCount == 0 {
            return URL(string: "http://\(host):\(fallbackPort)")
        }
        if colonCount == 1 {
            return URL(string: "http://\(host)")
        }
        return URL(string: "http://[\(host)]:\(fallbackPort)")
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
