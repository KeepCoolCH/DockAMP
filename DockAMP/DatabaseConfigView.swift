import SwiftUI

struct DatabaseConfigView: View {
    @ObservedObject var viewModel: ServerViewModel
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var sharedDatabaseStore = SharedDatabaseStore.shared
    @State private var currentRootPassword: String = ""
    @State private var newRootPassword: String = ""
    @State private var isChangingRootPassword: Bool = false
    @State private var rootPasswordChangeMessage: String?
    @State private var showRootPasswordChangeAlert: Bool = false
    @State private var isLaunchingPhpMyAdmin: Bool = false
    
    var body: some View {
        Form {
            Section("Database Mode") {
                Picker("Mode", selection: $viewModel.configuration.databaseAttachmentMode) {
                    ForEach(DatabaseAttachmentMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if viewModel.configuration.databaseAttachmentMode == .global {
                Section("Global Database Container") {
                    Picker("Database", selection: $sharedDatabaseStore.settings.databaseType) {
                        ForEach(DatabaseType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $sharedDatabaseStore.settings.databasePort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)

                        Text(verbatim: "Default: \(sharedDatabaseStore.settings.databaseType.defaultPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Root Password") {
                        HoldToRevealPasswordField(
                            placeholder: "Password",
                            text: $sharedDatabaseStore.settings.databaseSettings.rootPassword
                        )
                            .frame(width: 220)
                    }

                    LabeledContent("CPU Cores (--cpus)") {
                        TextField("e.g. 1.0", text: $sharedDatabaseStore.settings.cpus)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("RAM Limit (--memory)") {
                        TextField("e.g. 1g", text: $sharedDatabaseStore.settings.memoryLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    Text("Container is shared by all servers")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.dbStatus == .running {
                        Divider()

                        LabeledContent("Current Root Password") {
                            HoldToRevealPasswordField(
                                placeholder: "Current password",
                                text: $currentRootPassword
                            )
                            .frame(width: 220)
                        }

                        LabeledContent("New Root Password") {
                            HoldToRevealPasswordField(
                                placeholder: "New password",
                                text: $newRootPassword
                            )
                            .frame(width: 220)
                        }

                        Button {
                            Task {
                                await changeRootPasswordInRunningContainer()
                            }
                        } label: {
                            Label("Change root password in container", systemImage: "key.fill")
                        }
                        .disabled(isChangingRootPassword || currentRootPassword.isEmpty || newRootPassword.isEmpty)
                    }
                }
            }

            if viewModel.configuration.databaseAttachmentMode == .dedicated {
                Section("Dedicated Database Container") {
                    Picker("Database", selection: $viewModel.configuration.databaseType) {
                        ForEach(DatabaseType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $viewModel.configuration.databasePort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)

                        Text(verbatim: "Default: \(viewModel.configuration.databaseType.defaultPort)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Root Password") {
                        HoldToRevealPasswordField(
                            placeholder: "Password",
                            text: $viewModel.configuration.databaseSettings.rootPassword
                        )
                            .frame(width: 220)
                    }

                    LabeledContent("CPU Cores (--cpus)") {
                        TextField("e.g. 1.0", text: $viewModel.configuration.dedicatedDatabaseCPUs)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("RAM Limit (--memory)") {
                        TextField("e.g. 1g", text: $viewModel.configuration.dedicatedDatabaseMemoryLimit)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                    }

                    if viewModel.dbStatus == .running {
                        Divider()

                        LabeledContent("Current Root Password") {
                            HoldToRevealPasswordField(
                                placeholder: "Current password",
                                text: $currentRootPassword
                            )
                            .frame(width: 220)
                        }

                        LabeledContent("New Root Password") {
                            HoldToRevealPasswordField(
                                placeholder: "New password",
                                text: $newRootPassword
                            )
                            .frame(width: 220)
                        }

                        Button {
                            Task {
                                await changeRootPasswordInRunningContainer()
                            }
                        } label: {
                            Label("Change root password in container", systemImage: "key.fill")
                        }
                        .disabled(isChangingRootPassword || currentRootPassword.isEmpty || newRootPassword.isEmpty)
                    }
                }
            }

            if viewModel.configuration.databaseAttachmentMode != .none {
                Section("Database per Server") {
                LabeledContent("Database Name") {
                    TextField("Database name", text: $viewModel.configuration.databaseSettings.databaseName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }

                LabeledContent("Username") {
                    TextField("Username", text: $viewModel.configuration.databaseSettings.username)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }

                LabeledContent("Password") {
                    HoldToRevealPasswordField(
                        placeholder: "Password",
                        text: $viewModel.configuration.databaseSettings.password
                    )
                        .frame(width: 240)
                }

                Text("When this server starts, DB and user are automatically provisioned in the selected database mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            if viewModel.configuration.databaseAttachmentMode != .none {
                Section("Connection Details") {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        ConnectionInfoRow(label: "Host", value: "host.docker.internal")
                        ConnectionInfoRow(label: "Port", value: "\(effectivePort)")
                        ConnectionInfoRow(label: "Database", value: viewModel.configuration.databaseSettings.databaseName)
                        ConnectionInfoRow(label: "Username", value: viewModel.configuration.databaseSettings.username)
                    }
                }
                .padding(.vertical, 4)
            }
            } else {
                Section {
                    Text("No database is enabled for this server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Section {
                Button("Save Changes") {
                    if viewModel.configuration.databaseAttachmentMode == .global {
                        sharedDatabaseStore.save()
                    }
                    viewModel.saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                
                if viewModel.isRunning {
                    Text("⚠️ Server must be restarted for changes to take effect")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            
            if viewModel.configuration.databaseAttachmentMode != .none && viewModel.dbStatus == .running {
                Section("Quick Actions") {
                    Button {
                        openSequelPro()
                    } label: {
                        Label("Open in Sequel Pro/Ace", systemImage: "cylinder.fill")
                    }

                    Button {
                        Task {
                            await openPhpMyAdmin()
                        }
                    } label: {
                        Label("Open in phpMyAdmin", systemImage: "safari")
                    }
                    .disabled(isLaunchingPhpMyAdmin)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("Change Root Password", isPresented: $showRootPasswordChangeAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(rootPasswordChangeMessage ?? "Unknown status")
        }
        .onChange(of: viewModel.configuration.databaseAttachmentMode) { oldValue, newValue in
            guard oldValue != .dedicated, newValue == .dedicated else { return }
            let startPort = suggestedDedicatedDatabaseStartPort(for: viewModel.configuration.databaseType)
            viewModel.configuration.databasePort = nextAvailableDedicatedDatabasePort(startingAt: startPort)
        }
    }

    private var effectivePort: Int {
        switch viewModel.configuration.databaseAttachmentMode {
        case .global:
            return sharedDatabaseStore.settings.databasePort
        case .dedicated:
            return viewModel.configuration.databasePort
        case .none:
            return 0
        }
    }
    
    private func openSequelPro() {
        let db = viewModel.configuration.databaseSettings
        let port = effectivePort

        guard let mysqlURL = buildDatabaseURL(
            scheme: "mysql",
            host: "127.0.0.1",
            username: db.username,
            password: db.password,
            port: port,
            database: db.databaseName
        ) else { return }

        let appURL = findSequelAceAppURL()
        guard let appURL else {
            openMacAppStoreSearch(term: "Sequel Ace")
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.promptsUserIfNeeded = false
        NSWorkspace.shared.open([mysqlURL], withApplicationAt: appURL, configuration: config) { _, _ in }
    }

    @MainActor
    private func openPhpMyAdmin() async {
        guard viewModel.configuration.databaseAttachmentMode != .none else { return }

        switch effectiveDatabaseType {
        case .postgres:
            rootPasswordChangeMessage = "phpMyAdmin only supports MySQL/MariaDB (not PostgreSQL)."
            showRootPasswordChangeAlert = true
            return
        case .mysql, .mariadb:
            break
        }

        isLaunchingPhpMyAdmin = true
        defer { isLaunchingPhpMyAdmin = false }

        do {
            let db = viewModel.configuration.databaseSettings
            let hostPort = try await DockerManager.shared.startPhpMyAdmin(
                host: "host.docker.internal",
                port: effectivePort,
                username: db.username,
                password: db.password
            )
            if let url = URL(string: "http://localhost:\(hostPort)") {
                NSWorkspace.shared.open(url)
            }
        } catch {
            rootPasswordChangeMessage = error.localizedDescription
            showRootPasswordChangeAlert = true
        }
    }

    private var effectiveDatabaseType: DatabaseType {
        switch viewModel.configuration.databaseAttachmentMode {
        case .global:
            return sharedDatabaseStore.settings.databaseType
        case .dedicated:
            return viewModel.configuration.databaseType
        case .none:
            return .mysql
        }
    }

    private func buildDatabaseURL(scheme: String, host: String, username: String, password: String, port: Int, database: String) -> URL? {
        let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
        let encodedPassword = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
        let encodedDatabase = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database
        let urlString = "\(scheme)://\(encodedUser):\(encodedPassword)@\(host):\(port)/\(encodedDatabase)"
        return URL(string: urlString)
    }

    private func findSequelAceAppURL() -> URL? {
        let bundleIDs = [
            "com.sequel-ace.sequel-ace",
            "com.sequel-ace.sequelace",
            "com.sequelpro.sequelpro"
        ]

        for bundleID in bundleIDs {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return appURL
            }
        }

        let home = NSHomeDirectory()
        let candidatePaths = [
            "/Applications/Sequel Ace.app",
            "\(home)/Applications/Sequel Ace.app",
            "/Applications/Sequel Pro.app",
            "\(home)/Applications/Sequel Pro.app"
        ]

        for path in candidatePaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func openMacAppStoreSearch(term: String) {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        if let url = URL(string: "macappstore://itunes.apple.com/search?term=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func suggestedDedicatedDatabaseStartPort(for type: DatabaseType) -> Int {
        switch type {
        case .postgres:
            return 5433
        case .mysql, .mariadb:
            return 3307
        }
    }

    private func nextAvailableDedicatedDatabasePort(startingAt startPort: Int) -> Int {
        let minimumPort = max(1, startPort)

        var usedPorts = Set(
            configStore.configurations
                .filter { $0.id != viewModel.configuration.id && $0.databaseAttachmentMode == .dedicated }
                .map { $0.databasePort }
        )

        usedPorts.insert(sharedDatabaseStore.settings.databasePort)

        var candidate = minimumPort
        while usedPorts.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    @MainActor
    private func changeRootPasswordInRunningContainer() async {
        guard !currentRootPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !newRootPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            rootPasswordChangeMessage = "Please enter current and new root password."
            showRootPasswordChangeAlert = true
            return
        }

        isChangingRootPassword = true
        defer { isChangingRootPassword = false }

        do {
            switch viewModel.configuration.databaseAttachmentMode {
            case .global:
                try await DockerManager.shared.changeSharedDatabaseRootPassword(
                    currentPassword: currentRootPassword,
                    newPassword: newRootPassword
                )
                sharedDatabaseStore.settings.databaseSettings.rootPassword = newRootPassword
                sharedDatabaseStore.save()
            case .dedicated:
                try await DockerManager.shared.changeDedicatedDatabaseRootPassword(
                    config: viewModel.configuration,
                    currentPassword: currentRootPassword,
                    newPassword: newRootPassword
                )
                viewModel.configuration.databaseSettings.rootPassword = newRootPassword
                viewModel.saveConfiguration()
            case .none:
                rootPasswordChangeMessage = "No database is enabled for this server."
                showRootPasswordChangeAlert = true
                return
            }

            currentRootPassword = ""
            newRootPassword = ""
            rootPasswordChangeMessage = "Root password was changed in the running container. Data is preserved."
            showRootPasswordChangeAlert = true
        } catch {
            rootPasswordChangeMessage = error.localizedDescription
            showRootPasswordChangeAlert = true
        }
    }
}

struct ConnectionInfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.medium)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy")
        }
    }
}

#Preview {
    DatabaseConfigView(viewModel: ServerViewModel(configuration: ServerConfiguration()))
}
