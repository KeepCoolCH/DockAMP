import SwiftUI
import AppKit

extension Notification.Name {
    static let dockAMPShowNewServerSheet = Notification.Name("dockAMPShowNewServerSheet")
}

@main
struct DockAMPApp: App {
    @NSApplicationDelegateAdaptor(DockAMPAppDelegate.self) private var appDelegate
    @StateObject private var dockerManager = DockerManager.shared
    @StateObject private var configStore = ConfigurationStore.shared
    
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .alert("OrbStack or Docker Desktop not found", isPresented: .constant(!dockerManager.isDockerInstalled)) {
                    Button("Download OrbStack") {
                        if let url = URL(string: "https://orbstack.dev/download") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Download Docker Desktop") {
                        if let url = URL(string: "https://www.docker.com/products/docker-desktop") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    Button("Later") {
                    }
                } message: {
                    Text("DockAMP requires OrbStack or Docker Desktop. Please install OrbStack or Docker Desktop for macOS to continue or start OrbStack/Docker Desktop.")
                }
        }
        .defaultSize(width: 1500, height: 980)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Server...") {
                    DockAMPAppDelegate.shared?.showMainWindowMode()
                    NotificationCenter.default.post(name: .dockAMPShowNewServerSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            
            CommandGroup(replacing: .help) {
                Button("DockAMP Help") {
                    if let url = URL(string: "https://github.com/KeepCoolCH/DockAMP") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        MenuBarExtra {
            DockAMPMenuBarView()
        } label: {
            Image(systemName: dockerManager.isGlobalBulkActionRunning ? "arrow.triangle.2.circlepath" : "server.rack")
        }
    }
}

final class DockAMPAppDelegate: NSObject, NSApplicationDelegate {
    static var shared: DockAMPAppDelegate?

    private var windowObservers: [NSObjectProtocol] = []

    static func isMainAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.level == .normal
    }

    override init() {
        super.init()
        DockAMPAppDelegate.shared = self
    }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "NSAutomaticQuoteSubstitutionEnabled")

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        BackupManager.shared.startAutomaticBackups()
        installWindowObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.updateActivationPolicyForWindowState()
        }
    }

    func showMainWindowMode() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installWindowObservers() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification
        ]

        for name in names {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.updateActivationPolicyForWindowState()
            }
            windowObservers.append(observer)
        }
    }

    private func updateActivationPolicyForWindowState() {
        let hasVisibleMainWindow = NSApp.windows.contains { window in
            DockAMPAppDelegate.isMainAppWindow(window) && window.isVisible && !window.isMiniaturized
        }

        let targetPolicy: NSApplication.ActivationPolicy = hasVisibleMainWindow ? .regular : .accessory
        if NSApp.activationPolicy() != targetPolicy {
            NSApp.setActivationPolicy(targetPolicy)
        }
    }
}

private struct DockAMPMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var dockerManager = DockerManager.shared

    @State private var isBulkActionRunning = false
    @State private var bulkActionStatusText = ""
    @State private var bulkActionErrorMessage: String?
    @State private var showBulkActionError = false
    @State private var serverStatuses: [UUID: ContainerStatus] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isBulkActionRunning {
                HStack(spacing: 6) {
                    Text(bulkActionStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }

            Button("Open DockAMP") {
                focusOrOpenMainWindow()
            }

            Divider()

            if configStore.configurations.isEmpty {
                Text("No Servers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(configStore.configurations) { config in
                    Button("\(statusDot(for: serverStatuses[config.id] ?? .notCreated)) \(config.name)") {
                        configStore.selectedConfiguration = config
                        focusOrOpenMainWindow()
                    }
                }
            }

            Divider()

            Button("Start All Servers") {
                Task {
                    await runForAllServers(statusText: "Starting...") { config in
                        try await dockerManager.startStack(config: config)
                    }
                }
            }
            .disabled(isBulkActionRunning || configStore.configurations.isEmpty)

            Button("Restart All Servers") {
                Task {
                    await runForAllServers(statusText: "Restarting...") { config in
                        try await dockerManager.restartStack(config: config)
                    }
                }
            }
            .disabled(isBulkActionRunning || configStore.configurations.isEmpty)

            Button("Stop All Servers") {
                Task {
                    await runForAllServers(statusText: "Stopping...") { config in
                        try await dockerManager.stopStack(config: config)
                    }
                }
            }
            .disabled(isBulkActionRunning || configStore.configurations.isEmpty)

            Divider()

            Button("Quit DockAMP") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 2)
        .alert("Action failed", isPresented: $showBulkActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(bulkActionErrorMessage ?? "Unknown error")
        }
        .task(id: statusRefreshKey) {
            while !Task.isCancelled {
                await refreshServerStatuses()
                try? await Task.sleep(for: .seconds(4))
            }
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

        await refreshServerStatuses()
    }

    private var statusRefreshKey: String {
        configStore.configurations.map { $0.id.uuidString }.joined(separator: "|")
    }

    private func refreshServerStatuses() async {
        var next: [UUID: ContainerStatus] = [:]
        for config in configStore.configurations {
            let status = await dockerManager.getStackStatus(config: config)
            next[config.id] = aggregateStatus(mode: config.databaseAttachmentMode, web: status.web, php: status.php, db: status.db)
        }
        serverStatuses = next
    }

    private func aggregateStatus(
        mode: DatabaseAttachmentMode,
        web: ContainerStatus,
        php: ContainerStatus,
        db: ContainerStatus
    ) -> ContainerStatus {
        if mode == .none {
            if web == .running && php == .running { return .running }
            if web == .error || php == .error { return .error }
            if web == .starting || php == .starting { return .starting }
            if web == .stopping || php == .stopping { return .stopping }
            if web == .notCreated && php == .notCreated { return .notCreated }
            return .stopped
        }

        if web == .running && php == .running && db == .running { return .running }
        if web == .error || php == .error || db == .error { return .error }
        if web == .starting || php == .starting || db == .starting { return .starting }
        if web == .stopping || php == .stopping || db == .stopping { return .stopping }
        if web == .notCreated && php == .notCreated { return .notCreated }
        return .stopped
    }

    private func statusDot(for status: ContainerStatus) -> String {
        switch status {
        case .running:
            return "🟢"
        case .starting, .stopping:
            return "🟠"
        case .error:
            return "🔴"
        case .stopped, .notCreated:
            return "⚪️"
        }
    }

    private func focusOrOpenMainWindow() {
        DockAMPAppDelegate.shared?.showMainWindowMode()

        if let existingWindow = NSApp.windows.first(where: {
            DockAMPAppDelegate.isMainAppWindow($0) && $0.isVisible && !$0.isMiniaturized
        }) {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        openWindow(id: "main")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            DockAMPAppDelegate.shared?.showMainWindowMode()
            if let openedWindow = NSApp.windows.first(where: {
                DockAMPAppDelegate.isMainAppWindow($0) && $0.isVisible && !$0.isMiniaturized
            }) {
                openedWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                openWindow(id: "main")
            }
        }
    }
}
