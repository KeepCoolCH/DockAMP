import SwiftUI

struct ServerDetailView: View {
    let configuration: ServerConfiguration
    
    @StateObject private var viewModel: ServerViewModel
    @State private var selectedTab: DetailTab = .overview
    
    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        _viewModel = StateObject(wrappedValue: ServerViewModel(configuration: configuration))
    }
    
    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case webserver = "Web Server"
        case php = "PHP"
        case database = "Database"
        case logs = "Logs"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ServerControlsView(viewModel: viewModel)
                .padding()
                .background(.ultraThinMaterial)
            
            Divider()
            
            Picker("View", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            ScrollView {
                switch selectedTab {
                case .overview:
                    OverviewTabView(viewModel: viewModel)
                case .webserver:
                    WebServerConfigView(viewModel: viewModel)
                case .php:
                    PHPConfigView(viewModel: viewModel)
                case .database:
                    DatabaseConfigView(viewModel: viewModel)
                case .logs:
                    LogsTabView(viewModel: viewModel)
                }
            }
        }
        .navigationTitle(configuration.name)
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {
                viewModel.showError = false
            }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .task(id: viewModel.configuration.id) {
            while !Task.isCancelled {
                await viewModel.refreshStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

// MARK: - Server Controls

struct ServerControlsView: View {
    @ObservedObject var viewModel: ServerViewModel

    @MainActor
    private func commitPendingEdits() {
        NSApp.mainWindow?.endEditing(for: nil)
        NSApp.keyWindow?.endEditing(for: nil)
    }

    private func commitPendingEditsAndWait() async {
        commitPendingEdits()
        try? await Task.sleep(for: .milliseconds(120))
    }

    private var liveProcessText: String {
        if viewModel.isResettingWebStack {
            return "Resetting..."
        }
        if viewModel.isUpdating {
            return "Updating..."
        }
        if viewModel.isStopping {
            return "Stopping..."
        }
        if viewModel.isStarting {
            return "Starting..."
        }
        return "Running..."
    }
    
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Circle()
                        .fill(viewModel.isRunning ? Color.green : Color.secondary)
                        .frame(width: 12, height: 12)
                    
                    Text(viewModel.statusText)
                        .font(.headline)
                }
                
                if viewModel.isRunning {
                    Text(verbatim: "Port: \(viewModel.configuration.webServerPort)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }
            
            Spacer()
            
            HStack(spacing: 12) {
                if viewModel.isStarting || viewModel.isStopping || viewModel.isUpdating || viewModel.isResettingWebStack {
                    Text(liveProcessText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ProgressView()
                        .scaleEffect(0.8)
                }

                if viewModel.isRunning {
                    Button {
                        viewModel.openInBrowser()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    
                    Button {
                        Task {
                            await commitPendingEditsAndWait()
                            await viewModel.restartServer()
                        }
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isStarting || viewModel.isStopping)
                    
                    Button(role: .destructive) {
                        Task {
                            await commitPendingEditsAndWait()
                            await viewModel.stopServer()
                        }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .disabled(viewModel.isStopping)
                } else {
                    Button {
                        Task {
                            await commitPendingEditsAndWait()
                            await viewModel.startServer()
                        }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .disabled(viewModel.isStarting)
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    Task {
                        await commitPendingEditsAndWait()
                        await viewModel.resetWebStack()
                    }
                } label: {
                    Label("Reset Web/PHP", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isResettingWebStack)

                Toggle("Auto-Start", isOn: $viewModel.configuration.autoStartOnAppLaunch)
                    .help("Automatically start server when app opens")
            }
        }
    }
}

// MARK: - Overview Tab

struct OverviewTabView: View {
    @ObservedObject var viewModel: ServerViewModel
    @StateObject private var sharedDatabaseStore = SharedDatabaseStore.shared
    @State private var draftServerName: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            GroupBox("Server Name") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Server name", text: $draftServerName)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Spacer()
                        Button("Save Name") {
                            Task {
                                viewModel.configuration.name = draftServerName
                                await viewModel.saveServerNameAndRenameContainers()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftServerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if viewModel.isRunning {
                        Text("⚠️ Renamed servers may require restart/rebuild for running containers.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(8)
            }
            .padding(.horizontal)

            HStack(spacing: 16) {
                ContainerStatusCard(
                    title: "Web Server",
                    type: viewModel.configuration.webServerType.rawValue,
                    status: viewModel.webStatus,
                    icon: "server.rack"
                )
                
                ContainerStatusCard(
                    title: "PHP",
                    type: "Version \(viewModel.configuration.phpVersion)",
                    status: viewModel.phpStatus,
                    icon: "chevron.left.forwardslash.chevron.right"
                )
                
                ContainerStatusCard(
                    title: "Database",
                    type: databaseTypeLabel,
                    status: viewModel.dbStatus,
                    icon: "cylinder.fill"
                )
            }
            .padding(.horizontal)
            
            GroupBox("Quick Overview") {
                VStack(spacing: 12) {
                    InfoRow(label: "Server Name", value: viewModel.configuration.name)
                    Divider()
                    InfoRow(label: "Web Server Port", value: "\(viewModel.configuration.webServerPort)")
                    Divider()
                    InfoRow(label: "Database Port", value: databasePortLabel)
                    Divider()
                    InfoRow(label: "Document Root", value: viewModel.configuration.webServerDocumentRoot)
                }
                .padding(8)
            }
            .padding(.horizontal)
            
            Spacer()
        }
        .padding(.vertical)
        .onAppear {
            draftServerName = viewModel.configuration.name
        }
        .onChange(of: viewModel.configuration.id) { _, _ in
            draftServerName = viewModel.configuration.name
        }
    }

    private var databaseTypeLabel: String {
        switch viewModel.configuration.databaseAttachmentMode {
        case .none:
            return "None"
        case .global:
            return "\(sharedDatabaseStore.settings.databaseType.rawValue) (global)"
        case .dedicated:
            return "\(viewModel.configuration.databaseType.rawValue) (dedicated)"
        }
    }

    private var databasePortLabel: String {
        switch viewModel.configuration.databaseAttachmentMode {
        case .none:
            return "-"
        case .global:
            return "\(sharedDatabaseStore.settings.databasePort)"
        case .dedicated:
            return "\(viewModel.configuration.databasePort)"
        }
    }
}

struct ContainerStatusCard: View {
    let title: String
    let type: String
    let status: ContainerStatus
    let icon: String
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(statusColor)
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                
                Text(type)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                Text(statusText)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
    
    private var statusText: String {
        switch status {
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        case .notCreated:
            return "Not created"
        case .starting:
            return "Starting..."
        case .stopping:
            return "Stopping..."
        case .error:
            return "Error"
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    ServerDetailView(configuration: ServerConfiguration(name: "Test Server"))
}
