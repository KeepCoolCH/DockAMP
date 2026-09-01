import SwiftUI

struct LogsTabView: View {
    @ObservedObject var viewModel: ServerViewModel
    @State private var selectedContainer: LogContainer = .web
    @State private var isLoading = false
    @State private var autoRefresh = false
    
    enum LogContainer: String, CaseIterable {
        case web = "Web Server"
        case php = "PHP"
        case database = "Database"
        
        func containerName(for config: ServerConfiguration) -> String {
            switch self {
            case .web:
                return config.primaryContainerName
            case .php:
                return config.phpContainerName
            case .database:
                switch config.databaseAttachmentMode {
                case .global:
                    return DockerManager.sharedDatabaseContainerName
                case .dedicated:
                    return config.dbContainerName
                case .none:
                    return ""
                }
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Container", selection: $selectedContainer) {
                    ForEach(availableContainers, id: \.self) { container in
                        Text(container == .web && viewModel.configuration.serverType.isAppServer ? viewModel.configuration.serverType.rawValue : container.rawValue).tag(container)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                
                Spacer()
                
                Toggle("Auto-Refresh", isOn: $autoRefresh)
                
                Button {
                    loadLogs()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                
                Button {
                    viewModel.logs = ""
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .padding()
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    if viewModel.logs.isEmpty {
                        ContentUnavailableView(
                            "No logs available",
                            systemImage: "doc.text",
                            description: Text("Click 'Refresh' to load logs")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(viewModel.logs)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("bottom")
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: viewModel.logs) { oldValue, newValue in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
        .onAppear {
            loadLogs()
        }
        .onChange(of: selectedContainer) { oldValue, newValue in
            loadLogs()
        }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            
            while autoRefresh && !Task.isCancelled {
                loadLogs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var availableContainers: [LogContainer] {
        var result: [LogContainer] = [.web]
        if viewModel.configuration.serverType == .php { result.append(.php) }
        if viewModel.configuration.databaseAttachmentMode != .none { result.append(.database) }
        return result
    }
    
    private func loadLogs() {
        if selectedContainer == .database && viewModel.configuration.databaseAttachmentMode == .none {
            viewModel.logs = "No database is enabled for this server."
            isLoading = false
            return
        }

        isLoading = true
        
        Task {
            let containerName = selectedContainer.containerName(for: viewModel.configuration)
            await viewModel.loadLogs(for: containerName)
            isLoading = false
        }
    }

}

#Preview {
    LogsTabView(viewModel: ServerViewModel(configuration: ServerConfiguration()))
}
