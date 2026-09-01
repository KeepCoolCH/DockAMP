import SwiftUI

struct NewServerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var phpVersionStore = PHPVersionStore.shared
    
    @State private var serverName = ""
    @State private var serverType: ServerType = .php
    @State private var webServerType: WebServerType = .nginx
    @State private var phpVersion: String = PHPVersionCatalog.defaultVersion
    @State private var webPort = 8081
    @State private var documentRoot = NSHomeDirectory() + "/Sites"
    @State private var pythonVersion = "3.13"
    @State private var pythonFramework: PythonFramework = .generic
    @State private var pythonContainerPort = 8000
    @State private var pythonStartCommand = "python app.py"
    @State private var pythonRequirements = ""
    @State private var nodeVersion = "22"
    @State private var nodeFramework: NodeFramework = .generic
    @State private var nodeContainerPort = 3000
    @State private var nodeStartCommand = "npm start"
    @State private var nodeInstallCommand = "npm install"
    @State private var npmProxyEnabled = true
    @State private var mountRows: [MountRowEntry] = []
    @State private var databaseMode: DatabaseAttachmentMode = .global
    @State private var databaseType: DatabaseType = .mysql
    @State private var databasePort = 3307
    @State private var databaseRootPassword = "root"
    @State private var databaseName = ""
    @State private var databaseUsername = ""
    @State private var databasePassword = "devpassword"
    @State private var didEditDatabaseName = false
    @State private var didEditDatabaseUsername = false
    @State private var showingContainerPathBrowser = false
    @State private var containerPathBrowserMountID: UUID?
    @State private var containerBrowserPath = "/"
    @State private var containerBrowserListing: ContainerDirectoryListing?
    @State private var isLoadingContainerBrowser = false
    @State private var containerBrowserError: String?
    @State private var isCreating = false
    @State private var createdConfiguration: ServerConfiguration?
    @State private var creationError: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Server Name") {
                    TextField("Name", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Server Type") {
                    Picker("Type", selection: $serverType) {
                        ForEach(ServerType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Automatically manage Proxy Host in NPM", isOn: $npmProxyEnabled)
                }
                
                if serverType == .php {
                    Section("Web Server") {
                    Picker("Type", selection: $webServerType) {
                        ForEach(WebServerType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("", value: $webPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }
                
                    Section("PHP") {
                        Picker("Version", selection: $phpVersion) {
                            ForEach(availablePHPVersions, id: \.self) { version in
                                Text("PHP \(version)").tag(version)
                            }
                        }
                    }
                } else if serverType == .python {
                    Section("Python") {
                        Picker("Version", selection: $pythonVersion) {
                            ForEach(["3.13", "3.12", "3.11", "3.10", "3.9"], id: \.self) { version in
                                Text("Python \(version)").tag(version)
                            }
                        }
                        Picker("Framework", selection: $pythonFramework) {
                            ForEach(PythonFramework.allCases) { framework in
                                Text(framework.displayName).tag(framework)
                            }
                        }
                        .onChange(of: pythonFramework) { oldValue, newValue in
                            applyPythonFrameworkDefaults(from: oldValue, to: newValue)
                        }
                        LabeledContent("Internal Port") {
                            TextField("", value: $pythonContainerPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        LabeledContent("Host Port") {
                            TextField("", value: $webPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        LabeledContent("Start Command") {
                            TextField("python app.py", text: $pythonStartCommand)
                                .textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                        LabeledContent("Requirements") {
                            TextEditor(text: $pythonRequirements)
                                .font(.system(.body, design: .monospaced)).frame(width: 260, height: 70)
                        }
                    }
                } else {
                    Section("Node.js") {
                        Picker("Version", selection: $nodeVersion) {
                            ForEach(["24", "22", "20", "18"], id: \.self) { version in
                                Text("Node.js \(version)").tag(version)
                            }
                        }
                        Picker("Framework", selection: $nodeFramework) {
                            ForEach(NodeFramework.allCases) { framework in
                                Text(framework.displayName).tag(framework)
                            }
                        }
                        .onChange(of: nodeFramework) { oldValue, newValue in
                            applyNodeFrameworkDefaults(from: oldValue, to: newValue)
                        }
                        LabeledContent("Internal Port") {
                            TextField("", value: $nodeContainerPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        LabeledContent("Host Port") {
                            TextField("", value: $webPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder).frame(width: 100)
                        }
                        LabeledContent("Start Command") {
                            TextField("npm start", text: $nodeStartCommand)
                                .textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                        LabeledContent("Install Command") {
                            TextField("npm install", text: $nodeInstallCommand)
                                .textFieldStyle(.roundedBorder).frame(width: 260)
                        }
                    }
                }

                Section("Database Mode") {
                    Picker("Mode", selection: $databaseMode) {
                        ForEach(DatabaseAttachmentMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if databaseMode == .dedicated {
                    Section("Dedicated Database Container") {
                        Picker("Database", selection: $databaseType) {
                            ForEach(DatabaseType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("", value: $databasePort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                        }

                        LabeledContent("Root Password") {
                            HoldToRevealPasswordField(
                                placeholder: "Password",
                                text: $databaseRootPassword
                            )
                                .frame(width: 220)
                        }
                    }
                }

                Section("Document Root") {
                    HStack {
                        TextField("Path", text: $documentRoot)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Choose...") {
                            selectDocumentRoot()
                        }
                    }

                    Text(serverType == .php ? "Additional bind mounts for Web + PHP containers" : "Additional bind mounts for the app container")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if mountRows.isEmpty {
                        Text("No additional mounts configured.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ForEach($mountRows) { $row in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Host Path")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("/Users/.../ordner", text: $row.hostPath)
                                    .textFieldStyle(.roundedBorder)

                                Button {
                                    selectAdditionalMountHostPath(row.id)
                                } label: {
                                    Label("Choose...", systemImage: "folder")
                                }
                            }

                            Text("Container Path")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                TextField("/var/www/ordner", text: $row.containerPath)
                                    .textFieldStyle(.roundedBorder)

                                Button {
                                    openContainerPathBrowser(for: row.id, currentPath: row.containerPath)
                                } label: {
                                    Label("Browse...", systemImage: "shippingbox")
                                }
                            }

                            HStack {
                                Toggle("Read only (ro)", isOn: $row.readOnly)
                                    .toggleStyle(.switch)
                                    .help("Block write access inside container")
                                Spacer()
                                Button(role: .destructive) {
                                    removeMountRow(row.id)
                                } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Button {
                        addMountRow()
                    } label: {
                        Label("Add Mount", systemImage: "plus.circle")
                    }
                }

                if databaseMode != .none {
                    Section("Database (per server)") {
                        LabeledContent("Database Name") {
                            TextField("Database name", text: $databaseName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onChange(of: databaseName) { _, _ in
                                    didEditDatabaseName = true
                                }
                        }

                        LabeledContent("Username") {
                            TextField("Username", text: $databaseUsername)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                                .onChange(of: databaseUsername) { _, _ in
                                    didEditDatabaseUsername = true
                                }
                        }

                        LabeledContent("Password") {
                            HoldToRevealPasswordField(
                                placeholder: "Password",
                                text: $databasePassword
                            )
                                .frame(width: 220)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button(createdConfiguration == nil ? "Create" : "Retry Start") {
                        Task { await createAndStartServer() }
                    }
                    .disabled(
                        isCreating
                            || serverName.isEmpty
                            || (databaseMode != .none && (databaseName.isEmpty || databaseUsername.isEmpty))
                    )
                }
            }
        }
        .frame(width: 500, height: 600)
        .onAppear {
            webPort = nextAvailableWebPort(startingAt: webPort)
            applyDatabaseDefaultsIfNeeded(for: serverName)
        }
        .onChange(of: serverName) { _, newValue in
            applyDatabaseDefaultsIfNeeded(for: newValue)
        }
        .task {
            await phpVersionStore.refreshIfNeeded()
        }
        .sheet(isPresented: $showingContainerPathBrowser) {
            containerPathBrowserSheet
        }
        .alert("Server Could Not Start", isPresented: Binding(
            get: { creationError != nil },
            set: { if !$0 { creationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(creationError ?? "Unknown error")
        }
    }

    private var containerPathBrowserSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Container Path Browser")
                        .font(.title2.bold())
                    Text("\(serverType.rawValue) container filesystem")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel") {
                    showingContainerPathBrowser = false
                }

                Button("Use Path") {
                    applySelectedContainerPath()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("Path", text: $containerBrowserPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            Task { await loadContainerDirectories(path: containerBrowserPath) }
                        }

                    Button {
                        Task { await loadContainerDirectories(path: containerBrowserPath) }
                    } label: {
                        Label("Go", systemImage: "arrow.right.circle")
                    }
                    .disabled(isLoadingContainerBrowser)
                }

                HStack {
                    Button {
                        if let parent = containerBrowserListing?.parent {
                            Task { await loadContainerDirectories(path: parent) }
                        }
                    } label: {
                        Label("Parent", systemImage: "arrow.up")
                    }
                    .disabled(containerBrowserListing?.parent == nil || isLoadingContainerBrowser)

                    Button {
                        Task { await loadContainerDirectories(path: "/") }
                    } label: {
                        Label("Root", systemImage: "house")
                    }
                    .disabled(isLoadingContainerBrowser)

                    Spacer()

                    if isLoadingContainerBrowser {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let containerBrowserError {
                    Label(containerBrowserError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                List {
                    ForEach(containerBrowserListing?.directories ?? [], id: \.self) { directory in
                        Button {
                            Task { await loadContainerDirectories(path: joinedContainerPath(containerBrowserPath, directory)) }
                        } label: {
                            Label(directory, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(minHeight: 300)
                .overlay {
                    if !isLoadingContainerBrowser && (containerBrowserListing?.directories ?? []).isEmpty {
                        ContentUnavailableView(
                            "No subdirectories",
                            systemImage: "folder",
                            description: Text("Use this path or type another absolute container path.")
                        )
                    }
                }

                Text("DockAMP uses the selected webserver image as a temporary helper while this server has not been created yet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .frame(minWidth: 620, minHeight: 520)
    }
    
    @MainActor
    private func createAndStartServer() async {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        defer { isCreating = false }

        if let createdConfiguration {
            do {
                try await DockerManager.shared.startStack(config: createdConfiguration)
                dismiss()
            } catch {
                creationError = error.localizedDescription
            }
            return
        }

        let resolvedWebPort = nextAvailableWebPort(startingAt: webPort)

        var config = ServerConfiguration(name: serverName)
        config.serverType = serverType
        config.webServerType = webServerType
        config.phpVersion = phpVersion
        config.webServerPort = resolvedWebPort
        config.webServerDocumentRoot = documentRoot
        config.additionalContainerMounts = serializeMountRows(mountRows)
        config.pythonSettings.version = pythonVersion
        config.pythonSettings.framework = pythonFramework
        config.pythonSettings.containerPort = pythonContainerPort
        config.pythonSettings.startCommand = pythonStartCommand
        config.pythonSettings.requirements = pythonRequirements
        config.nodeSettings.version = nodeVersion
        config.nodeSettings.framework = nodeFramework
        config.nodeSettings.containerPort = nodeContainerPort
        config.nodeSettings.startCommand = nodeStartCommand
        config.nodeSettings.installCommand = nodeInstallCommand
        config.npmProxyEnabled = npmProxyEnabled
        config.npmProxyStatus = npmProxyEnabled ? "not_created" : "disabled"
        config.databaseAttachmentMode = databaseMode
        if databaseMode == .dedicated {
            config.databaseType = databaseType
            config.databasePort = databasePort
            config.databaseSettings.rootPassword = databaseRootPassword
        }
        config.databaseSettings.databaseName = databaseName
        config.databaseSettings.username = databaseUsername
        config.databaseSettings.password = databasePassword

        webPort = resolvedWebPort
        do {
            try DockerManager.shared.initializeDefaultProjectFiles(for: config)
            configStore.addConfiguration(config)
            createdConfiguration = config
            try await DockerManager.shared.startStack(config: config)
            dismiss()
        } catch {
            creationError = error.localizedDescription
        }
    }
    
    private func selectDocumentRoot() {
        selectFolder(message: "Select the document root directory") { url in
            documentRoot = url.path
        }
    }

    private func applyPythonFrameworkDefaults(from oldValue: PythonFramework, to newValue: PythonFramework) {
        let knownCommands = Set(PythonFramework.allCases.map(\.startCommand))
        let knownRequirements = Set(PythonFramework.allCases.map(\.suggestedRequirements) + ["fastapi\nuvicorn"])
        if pythonStartCommand.isEmpty || knownCommands.contains(pythonStartCommand) || pythonStartCommand == oldValue.startCommand {
            pythonStartCommand = newValue.startCommand
        }
        if pythonRequirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || knownRequirements.contains(pythonRequirements)
            || pythonRequirements == oldValue.suggestedRequirements {
            pythonRequirements = newValue.suggestedRequirements
        }
        pythonContainerPort = newValue.containerPort
    }

    private func applyNodeFrameworkDefaults(from oldValue: NodeFramework, to newValue: NodeFramework) {
        let knownCommands = Set(NodeFramework.allCases.map(\.startCommand))
        let knownInstalls = Set(NodeFramework.allCases.map(\.installCommand))
        if nodeStartCommand.isEmpty || knownCommands.contains(nodeStartCommand) || nodeStartCommand == oldValue.startCommand {
            nodeStartCommand = newValue.startCommand
        }
        if nodeInstallCommand.isEmpty || knownInstalls.contains(nodeInstallCommand) || nodeInstallCommand == oldValue.installCommand {
            nodeInstallCommand = newValue.installCommand
        }
        nodeContainerPort = newValue.containerPort
    }

    private func selectAdditionalMountHostPath(_ id: UUID) {
        selectFolder(message: "Select an additional host directory") { url in
            guard let index = mountRows.firstIndex(where: { $0.id == id }) else { return }
            mountRows[index].hostPath = url.path
        }
    }

    private func selectFolder(message: String, onSelect: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = message

        if panel.runModal() == .OK, let url = panel.url {
            onSelect(url)
        }
    }

    private func openContainerPathBrowser(for id: UUID, currentPath: String) {
        containerPathBrowserMountID = id
        containerBrowserPath = currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultContainerRootPath : currentPath
        containerBrowserListing = nil
        containerBrowserError = nil
        showingContainerPathBrowser = true

        Task {
            await loadContainerDirectories(path: containerBrowserPath)
        }
    }

    private var defaultContainerRootPath: String {
        if serverType.isAppServer { return "/app" }
        switch webServerType {
        case .apache:
            return "/usr/local/apache2"
        case .nginx:
            return "/var/www"
        }
    }

    private func loadContainerDirectories(path: String) async {
        isLoadingContainerBrowser = true
        containerBrowserError = nil
        defer { isLoadingContainerBrowser = false }

        do {
            var config = ServerConfiguration(name: serverName.isEmpty ? "new-server" : serverName)
            config.serverType = serverType
            config.webServerType = webServerType
            config.webServerDocumentRoot = documentRoot
            let listing = try await DockerManager.shared.containerDirectories(for: config, path: path)
            containerBrowserListing = listing
            containerBrowserPath = listing.path
        } catch {
            containerBrowserError = error.localizedDescription
        }
    }

    private func applySelectedContainerPath() {
        guard let id = containerPathBrowserMountID,
              let index = mountRows.firstIndex(where: { $0.id == id }) else {
            showingContainerPathBrowser = false
            return
        }

        mountRows[index].containerPath = containerBrowserPath
        showingContainerPathBrowser = false
    }

    private func joinedContainerPath(_ base: String, _ child: String) -> String {
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedBase.isEmpty {
            return "/\(trimmedChild)"
        }
        return "/\(trimmedBase)/\(trimmedChild)"
    }

    private func addMountRow() {
        mountRows.append(MountRowEntry())
    }

    private func removeMountRow(_ id: UUID) {
        mountRows.removeAll { $0.id == id }
    }

    private func serializeMountRows(_ rows: [MountRowEntry]) -> String {
        rows
            .map { row -> String? in
                let host = row.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let container = row.containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !container.isEmpty else { return nil }
                return row.readOnly ? "\(host):\(container):ro" : "\(host):\(container)"
            }
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func applyDatabaseDefaultsIfNeeded(for name: String) {
        let slug = slugify(name)
        guard !slug.isEmpty else { return }

        if !didEditDatabaseName || databaseName.isEmpty {
            databaseName = "\(slug)_db"
        }
        if !didEditDatabaseUsername || databaseUsername.isEmpty {
            databaseUsername = "\(slug)_user"
        }
    }

    private func slugify(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = CharacterSet.alphanumerics
        let mapped = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let raw = String(mapped)
        let collapsed = raw.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func nextAvailableWebPort(startingAt startPort: Int) -> Int {
        let minimumPort = max(8081, startPort)
        let usedPorts = Set(configStore.configurations.map { $0.webServerPort })

        var candidate = minimumPort
        while usedPorts.contains(candidate) {
            candidate += 1
        }
        return candidate
    }

    private var availablePHPVersions: [String] {
        let versions = phpVersionStore.availableVersions
        if versions.contains(phpVersion) {
            return versions
        }
        return [phpVersion] + versions
    }

    private struct MountRowEntry: Identifiable, Equatable {
        var id = UUID()
        var hostPath: String = ""
        var containerPath: String = ""
        var readOnly: Bool = false
    }
}

#Preview {
    NewServerSheet()
}
