import SwiftUI

struct ProxyManagerConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ProxyManagerStore.shared
    @StateObject private var dockerManager = DockerManager.shared
    @StateObject private var configStore = ConfigurationStore.shared

    @State private var status: ContainerStatus = .notCreated
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var npmHosts: [NPMProxyHost] = []
    @State private var selectedNPMHostIDs = Set<Int>()
    @State private var npmMessage: String?

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

                    LabeledContent("NPM Administrator Email") {
                        TextField("", text: $store.settings.adminEmail)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }

                    LabeledContent("NPM Administrator Password") {
                        HoldToRevealPasswordField(
                            placeholder: "",
                            text: $store.settings.adminPassword
                        )
                            .frame(width: 240)
                    }

                    HStack {
                        Button("Test Connection") {
                            Task { await testNPMConnection() }
                        }
                        Button("Load Existing Hosts") {
                            Task { await loadNPMHosts() }
                        }
                        .disabled(isBusy)
                    }

                    LabeledContent("Admin Port") {
                        TextField("", value: $store.settings.adminPort, format: .number.grouping(.never))
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
                            TextField("", value: $store.settings.httpPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }

                        LabeledContent("HTTPS Port") {
                            TextField("", value: $store.settings.httpsPort, format: .number.grouping(.never))
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

                Section("Existing NPM Proxy Hosts") {
                    if npmHosts.isEmpty {
                        Text("Load existing hosts to adopt matching domains into DockAMP servers.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(npmHosts) { host in
                            Toggle(isOn: selectionBinding(for: host.id)) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(host.displayName.isEmpty ? "Host ID \(host.id)" : host.displayName)
                                        Text("\(host.forwardHost):\(host.forwardPort) · \(host.usesSSL ? "HTTPS" : "HTTP") · ID \(host.id)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .toggleStyle(.checkbox)
                        }

                        Button("Adopt Selected Hosts") {
                            adoptSelectedHosts()
                        }
                        .disabled(selectedNPMHostIDs.isEmpty)
                    }

                    if let npmMessage {
                        Text(npmMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

    private func testNPMConnection() async {
        isBusy = true
        defer { isBusy = false }
        do {
            store.save()
            let count = try await NPMProxyService.shared.testConnection(settings: store.settings)
            npmMessage = "NPM connection successful · \(count) Proxy Hosts"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadNPMHosts() async {
        isBusy = true
        defer { isBusy = false }
        do {
            store.save()
            npmHosts = try await NPMProxyService.shared.proxyHosts(settings: store.settings)
            selectedNPMHostIDs = Set(npmHosts.filter { host in
                configStore.configurations.contains { $0.npmProxyHostID == host.id }
            }.map(\.id))
            npmMessage = "Loaded \(npmHosts.count) Proxy Hosts"
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func selectionBinding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { selectedNPMHostIDs.contains(id) },
            set: { selected in
                if selected { selectedNPMHostIDs.insert(id) } else { selectedNPMHostIDs.remove(id) }
            }
        )
    }

    private func adoptSelectedHosts() {
        var adopted = 0
        var unmatched: [String] = []
        for host in npmHosts where selectedNPMHostIDs.contains(host.id) {
            let domains = Set(host.domainNames.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
            let matches = configStore.configurations.filter {
                domains.contains($0.name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }
            guard matches.count == 1, var config = matches.first else {
                unmatched.append(host.displayName.isEmpty ? "ID \(host.id)" : host.displayName)
                continue
            }
            guard (config.npmProxyHostID == nil || config.npmProxyHostID == host.id),
                  !configStore.configurations.contains(where: { $0.id != config.id && $0.npmProxyHostID == host.id }) else {
                unmatched.append(host.displayName.isEmpty ? "ID \(host.id)" : host.displayName)
                continue
            }
            config.npmProxyEnabled = true
            config.npmProxyHostID = host.id
            config.npmProxyStatus = host.usesSSL ? "ssl" : "http"
            config.npmProxyError = ""
            configStore.updateConfiguration(config)
            adopted += 1
        }
        npmMessage = unmatched.isEmpty
            ? "Adopted \(adopted) Proxy Hosts"
            : "Adopted \(adopted). No unique DockAMP server match: \(unmatched.joined(separator: ", "))"
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
