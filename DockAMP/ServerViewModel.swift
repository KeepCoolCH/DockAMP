import Foundation
import SwiftUI
import Combine

@MainActor
class ServerViewModel: ObservableObject {
    @Published var configuration: ServerConfiguration
    @Published var webStatus: ContainerStatus = .notCreated
    @Published var phpStatus: ContainerStatus = .notCreated
    @Published var dbStatus: ContainerStatus = .notCreated
    
    @Published var isStarting = false
    @Published var isStopping = false
    @Published var isUpdating = false
    @Published var isResettingWebStack = false
    @Published var isFixingPermissions = false
    @Published var isProxySyncing = false
    
    @Published var errorMessage: String?
    @Published var showError = false
    
    @Published var logs: String = ""

    private var lastHealthyStatusAt: Date?
    private let transientStatusGraceInterval: TimeInterval = 2.5
    
    private let dockerManager = DockerManager.shared
    private let configStore = ConfigurationStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var lastContainerBaseName: String
    
    var isRunning: Bool {
        let webAndPHPRunning = webStatus == .running && phpStatus == .running
        if configuration.databaseAttachmentMode == .none {
            return webAndPHPRunning
        }
        return webAndPHPRunning && dbStatus == .running
    }
    
    var statusText: String {
        let inLifecycleAction = isStarting || isStopping || isUpdating || isResettingWebStack
        let withinGraceWindow: Bool = {
            guard let lastHealthyStatusAt else { return false }
            return Date().timeIntervalSince(lastHealthyStatusAt) <= transientStatusGraceInterval
        }()

        if isRunning || (!inLifecycleAction && withinGraceWindow) {
            return "Server running"
        } else if webStatus == .notCreated && phpStatus == .notCreated && dbStatus == .notCreated {
            return "Server not started"
        } else {
            return "Partially running"
        }
    }
    
    init(configuration: ServerConfiguration) {
        self.configuration = configuration
        self.lastContainerBaseName = configuration.name

        $configuration
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] updatedConfig in
                guard let self else { return }
                self.configStore.updateConfiguration(updatedConfig)
            }
            .store(in: &cancellables)
        
        Task {
            await refreshStatus()
        }
    }
    
    // MARK: - Actions
    
    func startServer() async {
        guard !isStarting else { return }
        
        isStarting = true
        errorMessage = nil
        
        do {
            try await dockerManager.startStack(config: configuration)
            
            try await Task.sleep(for: .seconds(3))
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isStarting = false
    }
    
    func stopServer() async {
        guard !isStopping else { return }
        
        isStopping = true
        errorMessage = nil
        
        do {
            try await dockerManager.stopStack(config: configuration)
            
            try await Task.sleep(for: .seconds(2))
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isStopping = false
    }
    
    func restartServer() async {
        guard !isStarting && !isStopping else { return }

        isStarting = true
        errorMessage = nil

        do {
            try await dockerManager.restartStack(config: configuration)
            try await Task.sleep(for: .seconds(2))
            await refreshStatus()

            if !isRunning {
                try await dockerManager.startStack(config: configuration)
                try await Task.sleep(for: .seconds(2))
                await refreshStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isStarting = false
    }
    
    func updateImages() async {
        guard !isUpdating else { return }
        
        isUpdating = true
        errorMessage = nil
        
        do {
            try await dockerManager.updateImages(config: configuration)
            
            if isRunning {
                await restartServer()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        
        isUpdating = false
    }

    func resetWebStack() async {
        guard !isResettingWebStack else { return }

        isResettingWebStack = true
        errorMessage = nil

        do {
            try await dockerManager.resetWebAndPHPContainers(config: configuration)
            try await Task.sleep(for: .seconds(2))
            await refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isResettingWebStack = false
    }
    
    func refreshStatus() async {
        let status = await dockerManager.getStackStatus(config: configuration)
        webStatus = status.web
        phpStatus = status.php
        dbStatus = status.db

        let webAndPHPRunning = webStatus == .running && phpStatus == .running
        let stackIsHealthy: Bool
        if configuration.databaseAttachmentMode == .none {
            stackIsHealthy = webAndPHPRunning
        } else {
            stackIsHealthy = webAndPHPRunning && dbStatus == .running
        }

        if stackIsHealthy {
            lastHealthyStatusAt = Date()
        }
    }
    
    func loadLogs(for container: String) async {
        do {
            logs = try await dockerManager.getContainerLogs(container)
        } catch {
            logs = "Failed to load logs: \(error.localizedDescription)"
        }
    }
    
    func saveConfiguration() {
        configStore.updateConfiguration(configuration)
    }

    func saveServerNameAndRenameContainers() async {
        let trimmedName = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Server name cannot be empty."
            showError = true
            return
        }

        let updatedConfig = {
            var config = configuration
            config.name = trimmedName
            return config
        }()

        guard let existingConfig = configStore.configurations.first(where: { $0.id == configuration.id }) else {
            configuration = updatedConfig
            configStore.updateConfiguration(updatedConfig)
            lastContainerBaseName = updatedConfig.name
            return
        }

        let renameSourceConfig = {
            var config = existingConfig
            config.name = lastContainerBaseName
            return config
        }()
        let nameChanged = renameSourceConfig.name != updatedConfig.name
        let wasRunning = isRunning

        do {
            if nameChanged {
                try await dockerManager.renameStackContainers(oldConfig: renameSourceConfig, newConfig: updatedConfig)
            }
            configuration = updatedConfig
            configStore.updateConfiguration(updatedConfig)
            lastContainerBaseName = updatedConfig.name
            if nameChanged && wasRunning {
                await restartServer()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func fixDocumentRootPermissions() async {
        guard !isFixingPermissions else { return }
        isFixingPermissions = true
        errorMessage = nil

        do {
            try await dockerManager.fixDocumentRootPermissions(path: configuration.webServerDocumentRoot)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }

        isFixingPermissions = false
    }

    func syncNPMProxyHost() async {
        guard !isProxySyncing else { return }
        isProxySyncing = true
        defer { isProxySyncing = false }
        do {
            if !configuration.npmProxyEnabled {
                if let hostID = configuration.npmProxyHostID {
                    try await NPMProxyService.shared.deleteManagedHost(id: hostID, settings: ProxyManagerStore.shared.settings)
                }
                configuration.npmProxyHostID = nil
                configuration.npmProxyStatus = "disabled"
                configuration.npmProxyError = ""
                configStore.updateConfiguration(configuration)
                return
            }
            let result = try await NPMProxyService.shared.syncProxyHost(
                for: configuration,
                settings: ProxyManagerStore.shared.settings
            )
            configuration.npmProxyHostID = result.hostID
            configuration.npmProxyStatus = result.status
            configuration.npmProxyError = result.certificateError
            configStore.updateConfiguration(configuration)
        } catch {
            configuration.npmProxyStatus = "error"
            configuration.npmProxyError = error.localizedDescription
            configStore.updateConfiguration(configuration)
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    func adoptExistingNPMProxyHost() async {
        guard !isProxySyncing else { return }
        isProxySyncing = true
        defer { isProxySyncing = false }
        do {
            let result = try await NPMProxyService.shared.adoptExistingHost(
                for: configuration,
                settings: ProxyManagerStore.shared.settings
            )
            configuration.npmProxyEnabled = true
            configuration.npmProxyHostID = result.hostID
            configuration.npmProxyStatus = result.status
            configuration.npmProxyError = ""
            configStore.updateConfiguration(configuration)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
    
    func openInBrowser() {
        let urlString = "http://localhost:\(configuration.webServerPort)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

}
