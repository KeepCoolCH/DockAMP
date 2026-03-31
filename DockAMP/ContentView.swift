import SwiftUI

struct ContentView: View {
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var dockerManager = DockerManager.shared
    @StateObject private var proxyManagerStore = ProxyManagerStore.shared
    @StateObject private var sharedDatabaseStore = SharedDatabaseStore.shared
    
    @State private var selectedConfigId: UUID?
    @State private var showingNewServerSheet = false
    @State private var showingProxyManagerSheet = false
    @State private var isBulkActionRunning = false
    @State private var bulkActionStatusText = ""
    @State private var bulkActionErrorMessage: String?
    @State private var showBulkActionError = false
    @State private var didRunAutoStart = false
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedConfigId) {
                Section("Servers") {
                    ForEach(configStore.configurations) { config in
                        ServerListItemView(configuration: config)
                            .tag(config.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedConfigId = config.id
                                configStore.selectedConfiguration = config
                            }
                            .contextMenu {
                                Button {
                                    duplicateConfiguration(config)
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }

                                Button(role: .destructive) {
                                    deleteConfiguration(config)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteConfigurations)
                }
            }
            .safeAreaInset(edge: .top) {
                Color.clear.frame(height: 8)
            }
            .navigationTitle("DockAMP")
            .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 460)
            .toolbar {
                if isBulkActionRunning {
                    ToolbarItem(placement: .automatic) {
                        HStack(spacing: 6) {
                            Text(bulkActionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button {
                            Task { await startAllServers() }
                        } label: {
                            Label("Start All", systemImage: "play.fill")
                        }
                        .disabled(isBulkActionRunning || configStore.configurations.isEmpty)

                        Button {
                            Task { await restartAllServers() }
                        } label: {
                            Label("Restart All", systemImage: "arrow.clockwise")
                        }
                        .disabled(isBulkActionRunning || configStore.configurations.isEmpty)

                        Button(role: .destructive) {
                            Task { await stopAllServers() }
                        } label: {
                            Label("Stop All", systemImage: "stop.fill")
                        }
                        .disabled(isBulkActionRunning || configStore.configurations.isEmpty)
                    } label: {
                        Label("All Servers", systemImage: "square.stack.3d.up")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingProxyManagerSheet = true
                    } label: {
                        VStack(spacing: 1) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Proxy Manager")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help("Proxy Manager")
                }

                ToolbarItem(placement: .navigation) {
                    Button {
                        showingNewServerSheet = true
                    } label: {
                        Label("New Server", systemImage: "plus")
                    }
                }
            }
            .frame(minWidth: 250)
        } detail: {
            if let selectedConfigId,
               let config = configStore.configurations.first(where: { $0.id == selectedConfigId }) {
                ServerDetailView(configuration: config)
                    .id(config.id)
            } else {
                WelcomeView()
            }
        }
        .sheet(isPresented: $showingNewServerSheet) {
            NewServerSheet()
        }
        .sheet(isPresented: $showingProxyManagerSheet) {
            ProxyManagerConfigView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .alert("Action failed", isPresented: $showBulkActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkActionErrorMessage ?? "Unknown error")
        }
        .onAppear {
            if let firstConfig = configStore.configurations.first {
                selectedConfigId = firstConfig.id
            }

            guard !didRunAutoStart else { return }
            didRunAutoStart = true
            Task {
                let dockerReady = await dockerManager.refreshDockerInstallationStatus()
                guard dockerReady else { return }

                await autoStartProxyManagerIfConfigured()
                await autoStartConfiguredServers()
            }
        }
        .onReceive(configStore.$selectedConfiguration) { selected in
            if let selected {
                selectedConfigId = selected.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dockAMPShowNewServerSheet)) { _ in
            showingNewServerSheet = true
        }
    }
    
    private func deleteConfigurations(at offsets: IndexSet) {
        for index in offsets {
            let config = configStore.configurations[index]
            deleteConfiguration(config)
        }
    }

    private func deleteConfiguration(_ config: ServerConfiguration) {
        Task {
            try? await dockerManager.removeStack(config: config)
        }
        configStore.deleteConfiguration(config)
    }

    private func duplicateConfiguration(_ source: ServerConfiguration) {
        var duplicate = source
        duplicate.id = UUID()
        duplicate.name = source.name + "-1"
        duplicate.createdAt = Date()
        duplicate.updatedAt = Date()

        duplicate.webServerPort = nextAvailableWebPort(startingAt: source.webServerPort)
        if duplicate.databaseAttachmentMode == .dedicated {
            duplicate.databasePort = nextAvailableDedicatedDatabasePort(startingAt: source.databasePort)
        }

        configStore.addConfiguration(duplicate)
        selectedConfigId = duplicate.id
    }

    private func nextAvailableWebPort(startingAt startPort: Int) -> Int {
        let minimumPort = max(1, startPort)
        let usedPorts = Set(configStore.configurations.map { $0.webServerPort })

        var candidate = minimumPort
        while usedPorts.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    private func nextAvailableDedicatedDatabasePort(startingAt startPort: Int) -> Int {
        let minimumPort = max(1, startPort)
        var usedPorts = Set(
            configStore.configurations
                .filter { $0.databaseAttachmentMode == .dedicated }
                .map { $0.databasePort }
        )

        usedPorts.insert(sharedDatabaseStore.settings.databasePort)

        var candidate = minimumPort
        while usedPorts.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    private func startAllServers() async {
        await runForAllServers(statusText: "Starting...") { config in
            try await dockerManager.startStack(config: config)
        }
    }

    private func restartAllServers() async {
        await runForAllServers(statusText: "Restarting...") { config in
            try await dockerManager.restartStack(config: config)
        }
    }

    private func stopAllServers() async {
        await runForAllServers(statusText: "Stopping...") { config in
            try await dockerManager.stopStack(config: config)
        }
    }

    private func runForAllServers(
        statusText: String,
        _ operation: @escaping (ServerConfiguration) async throws -> Void
    ) async {
        guard !isBulkActionRunning else { return }
        let dockerReady = await dockerManager.refreshDockerInstallationStatus()
        guard dockerReady else { return }

        isBulkActionRunning = true
        dockerManager.isGlobalBulkActionRunning = true
        bulkActionStatusText = statusText
        defer {
            isBulkActionRunning = false
            dockerManager.isGlobalBulkActionRunning = false
            bulkActionStatusText = ""
        }

        let configs = configStore.configurations
        for config in configs {
            do {
                try await operation(config)
            } catch {
                bulkActionErrorMessage = "Server '\(config.name)': \(error.localizedDescription)"
                showBulkActionError = true
                break
            }
        }
    }

    private func autoStartConfiguredServers() async {
        let targets = configStore.configurations.filter { $0.autoStartOnAppLaunch }
        for config in targets {
            do {
                let status = await dockerManager.getStackStatus(config: config)
                if isStackAlreadyRunning(config: config, status: status) {
                    continue
                }
                try await dockerManager.startStack(config: config)
            } catch {
                if await waitForStackToBecomeRunning(config: config, timeoutSeconds: 10) {
                    continue
                }

                let status = await dockerManager.getStackStatus(config: config)
                if isStackAlreadyRunning(config: config, status: status) {
                    continue
                }

                let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let details = message.isEmpty ? "Unknown Docker error during auto-start." : message
                bulkActionErrorMessage = "Auto-start failed for '\(config.name)': \(details)"
                showBulkActionError = true
                break
            }
        }
    }

    private func autoStartProxyManagerIfConfigured() async {
        guard dockerManager.isDockerInstalled else { return }
        guard proxyManagerStore.settings.autoStartOnAppLaunch else { return }

        let status = await dockerManager.getProxyManagerStatus()
        if status == .running || status == .starting {
            return
        }

        do {
            try await dockerManager.startProxyManager(settings: proxyManagerStore.settings)
        } catch {
            bulkActionErrorMessage = "Auto-start failed for Proxy Manager: \(error.localizedDescription)"
            showBulkActionError = true
        }
    }

    private func isStackAlreadyRunning(
        config: ServerConfiguration,
        status: (web: ContainerStatus, php: ContainerStatus, db: ContainerStatus)
    ) -> Bool {
        let webAndPHP = status.web == .running && status.php == .running
        switch config.databaseAttachmentMode {
        case .none:
            return webAndPHP
        case .global, .dedicated:
            return webAndPHP && status.db == .running
        }
    }

    private func waitForStackToBecomeRunning(config: ServerConfiguration, timeoutSeconds: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(max(1, timeoutSeconds)))
        while Date() < deadline {
            let status = await dockerManager.getStackStatus(config: config)
            if isStackAlreadyRunning(config: config, status: status) {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 80))
                .foregroundStyle(.secondary)
            
            Text("Welcome to DockAMP")
                .font(.largeTitle)
            
            Text("Manage your web development environments with Docker")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ServerListItemView: View {
    let configuration: ServerConfiguration
    @State private var status: ContainerStatus = .notCreated
    
    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.name)
                    .font(.headline)
                
                Text("\(configuration.webServerType.rawValue) • PHP \(configuration.phpVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: statusTaskKey) {
            while !Task.isCancelled {
                let stackStatus = await DockerManager.shared.getStackStatus(config: configuration)
                status = aggregateStatus(mode: configuration.databaseAttachmentMode, web: stackStatus.web, php: stackStatus.php, db: stackStatus.db)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var statusTaskKey: String {
        [
            configuration.id.uuidString,
            configuration.webContainerName,
            configuration.phpContainerName,
            configuration.dbContainerName,
            configuration.databaseAttachmentMode.rawValue
        ].joined(separator: "|")
    }

    private func aggregateStatus(mode: DatabaseAttachmentMode, web: ContainerStatus, php: ContainerStatus, db: ContainerStatus) -> ContainerStatus {
        if mode == .none {
            if web == .running && php == .running { return .running }
            if web == .error || php == .error { return .error }
            if web == .starting || php == .starting { return .starting }
            if web == .stopping || php == .stopping { return .stopping }
            if web == .notCreated && php == .notCreated { return .notCreated }
            return .stopped
        }

        if web == .running && php == .running && db == .running {
            return .running
        }
        if web == .error || php == .error || db == .error {
            return .error
        }
        if web == .starting || php == .starting || db == .starting {
            return .starting
        }
        if web == .stopping || php == .stopping || db == .stopping {
            return .stopping
        }
        if web == .notCreated && php == .notCreated {
            return .notCreated
        }
        return .stopped
    }
    
    private var statusIcon: String {
        switch status {
        case .running:
            return "circle.fill"
        case .stopped, .notCreated:
            return "circle"
        case .starting, .stopping:
            return "circle.dotted"
        case .error:
            return "exclamationmark.circle"
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .running:
            return .green
        case .stopped, .notCreated:
            return .secondary
        case .starting, .stopping:
            return .orange
        case .error:
            return .red
        }
    }
}

#Preview {
    ContentView()
}
