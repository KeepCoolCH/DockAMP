import Foundation
import Combine
import CryptoKit

@MainActor
class DockerManager: ObservableObject {
    static let shared = DockerManager()
    static let proxyManagerContainerName = "dockamp_proxy_manager"
    static let proxyManagerNetworkName = "dockamp_proxy_manager_network"
    static let proxyManagerDataVolumeName = "dockamp_proxy_manager_data"
    static let proxyManagerLEVolumeName = "dockamp_proxy_manager_letsencrypt"
    static let sharedDatabaseContainerName = "dockamp_database"
    static let sharedDatabaseVolumeName = "dockamp_database_data"
    static let phpMyAdminContainerName = "dockamp_phpmyadmin"
    static let phpMyAdminHostPort = 18080
    
    @Published var isDockerInstalled = false
    @Published var dockerVersion: String?
    @Published var isGlobalBulkActionRunning = false
    
    private init() {
        checkDockerInstallation()
    }
    
    // MARK: - Docker Installation Check
    
    func checkDockerInstallation() {
        Task {
            _ = await refreshDockerInstallationStatus()
        }
    }

    @discardableResult
    func refreshDockerInstallationStatus() async -> Bool {
        do {
            let output = try await executeCommand("docker", arguments: ["--version"])
            _ = try await executeCommand("docker", arguments: ["info", "--format", "{{.ServerVersion}}"])
            isDockerInstalled = true
            dockerVersion = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return true
        } catch {
            isDockerInstalled = false
            dockerVersion = nil
            return false
        }
    }
    
    // MARK: - Container Management
    
    func startStack(config: ServerConfiguration) async throws {
        try await createNetwork(config)
        
        switch config.databaseAttachmentMode {
        case .none:
            try await stopDedicatedDatabaseContainerIfRunning(config)
            try await disconnectSharedDatabaseContainer(from: config)
        case .global:
            try await stopDedicatedDatabaseContainerIfRunning(config)
            try await startSharedDatabaseContainer()
            try await connectSharedDatabaseContainer(to: config)
            try await ensureServerDatabaseAndUser(for: config)
        case .dedicated:
            try await startDedicatedDatabaseContainer(config)
        }
        
        try await startPHPContainer(config)
        try await waitForContainerRunning(config.phpContainerName)
        try await Task.sleep(for: .milliseconds(500))
        
        try await startWebServerContainer(config)
    }
    
    func stopStack(config: ServerConfiguration) async throws {
        var containers = [config.webContainerName, config.phpContainerName]
        if config.databaseAttachmentMode == .dedicated {
            containers.append(config.dbContainerName)
        }

        for container in containers {
            _ = try? await executeCommand("docker", arguments: ["stop", "-t", "5", container])
        }

        if config.databaseAttachmentMode == .global {
            let shouldStopSharedDB = await shouldStopSharedDatabaseAfterStopping(globalConfigID: config.id)
            if shouldStopSharedDB {
                _ = try? await executeCommand("docker", arguments: ["stop", "-t", "5", Self.sharedDatabaseContainerName])
            }
        }

        let shouldStopPhpMyAdmin = await shouldStopPhpMyAdminAfterDatabaseStop()
        if shouldStopPhpMyAdmin {
            _ = try? await executeCommand("docker", arguments: ["stop", "-t", "5", Self.phpMyAdminContainerName])
        }
    }

    private func shouldStopSharedDatabaseAfterStopping(globalConfigID: UUID) async -> Bool {
        let otherGlobalConfigs = ConfigurationStore.shared.configurations.filter {
            $0.databaseAttachmentMode == .global && $0.id != globalConfigID
        }

        for otherConfig in otherGlobalConfigs {
            let status = await getStackStatus(config: otherConfig)
            let webActive = status.web == .running || status.web == .starting
            let phpActive = status.php == .running || status.php == .starting
            if webActive && phpActive {
                return false
            }
        }

        return true
    }

    private func shouldStopPhpMyAdminAfterDatabaseStop() async -> Bool {
        let sharedDatabaseStatus = await getContainerStatus(Self.sharedDatabaseContainerName)
        if sharedDatabaseStatus == .running || sharedDatabaseStatus == .starting {
            return false
        }

        let dedicatedContainers = Set(
            ConfigurationStore.shared.configurations
                .filter { $0.databaseAttachmentMode == .dedicated }
                .map { $0.dbContainerName }
        )

        for containerName in dedicatedContainers {
            let status = await getContainerStatus(containerName)
            if status == .running || status == .starting {
                return false
            }
        }

        return true
    }
    
    func removeStack(config: ServerConfiguration) async throws {
        try? await stopStack(config: config)
        
        let containers = [config.webContainerName, config.phpContainerName, config.dbContainerName]
        for container in containers {
            _ = try? await executeCommand("docker", arguments: ["rm", "-f", container])
        }

        if requiresCustomPHPRuntimeImage(settings: config.phpSettings) {
            let signature = phpRuntimeSignature(baseImage: config.phpDockerImage, settings: config.phpSettings)
            let imageTag = "dockamp-php-runtime:\(signature)"
            _ = try? await executeCommand("docker", arguments: ["image", "rm", imageTag])
        }
        
        _ = try? await executeCommand("docker", arguments: ["volume", "rm", "-f", config.dbDataVolumeName])
        await removeServerNetworkIfPossible(config.networkName)
    }

    private func removeServerNetworkIfPossible(_ networkName: String) async {
        let connectedContainerNames: [String]
        if let output = try? await executeCommand("docker", arguments: [
            "network", "inspect",
            "--format", "{{range .Containers}}{{println .Name}}{{end}}",
            networkName
        ]) {
            connectedContainerNames = output
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            connectedContainerNames = []
        }

        for containerName in connectedContainerNames {
            _ = try? await executeCommand("docker", arguments: [
                "network", "disconnect", "-f", networkName, containerName
            ])
        }

        _ = try? await executeCommand("docker", arguments: ["network", "rm", networkName])
    }
    
    func restartStack(config: ServerConfiguration) async throws {
        var containers = [config.webContainerName, config.phpContainerName]
        if config.databaseAttachmentMode == .dedicated {
            containers.append(config.dbContainerName)
        }
        _ = try? await executeCommand("docker", arguments: ["rm", "-f"] + containers)

        try await Task.sleep(for: .milliseconds(300))
        try await startStack(config: config)
    }

    func resetWebAndPHPContainers(config: ServerConfiguration) async throws {
        _ = try? await executeCommand("docker", arguments: ["stop", config.webContainerName, config.phpContainerName])
        _ = try? await executeCommand("docker", arguments: ["rm", "-f", config.webContainerName, config.phpContainerName])

        try await createNetwork(config)
        try await startPHPContainer(config)
        try await waitForContainerRunning(config.phpContainerName)
        try await Task.sleep(for: .milliseconds(500))
        try await startWebServerContainer(config)
    }
    
    // MARK: - Container Status
    
    func getContainerStatus(_ containerName: String) async -> ContainerStatus {
        do {
            let output = try await executeCommand("docker", arguments: [
                "inspect",
                "--format", "{{.State.Status}}",
                containerName
            ])
            let state = output.trimmingCharacters(in: .whitespacesAndNewlines)

            switch state {
            case "running":
                return .running
            case "exited", "created", "paused":
                return .stopped
            case "restarting":
                return .starting
            case "removing", "dead":
                return .stopping
            default:
                return .error
            }
        } catch {
            return .notCreated
        }
    }
    
    func getStackStatus(config: ServerConfiguration) async -> (web: ContainerStatus, php: ContainerStatus, db: ContainerStatus) {
        async let webStatus = getContainerStatus(config.webContainerName)
        async let phpStatus = getContainerStatus(config.phpContainerName)
        let dbStatus: ContainerStatus
        switch config.databaseAttachmentMode {
        case .none:
            dbStatus = .notCreated
        case .global:
            dbStatus = await getContainerStatus(Self.sharedDatabaseContainerName)
        case .dedicated:
            dbStatus = await getContainerStatus(config.dbContainerName)
        }

        return await (webStatus, phpStatus, dbStatus)
    }
    
    // MARK: - Image Management
    
    func updateImages(config: ServerConfiguration) async throws {
        var images = [
            "\(config.webServerType.dockerImage):latest",
            config.phpDockerImage
        ]

        switch config.databaseAttachmentMode {
        case .none:
            break
        case .global:
            images.append("\(SharedDatabaseStore.shared.settings.databaseType.dockerImage):latest")
        case .dedicated:
            images.append("\(config.databaseType.dockerImage):latest")
        }
        
        for image in images {
            _ = try await executeCommand("docker", arguments: ["pull", image])
        }
    }
    
    func listImages() async throws -> [String] {
        let output = try await executeCommand("docker", arguments: ["images", "--format", "{{.Repository}}:{{.Tag}}"])
        return output.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    
    // MARK: - Logs
    
    func getContainerLogs(_ containerName: String, tail: Int = 100) async throws -> String {
        let escapedContainerName = escapeForSingleQuotedShell(containerName)
        let command = "docker logs --tail \(tail) '\(escapedContainerName)' 2>&1"
        return try await executeCommand("sh", arguments: ["-lc", command])
    }

    func fixDocumentRootPermissions(path: String) async throws {
        _ = try await executeCommand("mkdir", arguments: ["-p", path])
        _ = try await executeCommand("chmod", arguments: ["-R", "u+rwX,go+rX", path])
        _ = try? await executeCommand("find", arguments: [
            path, "-name", ".htaccess", "-type", "f",
            "-exec", "chmod", "u+rw,go+r", "{}", "+"
        ])
        _ = try? await executeCommand("find", arguments: [
            path,
            "-type", "f",
            "(",
            "-name", "*.cgi",
            "-o", "-name", "*.pl",
            "-o", "-name", "*.py",
            "-o", "-name", "*.sh",
            ")",
            "-exec", "chmod", "u+rwx,go+rx", "{}", "+"
        ])
    }

    func renameStackContainers(oldConfig: ServerConfiguration, newConfig: ServerConfiguration) async throws {
        try await renameContainerIfExists(from: oldConfig.webContainerName, to: newConfig.webContainerName)
        try await renameContainerIfExists(from: oldConfig.phpContainerName, to: newConfig.phpContainerName)

        if oldConfig.databaseAttachmentMode == .dedicated || newConfig.databaseAttachmentMode == .dedicated {
            try await renameContainerIfExists(from: oldConfig.dbContainerName, to: newConfig.dbContainerName)
        }
    }

    // MARK: - Proxy Manager (Global)

    func getProxyManagerStatus() async -> ContainerStatus {
        await getContainerStatus(Self.proxyManagerContainerName)
    }

    func startProxyManager(settings: ProxyManagerSettings) async throws {
        let existingStatus = await getContainerStatus(Self.proxyManagerContainerName)
        switch existingStatus {
        case .running, .starting, .stopped:
            _ = try? await executeCommand("docker", arguments: ["rm", "-f", Self.proxyManagerContainerName])
        case .notCreated, .error, .stopping:
            break
        }

        var args = [
            "run", "-d",
            "--name", Self.proxyManagerContainerName,
            "--network", Self.proxyManagerNetworkName,
            "-p", "\(settings.httpPort):80",
            "-p", "\(settings.httpsPort):443",
            "-p", "\(settings.adminPort):81",
        ]
        if settings.autoStartOnAppLaunch {
            args += ["--restart", "unless-stopped"]
        }
        appendResourceArgs(cpus: settings.cpus, memory: settings.memoryLimit, to: &args)

        if settings.useNamedVolumes {
            args += [
                "-v", "\(Self.proxyManagerDataVolumeName):/data",
                "-v", "\(Self.proxyManagerLEVolumeName):/etc/letsencrypt",
            ]
        } else {
            args += [
                "-v", "\(settings.dataMountPath):/data",
                "-v", "\(settings.letsEncryptMountPath):/etc/letsencrypt",
            ]
        }

        args.append("jc21/nginx-proxy-manager:latest")
        try await ensureNetworkExists(Self.proxyManagerNetworkName)
        try await runContainerWithNetworkRecovery(networkName: Self.proxyManagerNetworkName, arguments: args)
    }

    func stopProxyManager() async throws {
        _ = try await executeCommand("docker", arguments: ["stop", Self.proxyManagerContainerName])
    }

    func removeProxyManagerContainer() async throws {
        _ = try await executeCommand("docker", arguments: ["rm", "-f", Self.proxyManagerContainerName])
    }

    func updateProxyManagerImage() async throws {
        _ = try await executeCommand("docker", arguments: ["pull", "jc21/nginx-proxy-manager:latest"])
    }

    func changeSharedDatabaseRootPassword(currentPassword: String, newPassword: String) async throws {
        let settings = SharedDatabaseStore.shared.settings
        try await changeDatabaseRootPassword(
            containerName: Self.sharedDatabaseContainerName,
            databaseType: settings.databaseType,
            adminUser: settings.databaseSettings.username,
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }

    func startPhpMyAdmin(host: String, port: Int, username: String, password: String) async throws -> Int {
        _ = try? await executeCommand("docker", arguments: ["rm", "-f", Self.phpMyAdminContainerName])

        let args = [
            "run", "-d",
            "--name", Self.phpMyAdminContainerName,
            "-p", "\(Self.phpMyAdminHostPort):80",
            "-e", "PMA_HOST=\(host)",
            "-e", "PMA_PORT=\(port)",
            "-e", "PMA_USER=\(username)",
            "-e", "PMA_PASSWORD=\(password)",
            "phpmyadmin:latest"
        ]

        _ = try await executeCommand("docker", arguments: args)
        return Self.phpMyAdminHostPort
    }

    func changeDedicatedDatabaseRootPassword(config: ServerConfiguration, currentPassword: String, newPassword: String) async throws {
        try await changeDatabaseRootPassword(
            containerName: config.dbContainerName,
            databaseType: config.databaseType,
            adminUser: config.databaseSettings.username,
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }
    
    // MARK: - Private Helper Methods
    
    private func createNetwork(_ config: ServerConfiguration) async throws {
        try await ensureNetworkExists(config.networkName)
    }

    private func ensureNetworkExists(_ networkName: String) async throws {
        if (try? await executeCommand("docker", arguments: ["network", "inspect", networkName])) == nil {
            _ = try await executeCommand("docker", arguments: ["network", "create", networkName])
        }
    }

    private func runContainerWithNetworkRecovery(networkName: String, arguments: [String]) async throws {
        do {
            _ = try await executeCommand("docker", arguments: arguments)
        } catch {
            guard isMissingNetworkError(error) else { throw error }
            try await ensureNetworkExists(networkName)
            _ = try await executeCommand("docker", arguments: arguments)
        }
    }

    private func isMissingNetworkError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("network") && (message.contains("no such network") || message.contains("not found"))
    }

    private func renameContainerIfExists(from oldName: String, to newName: String) async throws {
        guard oldName != newName else { return }

        let oldStatus = await getContainerStatus(oldName)
        guard oldStatus != .notCreated else { return }

        let targetStatus = await getContainerStatus(newName)
        if targetStatus != .notCreated {
            throw DockerError.commandFailed("Container name '\(newName)' is already in use.")
        }

        _ = try await executeCommand("docker", arguments: ["rename", oldName, newName])
    }

    private func changeDatabaseRootPassword(containerName: String, databaseType: DatabaseType, adminUser: String, currentPassword: String, newPassword: String) async throws {
        let status = await getContainerStatus(containerName)
        guard status == .running else {
            throw DockerError.commandFailed("Database container '\(containerName)' is not running.")
        }

        let trimmedCurrent = currentPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrent.isEmpty, !trimmedNew.isEmpty else {
            throw DockerError.commandFailed("Current and new password must not be empty.")
        }

        switch databaseType {
        case .mysql, .mariadb:
            try await changeMySQLRootPassword(
                containerName: containerName,
                client: databaseType == .mariadb ? "mariadb" : "mysql",
                currentPassword: trimmedCurrent,
                newPassword: trimmedNew
            )
        case .postgres:
            let resolvedAdminUser = adminUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "postgres" : adminUser
            try await changePostgresAdminPassword(
                containerName: containerName,
                adminUser: resolvedAdminUser,
                currentPassword: trimmedCurrent,
                newPassword: trimmedNew
            )
        }
    }

    private func changeMySQLRootPassword(containerName: String, client: String, currentPassword: String, newPassword: String) async throws {
        let escapedPassword = escapeMySQLString(newPassword)
        let statements = [
            "ALTER USER 'root'@'localhost' IDENTIFIED BY '\(escapedPassword)';",
            "CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY '\(escapedPassword)';",
            "ALTER USER 'root'@'%' IDENTIFIED BY '\(escapedPassword)';",
            "GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;"
        ]

        var anySucceeded = false
        for statement in statements {
            do {
                _ = try await executeCommand("docker", arguments: [
                    "exec",
                    containerName,
                    client,
                    "-uroot",
                    "-p\(currentPassword)",
                    "-e",
                    statement
                ])
                anySucceeded = true
            } catch {
                continue
            }
        }

        guard anySucceeded else {
            throw DockerError.commandFailed("Root password could not be changed. Check current password.")
        }

        _ = try await executeCommand("docker", arguments: [
            "exec",
            containerName,
            client,
            "-uroot",
            "-p\(newPassword)",
            "-e",
            "FLUSH PRIVILEGES; SELECT 1;"
        ])
    }

    private func changePostgresAdminPassword(containerName: String, adminUser: String, currentPassword: String, newPassword: String) async throws {
        let escapedUser = escapePostgresIdentifier(adminUser)
        let escapedPassword = escapePostgresString(newPassword)
        _ = try await executeCommand("docker", arguments: [
            "exec",
            "-e", "PGPASSWORD=\(currentPassword)",
            containerName,
            "psql",
            "-U", adminUser,
            "-d", "postgres",
            "-c",
            "ALTER USER \"\(escapedUser)\" WITH PASSWORD '\(escapedPassword)';"
        ])

        _ = try await executeCommand("docker", arguments: [
            "exec",
            "-e", "PGPASSWORD=\(newPassword)",
            containerName,
            "psql",
            "-U", adminUser,
            "-d", "postgres",
            "-tAc",
            "SELECT 1;"
        ])
    }
    
    private func startSharedDatabaseContainer() async throws {
        let sharedDB = SharedDatabaseStore.shared.settings
        let existingStatus = await getContainerStatus(Self.sharedDatabaseContainerName)
        switch existingStatus {
        case .running, .starting:
            return
        case .stopped:
            do {
                _ = try await executeCommand("docker", arguments: ["start", Self.sharedDatabaseContainerName])
                return
            } catch {
                guard isMissingNetworkError(error) else { throw error }
                _ = try? await executeCommand("docker", arguments: ["rm", "-f", Self.sharedDatabaseContainerName])
            }
        case .notCreated, .error, .stopping:
            break
        }

        var args = [
            "run", "-d",
            "--name", Self.sharedDatabaseContainerName,
            "--restart", "unless-stopped",
            "-p", "\(sharedDB.databasePort):\(sharedDB.databaseType.defaultPort)",
        ]
        appendResourceArgs(cpus: sharedDB.cpus, memory: sharedDB.memoryLimit, to: &args)
        
        switch sharedDB.databaseType {
        case .mysql:
            args += [
                "-e", "MYSQL_ROOT_PASSWORD=\(sharedDB.databaseSettings.rootPassword)",
                "-v", "\(Self.sharedDatabaseVolumeName):/var/lib/mysql",
            ]
        case .mariadb:
            args += [
                "-e", "MARIADB_ROOT_PASSWORD=\(sharedDB.databaseSettings.rootPassword)",
                "-v", "\(Self.sharedDatabaseVolumeName):/var/lib/mysql",
            ]
        case .postgres:
            args += [
                "-e", "POSTGRES_PASSWORD=\(sharedDB.databaseSettings.rootPassword)",
                "-v", "\(Self.sharedDatabaseVolumeName):/var/lib/postgresql/data",
            ]
        }
        
        args.append("\(sharedDB.databaseType.dockerImage):latest")
        
        _ = try? await executeCommand("docker", arguments: ["rm", "-f", Self.sharedDatabaseContainerName])
        
        _ = try await executeCommand("docker", arguments: args)
    }

    private func startDedicatedDatabaseContainer(_ config: ServerConfiguration) async throws {
        var args = [
            "run", "-d",
            "--name", config.dbContainerName,
            "--network", config.networkName,
            "-p", "\(config.databasePort):\(config.databaseType.defaultPort)",
        ]
        appendRestartPolicyIfNeeded(for: config, to: &args)
        appendResourceArgs(cpus: config.dedicatedDatabaseCPUs, memory: config.dedicatedDatabaseMemoryLimit, to: &args)

        switch config.databaseType {
        case .mysql:
            args += [
                "-e", "MYSQL_ROOT_PASSWORD=\(config.databaseSettings.rootPassword)",
                "-e", "MYSQL_DATABASE=\(config.databaseSettings.databaseName)",
                "-e", "MYSQL_USER=\(config.databaseSettings.username)",
                "-e", "MYSQL_PASSWORD=\(config.databaseSettings.password)",
                "-v", "\(config.dbDataVolumeName):/var/lib/mysql",
            ]
        case .mariadb:
            args += [
                "-e", "MARIADB_ROOT_PASSWORD=\(config.databaseSettings.rootPassword)",
                "-e", "MARIADB_DATABASE=\(config.databaseSettings.databaseName)",
                "-e", "MARIADB_USER=\(config.databaseSettings.username)",
                "-e", "MARIADB_PASSWORD=\(config.databaseSettings.password)",
                "-v", "\(config.dbDataVolumeName):/var/lib/mysql",
            ]
        case .postgres:
            args += [
                "-e", "POSTGRES_PASSWORD=\(config.databaseSettings.rootPassword)",
                "-e", "POSTGRES_DB=\(config.databaseSettings.databaseName)",
                "-e", "POSTGRES_USER=\(config.databaseSettings.username)",
                "-v", "\(config.dbDataVolumeName):/var/lib/postgresql/data",
            ]
        }

        args.append("\(config.databaseType.dockerImage):latest")

        _ = try? await executeCommand("docker", arguments: ["rm", "-f", config.dbContainerName])
        try await runContainerWithNetworkRecovery(networkName: config.networkName, arguments: args)
    }

    private func stopDedicatedDatabaseContainerIfRunning(_ config: ServerConfiguration) async throws {
        let status = await getContainerStatus(config.dbContainerName)
        guard status == .running || status == .starting || status == .error else { return }
        _ = try? await executeCommand("docker", arguments: ["stop", config.dbContainerName])
    }

    private func connectSharedDatabaseContainer(to config: ServerConfiguration) async throws {
        do {
            _ = try await executeCommand("docker", arguments: [
                "network", "connect",
                "--alias", "db",
                "--alias", config.dbContainerName,
                config.networkName,
                Self.sharedDatabaseContainerName
            ])
        } catch {
            try await ensureNetworkExists(config.networkName)
            _ = try? await executeCommand("docker", arguments: [
                "network", "connect",
                "--alias", "db",
                "--alias", config.dbContainerName,
                config.networkName,
                Self.sharedDatabaseContainerName
            ])
        }
    }

    private func disconnectSharedDatabaseContainer(from config: ServerConfiguration) async throws {
        _ = try? await executeCommand("docker", arguments: [
            "network", "disconnect",
            config.networkName,
            Self.sharedDatabaseContainerName
        ])
    }

    private func waitForContainerRunning(_ containerName: String, timeoutSeconds: Int = 20) async throws {
        for _ in 0..<timeoutSeconds {
            let status = await getContainerStatus(containerName)
            if status == .running { return }
            if status == .error {
                throw DockerError.commandFailed("Container '\(containerName)' is in an error state.")
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw DockerError.commandFailed("Container '\(containerName)' did not become ready in time.")
    }

    private func ensureServerDatabaseAndUser(for config: ServerConfiguration) async throws {
        let shared = SharedDatabaseStore.shared.settings
        let db = config.databaseSettings

        switch shared.databaseType {
        case .mysql, .mariadb:
            try await waitForMySQLReady(rootPassword: shared.databaseSettings.rootPassword)
            let sql = """
            CREATE DATABASE IF NOT EXISTS `\(escapeMySQLIdentifier(db.databaseName))`;
            SET @dockamp_user_exists := (SELECT COUNT(*) FROM mysql.user WHERE user='\(escapeMySQLString(db.username))' AND host='%');
            SET @dockamp_user_sql := IF(
                @dockamp_user_exists = 0,
                'CREATE USER ''\(escapeMySQLString(db.username))''@''%'' IDENTIFIED BY ''\(escapeMySQLString(db.password))''',
                'ALTER USER ''\(escapeMySQLString(db.username))''@''%'' IDENTIFIED BY ''\(escapeMySQLString(db.password))'''
            );
            PREPARE dockamp_user_stmt FROM @dockamp_user_sql;
            EXECUTE dockamp_user_stmt;
            DEALLOCATE PREPARE dockamp_user_stmt;
            GRANT ALL PRIVILEGES ON `\(escapeMySQLIdentifier(db.databaseName))`.* TO '\(escapeMySQLString(db.username))'@'%';
            FLUSH PRIVILEGES;
            """
            let client = shared.databaseType == .mariadb ? "mariadb" : "mysql"
            _ = try await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                client,
                "-uroot",
                "-p\(shared.databaseSettings.rootPassword)",
                "-e",
                sql
            ])
        case .postgres:
            let adminUser = "postgres"
            try await waitForPostgresReady(adminUser: adminUser)

            let userExists = try await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                "psql",
                "-U", adminUser,
                "-tAc",
                "SELECT 1 FROM pg_roles WHERE rolname='\(escapePostgresString(db.username))';"
            ]).trimmingCharacters(in: .whitespacesAndNewlines) == "1"

            if !userExists {
                _ = try await executeCommand("docker", arguments: [
                    "exec",
                    Self.sharedDatabaseContainerName,
                    "psql",
                    "-U", adminUser,
                    "-c",
                    "CREATE ROLE \"\(escapePostgresIdentifier(db.username))\" LOGIN PASSWORD '\(escapePostgresString(db.password))';"
                ])
            } else {
                _ = try await executeCommand("docker", arguments: [
                    "exec",
                    Self.sharedDatabaseContainerName,
                    "psql",
                    "-U", adminUser,
                    "-c",
                    "ALTER ROLE \"\(escapePostgresIdentifier(db.username))\" WITH PASSWORD '\(escapePostgresString(db.password))';"
                ])
            }

            let dbExists = try await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                "psql",
                "-U", adminUser,
                "-tAc",
                "SELECT 1 FROM pg_database WHERE datname='\(escapePostgresString(db.databaseName))';"
            ]).trimmingCharacters(in: .whitespacesAndNewlines) == "1"

            if !dbExists {
                _ = try await executeCommand("docker", arguments: [
                    "exec",
                    Self.sharedDatabaseContainerName,
                    "psql",
                    "-U", adminUser,
                    "-c",
                    "CREATE DATABASE \"\(escapePostgresIdentifier(db.databaseName))\" OWNER \"\(escapePostgresIdentifier(db.username))\";"
                ])
            }

            _ = try await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                "psql",
                "-U", adminUser,
                "-c",
                "GRANT ALL PRIVILEGES ON DATABASE \"\(escapePostgresIdentifier(db.databaseName))\" TO \"\(escapePostgresIdentifier(db.username))\";"
            ])
        }
    }

    private func waitForMySQLReady(rootPassword: String) async throws {
        for _ in 0..<30 {
            let result = try? await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                "mysqladmin",
                "ping",
                "-h", "127.0.0.1",
                "-uroot",
                "-p\(rootPassword)",
                "--silent"
            ])
            if result != nil { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DockerError.commandFailed("Database is not ready (MySQL/MariaDB).")
    }

    private func waitForPostgresReady(adminUser: String) async throws {
        for _ in 0..<30 {
            let result = try? await executeCommand("docker", arguments: [
                "exec",
                Self.sharedDatabaseContainerName,
                "pg_isready",
                "-U", adminUser
            ])
            if result != nil { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw DockerError.commandFailed("Database is not ready (PostgreSQL).")
    }

    private func escapeMySQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    private func escapeMySQLIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }

    private func escapePostgresString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapePostgresIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\"\"")
    }
    
    private func startPHPContainer(_ config: ServerConfiguration) async throws {
        let phpIniPath = try createPHPConfig(config)
        let phpFpmPath = try createPHPFPMConfig(config)
        let phpRuntimeImage = try await ensurePHPRuntimeImage(for: config)

        var finalArgs = [
            "run", "-d",
            "--name", config.phpContainerName,
            "--network", config.networkName,
            "-v", "\(config.webServerDocumentRoot):/var/www/html",
            "-v", "\(phpIniPath):/usr/local/etc/php/php.ini:ro",
            "-v", "\(phpFpmPath):/usr/local/etc/php-fpm.d/zz-dockamp.conf:ro"
        ]
        appendRestartPolicyIfNeeded(for: config, to: &finalArgs)
        appendResourceArgs(cpus: config.phpCPUs, memory: config.phpMemoryLimit, to: &finalArgs)
        finalArgs += parseAdditionalContainerMountArgs(config.additionalContainerMounts)
        finalArgs.append(phpRuntimeImage)

        _ = try? await executeCommand("docker", arguments: ["rm", "-f", config.phpContainerName])
        try await runContainerWithNetworkRecovery(networkName: config.networkName, arguments: finalArgs)

        if phpRuntimeImage.hasPrefix("dockamp-php-runtime:") {
            await cleanupOldPHPRuntimeImages(keeping: phpRuntimeImage)
        }
    }
    
    private func startWebServerContainer(_ config: ServerConfiguration) async throws {
        var args = [
            "run", "-d",
            "--name", config.webContainerName,
            "--network", config.networkName,
            "-p", "\(config.webServerPort):80",
        ]
        appendRestartPolicyIfNeeded(for: config, to: &args)
        appendResourceArgs(cpus: config.webServerCPUs, memory: config.webServerMemoryLimit, to: &args)
        args += parseAdditionalDockerRunArgs(config.webServerAdditionalRunArgs)
        args += parseAdditionalContainerMountArgs(config.additionalContainerMounts)

        switch config.webServerType {
        case .apache:
            let apacheStartupScript = createApacheStartupScript(config)
            args += [
                "-v", "\(config.webServerDocumentRoot):/usr/local/apache2/htdocs",
                "\(config.webServerType.dockerImage):latest",
                "sh", "-c",
                apacheStartupScript
            ]
        case .nginx:
            let nginxMainConfigPath = try createNginxMainConfig(config)
            let nginxConfigPath = try createNginxConfig(config)
            args += [
                "-v", "\(config.webServerDocumentRoot):/var/www/html",
                "-v", "\(nginxMainConfigPath):/etc/nginx/nginx.conf:ro",
                "-v", "\(nginxConfigPath):/etc/nginx/conf.d/default.conf:ro",
                "\(config.webServerType.dockerImage):latest"
            ]
        }
        
        _ = try? await executeCommand("docker", arguments: ["rm", "-f", config.webContainerName])
        try await runContainerWithNetworkRecovery(networkName: config.networkName, arguments: args)
    }

    private func createPHPConfig(_ config: ServerConfiguration) throws -> String {
        let additionalIni = trimMultiline(config.phpSettings.additionalIniDirectives)
        let phpIni = """
        [PHP]
        memory_limit = \(config.phpSettings.memoryLimit)
        max_execution_time = \(config.phpSettings.maxExecutionTime)
        max_input_time = \(config.phpSettings.maxInputTime)
        max_input_vars = \(config.phpSettings.maxInputVars)
        default_socket_timeout = \(config.phpSettings.defaultSocketTimeout)
        realpath_cache_size = \(config.phpSettings.realpathCacheSize)
        realpath_cache_ttl = \(config.phpSettings.realpathCacheTTL)
        upload_max_filesize = \(config.phpSettings.uploadMaxFilesize)
        post_max_size = \(config.phpSettings.postMaxSize)
        file_uploads = \(config.phpSettings.fileUploadsEnabled ? "On" : "Off")
        max_file_uploads = \(config.phpSettings.maxFileUploads)
        display_errors = \(config.phpSettings.displayErrors ? "On" : "Off")
        display_startup_errors = \(config.phpSettings.displayStartupErrors ? "On" : "Off")
        log_errors = \(config.phpSettings.logErrors ? "On" : "Off")
        error_log = \(config.phpSettings.errorLogPath)
        error_reporting = \(config.phpSettings.errorReporting)
        date.timezone = \(config.phpSettings.timezone)
        expose_php = \(config.phpSettings.exposePHP ? "On" : "Off")
        allow_url_fopen = \(config.phpSettings.allowURLFopen ? "On" : "Off")
        allow_url_include = \(config.phpSettings.allowURLInclude ? "On" : "Off")
        disable_functions = \(config.phpSettings.disableFunctions)

        [Session]
        session.save_handler = \(config.phpSettings.sessionSaveHandler)
        session.save_path = \(config.phpSettings.sessionSavePath)
        session.gc_maxlifetime = \(config.phpSettings.sessionGCMaxLifetime)
        session.cookie_secure = \(config.phpSettings.sessionCookieSecure ? "1" : "0")
        session.cookie_httponly = \(config.phpSettings.sessionCookieHTTPOnly ? "1" : "0")
        session.cookie_samesite = \(config.phpSettings.sessionCookieSameSite)

        [opcache]
        opcache.enable = \(config.phpSettings.opcacheEnabled ? "1" : "0")
        opcache.memory_consumption = \(config.phpSettings.opcacheMemoryConsumption)
        opcache.max_accelerated_files = \(config.phpSettings.opcacheMaxAcceleratedFiles)
        opcache.validate_timestamps = \(config.phpSettings.opcacheValidateTimestamps ? "1" : "0")
        opcache.revalidate_freq = \(config.phpSettings.opcacheRevalidateFreq)
        opcache.jit = \(config.phpSettings.opcacheJITEnabled ? config.phpSettings.opcacheJITMode : "off")
        opcache.jit_buffer_size = \(config.phpSettings.opcacheJITEnabled ? config.phpSettings.opcacheJITBufferSize : "0")
        \(additionalIni)
        """
        
        let phpIniURL = try writeTransientConfigFile(
            named: "php_\(config.id).ini",
            contents: phpIni
        )
        return phpIniURL.path
    }

    private func createPHPFPMConfig(_ config: ServerConfiguration) throws -> String {
        let pmMode = config.phpSettings.fpmProcessManager.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "dynamic"
            : config.phpSettings.fpmProcessManager.trimmingCharacters(in: .whitespacesAndNewlines)
        let fpmConfig = """
        [www]
        pm = \(pmMode)
        pm.max_children = \(config.phpSettings.fpmMaxChildren)
        pm.start_servers = \(config.phpSettings.fpmStartServers)
        pm.min_spare_servers = \(config.phpSettings.fpmMinSpareServers)
        pm.max_spare_servers = \(config.phpSettings.fpmMaxSpareServers)
        pm.max_requests = \(config.phpSettings.fpmMaxRequests)
        catch_workers_output = yes
        """
        let fpmConfURL = try writeTransientConfigFile(
            named: "php_fpm_\(config.id).conf",
            contents: fpmConfig
        )
        return fpmConfURL.path
    }

    private func writeTransientConfigFile(named fileName: String, contents: String) throws -> URL {
        let fileManager = FileManager.default
        let candidateDirectories = [
            fileManager.temporaryDirectory,
            try dockampApplicationSupportTempDirectory()
        ]

        var lastError: Error?
        for directory in candidateDirectories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let fileURL = directory.appendingPathComponent(fileName)
                try contents.write(to: fileURL, atomically: true, encoding: .utf8)
                return fileURL
            } catch {
                lastError = error
            }
        }

        throw lastError ?? DockerError.commandFailed("Unable to write temporary config file '\(fileName)'.")
    }

    private func dockampApplicationSupportTempDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("DockAMP", isDirectory: true)
            .appendingPathComponent("tmp", isDirectory: true)
    }

    private func createNginxConfig(_ config: ServerConfiguration) throws -> String {
        let gzipEnabled = config.nginxSettings.gzipEnabled ? "on" : "off"
        let autoIndex = config.nginxSettings.autoIndexEnabled ? "on" : "off"
        let accessLog = config.nginxSettings.accessLogEnabled ? "/var/log/nginx/access.log" : "off"
        let xFrameHeader = config.nginxSettings.headerXFrameOptionsEnabled ? "add_header X-Frame-Options \"\(config.nginxSettings.headerXFrameOptionsValue)\" always;" : ""
        let xContentTypeHeader = config.nginxSettings.headerXContentTypeOptionsEnabled ? "add_header X-Content-Type-Options \"nosniff\" always;" : ""
        let referrerHeader = config.nginxSettings.headerReferrerPolicyEnabled ? "add_header Referrer-Policy \"\(config.nginxSettings.headerReferrerPolicyValue)\" always;" : ""
        let cspHeader = config.nginxSettings.headerCSPEnabled ? "add_header Content-Security-Policy \"\(config.nginxSettings.headerCSPValue.replacingOccurrences(of: "\"", with: "\\\""))\" always;" : ""
        let staticCacheLocation = config.nginxSettings.staticCacheEnabled ? """
            location ~* \\.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp|avif|woff|woff2|ttf|eot)$ {
                expires \(config.nginxSettings.staticCacheExpires);
                add_header Cache-Control "public, max-age=31536000, immutable";
                access_log off;
            }
        """ : ""
        let additionalServerDirectives = indentDirectives(config.nginxSettings.additionalServerDirectives, spaces: 4)
        let additionalLocationDirectives = indentDirectives(config.nginxSettings.additionalLocationDirectives, spaces: 8)
        let additionalLocationBlocks = indentDirectives(config.nginxSettings.additionalLocationBlocks, spaces: 4)
        let nginxConf = """
        server {
            listen 80;
            server_name localhost;
            root /var/www/html;
            index index.php index.html index.htm;
            client_max_body_size \(config.nginxSettings.clientMaxBodySize);
            access_log \(accessLog);
            \(xFrameHeader)
            \(xContentTypeHeader)
            \(referrerHeader)
            \(cspHeader)

            location / {
                try_files \(config.nginxSettings.tryFilesRule);
                autoindex \(autoIndex);
            \(additionalLocationDirectives)
            }

            location ~ \\.php$ {
                include fastcgi_params;
                fastcgi_index index.php;
                fastcgi_param SCRIPT_FILENAME /var/www/html$fastcgi_script_name;
                fastcgi_pass \(config.phpContainerName):9000;
                fastcgi_connect_timeout \(config.nginxSettings.fastcgiConnectTimeout);
                fastcgi_send_timeout \(config.nginxSettings.fastcgiSendTimeout);
                fastcgi_read_timeout \(config.nginxSettings.fastcgiReadTimeout);
                fastcgi_buffer_size \(config.nginxSettings.fastcgiBufferSize);
                fastcgi_buffers \(config.nginxSettings.fastcgiBuffersCount) \(config.nginxSettings.fastcgiBuffersSize);
            }

            gzip \(gzipEnabled);
            gzip_min_length \(config.nginxSettings.gzipMinLength);
            gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
            proxy_connect_timeout \(config.nginxSettings.proxyConnectTimeout);
            proxy_send_timeout \(config.nginxSettings.proxySendTimeout);
            proxy_read_timeout \(config.nginxSettings.proxyReadTimeout);
            \(staticCacheLocation)
            \(additionalServerDirectives)
            \(additionalLocationBlocks)
        }
        """

        let nginxConfURL = try writeTransientConfigFile(
            named: "nginx_\(config.id).conf",
            contents: nginxConf
        )
        return nginxConfURL.path
    }

    private func createNginxMainConfig(_ config: ServerConfiguration) throws -> String {
        let sendfile = config.nginxSettings.sendfileEnabled ? "on" : "off"
        let tcpNopush = config.nginxSettings.tcpNopushEnabled ? "on" : "off"
        let tcpNodelay = config.nginxSettings.tcpNodelayEnabled ? "on" : "off"
        let errorLogLevel = config.nginxSettings.errorLogLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "warn"
            : config.nginxSettings.errorLogLevel.trimmingCharacters(in: .whitespacesAndNewlines)

        let nginxMainConf = """
        user nginx;
        worker_processes \(config.nginxSettings.workerProcesses);
        pid /var/run/nginx.pid;

        events {
            worker_connections \(config.nginxSettings.workerConnections);
        }

        http {
            include /etc/nginx/mime.types;
            default_type application/octet-stream;

            sendfile \(sendfile);
            tcp_nopush \(tcpNopush);
            tcp_nodelay \(tcpNodelay);
            keepalive_timeout \(config.nginxSettings.keepaliveTimeout);
            client_body_timeout \(config.nginxSettings.clientBodyTimeout);
            client_header_timeout \(config.nginxSettings.clientHeaderTimeout);
            send_timeout \(config.nginxSettings.sendTimeout);

            error_log /var/log/nginx/error.log \(errorLogLevel);

            include /etc/nginx/conf.d/*.conf;
        }
        """

        let nginxMainConfURL = try writeTransientConfigFile(
            named: "nginx_main_\(config.id).conf",
            contents: nginxMainConf
        )
        return nginxMainConfURL.path
    }

    private func createApacheStartupScript(_ config: ServerConfiguration) -> String {
        let keepAlive = config.apacheSettings.keepAliveEnabled ? "On" : "Off"
        let sendfile = config.apacheSettings.enableSendfile ? "On" : "Off"
        let mmap = config.apacheSettings.enableMMAP ? "On" : "Off"
        let serverTokens = config.apacheSettings.serverTokensProd ? "Prod" : "Full"
        let serverSignature = config.apacheSettings.serverSignatureOff ? "Off" : "On"
        let traceEnable = config.apacheSettings.traceEnableOff ? "Off" : "On"
        let fileETag = config.apacheSettings.fileETagEnabled ? "MTime Size" : "None"
        let allowOverride = config.apacheSettings.allowOverrideAll ? "All" : "None"
        let requireDirective = createApacheRequireDirective(config)
        let directoryOptions = createApacheDirectoryOptions(config.apacheSettings)
        let directoryIndex = config.apacheSettings.forceDirectoryListing ? "disabled" : "index.php index.html index.htm"
        let mpmModuleLine = "LoadModule mpm_\(config.apacheSettings.mpmType.rawValue)_module modules/mod_mpm_\(config.apacheSettings.mpmType.rawValue).so"
        let expiresActive = config.apacheSettings.enableExpires ? "On" : "Off"
        let preserveHost = config.apacheSettings.proxyPreserveHost ? "On" : "Off"

        var commands = [
            "sed -i -E 's/^LoadModule mpm_(event|worker|prefork)_module/#&/g' /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^\(mpmModuleLine)' /usr/local/apache2/conf/httpd.conf || echo '\(mpmModuleLine)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LoadModule proxy_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule proxy_module modules/mod_proxy.so' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LoadModule proxy_fcgi_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LoadModule proxy_http_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule proxy_http_module modules/mod_proxy_http.so' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LoadModule reqtimeout_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule reqtimeout_module modules/mod_reqtimeout.so' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LoadModule headers_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule headers_module modules/mod_headers.so' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^DirectoryIndex \(directoryIndex)' /usr/local/apache2/conf/httpd.conf || echo 'DirectoryIndex \(directoryIndex)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^KeepAlive \(keepAlive)' /usr/local/apache2/conf/httpd.conf || echo 'KeepAlive \(keepAlive)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^MaxKeepAliveRequests \(config.apacheSettings.maxKeepAliveRequests)' /usr/local/apache2/conf/httpd.conf || echo 'MaxKeepAliveRequests \(config.apacheSettings.maxKeepAliveRequests)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^KeepAliveTimeout \(config.apacheSettings.keepAliveTimeout)' /usr/local/apache2/conf/httpd.conf || echo 'KeepAliveTimeout \(config.apacheSettings.keepAliveTimeout)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^Timeout \(config.apacheSettings.timeout)' /usr/local/apache2/conf/httpd.conf || echo 'Timeout \(config.apacheSettings.timeout)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^ProxyTimeout \(config.apacheSettings.proxyTimeout)' /usr/local/apache2/conf/httpd.conf || echo 'ProxyTimeout \(config.apacheSettings.proxyTimeout)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^RequestReadTimeout \(config.apacheSettings.requestReadTimeout)' /usr/local/apache2/conf/httpd.conf || echo 'RequestReadTimeout \(config.apacheSettings.requestReadTimeout)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^EnableSendfile \(sendfile)' /usr/local/apache2/conf/httpd.conf || echo 'EnableSendfile \(sendfile)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^EnableMMAP \(mmap)' /usr/local/apache2/conf/httpd.conf || echo 'EnableMMAP \(mmap)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^ServerTokens \(serverTokens)' /usr/local/apache2/conf/httpd.conf || echo 'ServerTokens \(serverTokens)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^ServerSignature \(serverSignature)' /usr/local/apache2/conf/httpd.conf || echo 'ServerSignature \(serverSignature)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^TraceEnable \(traceEnable)' /usr/local/apache2/conf/httpd.conf || echo 'TraceEnable \(traceEnable)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LogLevel \(config.apacheSettings.logLevel)' /usr/local/apache2/conf/httpd.conf || echo 'LogLevel \(config.apacheSettings.logLevel)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^ErrorLog \(config.apacheSettings.errorLogTarget)' /usr/local/apache2/conf/httpd.conf || echo 'ErrorLog \(config.apacheSettings.errorLogTarget)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^CustomLog \(config.apacheSettings.customLogTarget)' /usr/local/apache2/conf/httpd.conf || echo 'CustomLog \(config.apacheSettings.customLogTarget) \"\(escapeForDoubleQuotedApache(config.apacheSettings.customLogFormat))\"' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LimitRequestBody \(config.apacheSettings.limitRequestBody)' /usr/local/apache2/conf/httpd.conf || echo 'LimitRequestBody \(config.apacheSettings.limitRequestBody)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LimitRequestFields \(config.apacheSettings.limitRequestFields)' /usr/local/apache2/conf/httpd.conf || echo 'LimitRequestFields \(config.apacheSettings.limitRequestFields)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^LimitRequestLine \(config.apacheSettings.limitRequestLine)' /usr/local/apache2/conf/httpd.conf || echo 'LimitRequestLine \(config.apacheSettings.limitRequestLine)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^ProxyPreserveHost \(preserveHost)' /usr/local/apache2/conf/httpd.conf || echo 'ProxyPreserveHost \(preserveHost)' >> /usr/local/apache2/conf/httpd.conf;",
            "grep -q '^FileETag \(fileETag)' /usr/local/apache2/conf/httpd.conf || echo 'FileETag \(fileETag)' >> /usr/local/apache2/conf/httpd.conf;",
            "printf '\\n<IfModule mpm_\(config.apacheSettings.mpmType.rawValue)_module>\\n    StartServers \(config.apacheSettings.startServers)\\n    ServerLimit \(config.apacheSettings.serverLimit)\\n    MaxRequestWorkers \(config.apacheSettings.maxRequestWorkers)\\n    MinSpareThreads \(config.apacheSettings.minSpareThreads)\\n    MaxSpareThreads \(config.apacheSettings.maxSpareThreads)\\n    ThreadsPerChild \(config.apacheSettings.threadsPerChild)\\n</IfModule>\\n' >> /usr/local/apache2/conf/httpd.conf;",
            "printf '\\n<Directory \"/usr/local/apache2/htdocs\">\\n    AllowOverride \(allowOverride)\\n    Options \(directoryOptions)\\n    \(requireDirective)\\n</Directory>\\n' >> /usr/local/apache2/conf/httpd.conf;"
        ]

        if config.apacheSettings.enableDeflate {
            commands.append("grep -q '^LoadModule deflate_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule deflate_module modules/mod_deflate.so' >> /usr/local/apache2/conf/httpd.conf;")
            commands.append("grep -q '^AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css application/javascript application/json' /usr/local/apache2/conf/httpd.conf || echo 'AddOutputFilterByType DEFLATE text/html text/plain text/xml text/css application/javascript application/json' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.enableRewrite {
            commands.append("grep -q '^LoadModule rewrite_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule rewrite_module modules/mod_rewrite.so' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.enableExpires {
            commands.append("grep -q '^LoadModule expires_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule expires_module modules/mod_expires.so' >> /usr/local/apache2/conf/httpd.conf;")
            commands.append("grep -q '^ExpiresActive \(expiresActive)' /usr/local/apache2/conf/httpd.conf || echo 'ExpiresActive \(expiresActive)' >> /usr/local/apache2/conf/httpd.conf;")
            commands.append("grep -q '^ExpiresDefault \"\(escapeForDoubleQuotedApache(config.apacheSettings.expiresDefault))\"' /usr/local/apache2/conf/httpd.conf || echo 'ExpiresDefault \"\(escapeForDoubleQuotedApache(config.apacheSettings.expiresDefault))\"' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.sslProxyEngineEnabled {
            commands.append("grep -q '^LoadModule ssl_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule ssl_module modules/mod_ssl.so' >> /usr/local/apache2/conf/httpd.conf;")
            commands.append("grep -q '^SSLProxyEngine On' /usr/local/apache2/conf/httpd.conf || echo 'SSLProxyEngine On' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.optionIncludes || config.apacheSettings.optionIncludesNoExec {
            commands.append("grep -q '^LoadModule include_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule include_module modules/mod_include.so' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.optionExecCGI {
            commands.append("grep -q '^LoadModule cgid_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule cgid_module modules/mod_cgid.so' >> /usr/local/apache2/conf/httpd.conf;")
            commands.append("grep -q '^AddHandler cgi-script .cgi .pl .py' /usr/local/apache2/conf/httpd.conf || echo 'AddHandler cgi-script .cgi .pl .py' >> /usr/local/apache2/conf/httpd.conf;")
        }
        if config.apacheSettings.optionMultiViews {
            commands.append("grep -q '^LoadModule negotiation_module' /usr/local/apache2/conf/httpd.conf || echo 'LoadModule negotiation_module modules/mod_negotiation.so' >> /usr/local/apache2/conf/httpd.conf;")
        }

        let headerDirectives = createApacheHeaderDirectives(config.apacheSettings)
        if !headerDirectives.isEmpty {
            let escaped = escapeForSingleQuotedShell(headerDirectives)
            commands.append("printf '\\n\(escaped)\\n' >> /usr/local/apache2/conf/httpd.conf;")
        }

        let proxyRules = createApacheProxyPassDirectives(config.apacheSettings.proxyPassRules)
        if !proxyRules.isEmpty {
            let escaped = escapeForSingleQuotedShell(proxyRules)
            commands.append("printf '\\n\(escaped)\\n' >> /usr/local/apache2/conf/httpd.conf;")
        }

        let virtualHostDirectives = trimmedDirectiveText(config.apacheSettings.virtualHostDirectives)
        if !virtualHostDirectives.isEmpty {
            let escaped = escapeForSingleQuotedShell(virtualHostDirectives)
            commands.append("printf '\\n<VirtualHost *:80>\\n\(escaped)\\n</VirtualHost>\\n' >> /usr/local/apache2/conf/httpd.conf;")
        }

        let additionalDirectives = trimmedDirectiveText(config.apacheSettings.additionalDirectives)
        if !additionalDirectives.isEmpty {
            let escaped = escapeForSingleQuotedShell(additionalDirectives)
            commands.append("printf '\\n\(escaped)\\n' >> /usr/local/apache2/conf/httpd.conf;")
        }

        commands.append("grep -q '^ProxyPassMatch .*enablereuse=on' /usr/local/apache2/conf/httpd.conf || echo 'ProxyPassMatch ^/(.*\\\\.php(/.*)?)$ fcgi://\(config.phpContainerName):9000/var/www/html/$1 enablereuse=on' >> /usr/local/apache2/conf/httpd.conf;")
        commands.append("httpd-foreground")

        return commands.joined(separator: " ")
    }

    private func parseAdditionalDockerRunArgs(_ rawValue: String) -> [String] {
        rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func appendRestartPolicyIfNeeded(for config: ServerConfiguration, to arguments: inout [String]) {
        guard config.autoStartOnAppLaunch else { return }
        arguments += ["--restart", "unless-stopped"]
    }

    private func parseAdditionalContainerMountArgs(_ rawValue: String) -> [String] {
        rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains(":") }
            .flatMap { ["-v", $0] }
    }

    private func selectedPHPExtensions(from settings: PHPSettings) -> [String] {
        var extensions: [String] = []
        if settings.enableMySQLExtensions {
            extensions += ["mysqli", "pdo_mysql"]
        }
        if settings.enableGD { extensions.append("gd") }
        if settings.enableIntl { extensions.append("intl") }
        if settings.enableZip { extensions.append("zip") }
        if settings.enableBCMath { extensions.append("bcmath") }
        if settings.enableExif { extensions.append("exif") }
        if settings.enableSOAP { extensions.append("soap") }
        if settings.enableXSL { extensions.append("xsl") }
        if settings.enablePDOPgSQL { extensions.append("pdo_pgsql") }
        if settings.enablePgSQL { extensions.append("pgsql") }
        if settings.enableMBString { extensions.append("mbstring") }
        if settings.enableSockets { extensions.append("sockets") }
        if settings.enablePCNTL { extensions.append("pcntl") }
        if settings.enablePDOSQLite { extensions.append("pdo_sqlite") }
        if settings.enableSQLite3 { extensions.append("sqlite3") }
        if settings.enableCurlExtension { extensions.append("curl") }
        if settings.enableDOMExtension { extensions.append("dom") }
        if settings.enableXMLExtension { extensions.append("xml") }
        if settings.enableSimpleXMLExtension { extensions.append("simplexml") }
        if settings.enableFTPExtension { extensions.append("ftp") }
        return extensions
    }

    private func phpExtensionBootstrapCommand(settings: PHPSettings, runPHPFPMAtEnd: Bool = true) -> String {
        let extensions = selectedPHPExtensions(from: settings)
        let peclExtensions = selectedPECLPHPExtensions(from: settings)
        let installZipBinaryTools = settings.installZipBinaryTools
        let installLibarchiveTools = settings.installLibarchiveTools
        let installICUFullData = settings.installICUFullData
        let installGitTool = settings.installGitTool
        let installCurlWgetTools = settings.installCurlWgetTools
        let installEditorsNanoVim = settings.installEditorsNanoVim
        let installTreeTool = settings.installTreeTool
        let installRsyncTool = settings.installRsyncTool
        let installFFmpegTool = settings.installFFmpegTool
        let installGhostscriptTool = settings.installGhostscriptTool
        let installImageMagickTools = settings.installImageMagickTools
        let installNodeJSTools = settings.installNodeJSTools
        let installComposerTool = settings.installComposerTool

        guard !extensions.isEmpty ||
            !peclExtensions.isEmpty ||
            installZipBinaryTools ||
            installLibarchiveTools ||
            installICUFullData ||
            installGitTool ||
            installCurlWgetTools ||
            installEditorsNanoVim ||
            installTreeTool ||
            installRsyncTool ||
            installFFmpegTool ||
            installGhostscriptTool ||
            installImageMagickTools ||
            installNodeJSTools ||
            installComposerTool else {
            return "php-fpm"
        }

        let extensionList = extensions.joined(separator: " ")
        let peclList = peclExtensions.joined(separator: " ")
        let zipToolsFlag = installZipBinaryTools ? "1" : "0"
        let archiveToolsFlag = installLibarchiveTools ? "1" : "0"
        let icuDataFlag = installICUFullData ? "1" : "0"
        let gitFlag = installGitTool ? "1" : "0"
        let curlWgetFlag = installCurlWgetTools ? "1" : "0"
        let editorsFlag = installEditorsNanoVim ? "1" : "0"
        let treeFlag = installTreeTool ? "1" : "0"
        let rsyncFlag = installRsyncTool ? "1" : "0"
        let ffmpegFlag = installFFmpegTool ? "1" : "0"
        let ghostscriptFlag = installGhostscriptTool ? "1" : "0"
        let imageMagickFlag = installImageMagickTools ? "1" : "0"
        let nodeFlag = installNodeJSTools ? "1" : "0"
        let composerFlag = installComposerTool ? "1" : "0"
        let gdWebPFlag = settings.enableGDWebP ? "1" : "0"
        let gdAvifFlag = settings.enableGDAvif ? "1" : "0"
        return """
        set -eu
        export TERM="${TERM:-xterm}"
        EXTS="\(extensionList)"
        PECL_EXTS="\(peclList)"
        WANT_ZIP_TOOLS="\(zipToolsFlag)"
        WANT_ARCHIVE_TOOLS="\(archiveToolsFlag)"
        WANT_ICU_FULL_DATA="\(icuDataFlag)"
        WANT_GIT_TOOL="\(gitFlag)"
        WANT_CURL_WGET_TOOLS="\(curlWgetFlag)"
        WANT_EDITORS="\(editorsFlag)"
        WANT_TREE_TOOL="\(treeFlag)"
        WANT_RSYNC_TOOL="\(rsyncFlag)"
        WANT_FFMPEG_TOOL="\(ffmpegFlag)"
        WANT_GHOSTSCRIPT_TOOL="\(ghostscriptFlag)"
        WANT_IMAGEMAGICK_TOOLS="\(imageMagickFlag)"
        WANT_NODE_TOOLS="\(nodeFlag)"
        WANT_COMPOSER_TOOL="\(composerFlag)"
        WANT_GD_WEBP="\(gdWebPFlag)"
        WANT_GD_AVIF="\(gdAvifFlag)"
        MISSING=""
        for ext in $EXTS; do
            if ! php -m | grep -qi "^${ext}$"; then
                MISSING="${MISSING} ${ext}"
            fi
        done
        MISSING="$(echo "$MISSING" | tr -s ' ' | sed 's/^ //;s/ $//')"
        MISSING_PECL=""
        for ext in $PECL_EXTS; do
            if ! php -m | grep -qi "^${ext}$"; then
                MISSING_PECL="${MISSING_PECL} ${ext}"
            fi
        done
        MISSING_PECL="$(echo "$MISSING_PECL" | tr -s ' ' | sed 's/^ //;s/ $//')"
        NEED_ZIP_TOOLS=0
        NEED_ARCHIVE_TOOLS=0
        NEED_ICU_FULL_DATA=0
        NEED_GIT_TOOL=0
        NEED_CURL_WGET_TOOLS=0
        NEED_EDITORS=0
        NEED_TREE_TOOL=0
        NEED_RSYNC_TOOL=0
        NEED_FFMPEG_TOOL=0
        NEED_GHOSTSCRIPT_TOOL=0
        NEED_IMAGEMAGICK_TOOLS=0
        NEED_NODE_TOOLS=0
        NEED_COMPOSER_TOOL=0
        if [ "$WANT_ZIP_TOOLS" = "1" ] && { ! command -v zip >/dev/null 2>&1 || ! command -v unzip >/dev/null 2>&1; }; then
            NEED_ZIP_TOOLS=1
        fi
        if [ "$WANT_ARCHIVE_TOOLS" = "1" ] && ! command -v bsdtar >/dev/null 2>&1; then
            NEED_ARCHIVE_TOOLS=1
        fi
        if [ "$WANT_ICU_FULL_DATA" = "1" ] && ! dpkg -s icu-data-full >/dev/null 2>&1; then NEED_ICU_FULL_DATA=1; fi
        if [ "$WANT_GIT_TOOL" = "1" ] && ! command -v git >/dev/null 2>&1; then NEED_GIT_TOOL=1; fi
        if [ "$WANT_CURL_WGET_TOOLS" = "1" ] && { ! command -v curl >/dev/null 2>&1 || ! command -v wget >/dev/null 2>&1; }; then NEED_CURL_WGET_TOOLS=1; fi
        if [ "$WANT_EDITORS" = "1" ] && { ! command -v nano >/dev/null 2>&1 || ! command -v vim >/dev/null 2>&1; }; then NEED_EDITORS=1; fi
        if [ "$WANT_TREE_TOOL" = "1" ] && ! command -v tree >/dev/null 2>&1; then NEED_TREE_TOOL=1; fi
        if [ "$WANT_RSYNC_TOOL" = "1" ] && ! command -v rsync >/dev/null 2>&1; then NEED_RSYNC_TOOL=1; fi
        if [ "$WANT_FFMPEG_TOOL" = "1" ] && ! command -v ffmpeg >/dev/null 2>&1; then NEED_FFMPEG_TOOL=1; fi
        if [ "$WANT_GHOSTSCRIPT_TOOL" = "1" ] && ! command -v gs >/dev/null 2>&1; then NEED_GHOSTSCRIPT_TOOL=1; fi
        if [ "$WANT_IMAGEMAGICK_TOOLS" = "1" ] && ! command -v convert >/dev/null 2>&1; then NEED_IMAGEMAGICK_TOOLS=1; fi
        if [ "$WANT_NODE_TOOLS" = "1" ] && { ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; }; then NEED_NODE_TOOLS=1; fi
        if [ "$WANT_COMPOSER_TOOL" = "1" ] && ! command -v composer >/dev/null 2>&1; then NEED_COMPOSER_TOOL=1; fi

        if [ -n "$MISSING" ] || [ -n "$MISSING_PECL" ] || [ "$NEED_ZIP_TOOLS" = "1" ] || [ "$NEED_ARCHIVE_TOOLS" = "1" ] || [ "$NEED_ICU_FULL_DATA" = "1" ] || [ "$NEED_GIT_TOOL" = "1" ] || [ "$NEED_CURL_WGET_TOOLS" = "1" ] || [ "$NEED_EDITORS" = "1" ] || [ "$NEED_TREE_TOOL" = "1" ] || [ "$NEED_RSYNC_TOOL" = "1" ] || [ "$NEED_FFMPEG_TOOL" = "1" ] || [ "$NEED_GHOSTSCRIPT_TOOL" = "1" ] || [ "$NEED_IMAGEMAGICK_TOOLS" = "1" ] || [ "$NEED_NODE_TOOLS" = "1" ]; then
            apt-get update
            INSTALL_PACKAGES=""
            DEPS=""
            if [ -n "$MISSING" ] || [ -n "$MISSING_PECL" ]; then
                INSTALL_PACKAGES="$INSTALL_PACKAGES $PHPIZE_DEPS"
                echo " $MISSING " | grep -q " intl " && DEPS="$DEPS libicu-dev" || true
                echo " $MISSING " | grep -q " zip " && DEPS="$DEPS libzip-dev zlib1g-dev" || true
                echo " $MISSING " | grep -q " mbstring " && DEPS="$DEPS libonig-dev" || true
                echo " $MISSING " | grep -q " soap " && DEPS="$DEPS libxml2-dev" || true
                echo " $MISSING " | grep -q " xsl " && DEPS="$DEPS libxslt1-dev" || true
                echo " $MISSING " | grep -q " gd " && DEPS="$DEPS libpng-dev libjpeg62-turbo-dev libfreetype6-dev" || true
                if echo " $MISSING " | grep -q " gd "; then
                    [ "$WANT_GD_WEBP" = "1" ] && DEPS="$DEPS libwebp-dev" || true
                    [ "$WANT_GD_AVIF" = "1" ] && DEPS="$DEPS libavif-dev" || true
                fi
                (echo " $MISSING " | grep -q " pdo_pgsql " || echo " $MISSING " | grep -q " pgsql ") && DEPS="$DEPS libpq-dev" || true
            fi
            if echo " $MISSING_PECL " | grep -q " imagick "; then
                DEPS="$DEPS libmagickwand-dev imagemagick"
            fi
            if echo " $MISSING_PECL " | grep -q " ssh2 "; then
                DEPS="$DEPS libssh2-1-dev"
            fi
            if [ "$NEED_ZIP_TOOLS" = "1" ]; then
                INSTALL_PACKAGES="$INSTALL_PACKAGES zip unzip"
            fi
            if [ "$NEED_ARCHIVE_TOOLS" = "1" ]; then
                INSTALL_PACKAGES="$INSTALL_PACKAGES libarchive-tools"
            fi
            if [ "$NEED_ICU_FULL_DATA" = "1" ]; then
                if apt-cache show icu-data-full >/dev/null 2>&1; then INSTALL_PACKAGES="$INSTALL_PACKAGES icu-data-full"; fi
            fi
            [ "$NEED_GIT_TOOL" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES git" || true
            [ "$NEED_CURL_WGET_TOOLS" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES curl wget" || true
            [ "$NEED_EDITORS" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES nano vim" || true
            [ "$NEED_TREE_TOOL" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES tree" || true
            [ "$NEED_RSYNC_TOOL" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES rsync" || true
            [ "$NEED_FFMPEG_TOOL" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES ffmpeg" || true
            [ "$NEED_GHOSTSCRIPT_TOOL" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES ghostscript" || true
            [ "$NEED_IMAGEMAGICK_TOOLS" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES imagemagick" || true
            [ "$NEED_NODE_TOOLS" = "1" ] && INSTALL_PACKAGES="$INSTALL_PACKAGES nodejs npm" || true
            INSTALL_PACKAGES="$(echo "$INSTALL_PACKAGES $DEPS" | tr -s ' ' | sed 's/^ //;s/ $//')"
            if [ -n "$INSTALL_PACKAGES" ]; then
                apt-get install -y --no-install-recommends $INSTALL_PACKAGES
            fi
            if [ -n "$MISSING" ]; then
                if echo " $MISSING " | grep -q " gd "; then
                    GD_FLAGS="--with-freetype --with-jpeg"
                    [ "$WANT_GD_WEBP" = "1" ] && GD_FLAGS="$GD_FLAGS --with-webp" || true
                    [ "$WANT_GD_AVIF" = "1" ] && GD_FLAGS="$GD_FLAGS --with-avif" || true
                    docker-php-ext-configure gd $GD_FLAGS
                fi
                docker-php-ext-install -j$(nproc) $MISSING
            fi
            if [ -n "$MISSING_PECL" ]; then
                pecl install $MISSING_PECL
                docker-php-ext-enable $MISSING_PECL || true
            fi
            rm -rf /var/lib/apt/lists/*
        fi
        if [ "$NEED_COMPOSER_TOOL" = "1" ]; then
            php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
            php composer-setup.php --install-dir=/usr/local/bin --filename=composer
            rm -f composer-setup.php
        fi
        \(runPHPFPMAtEnd ? "php-fpm" : "true")
        """
    }

    private func selectedPECLPHPExtensions(from settings: PHPSettings) -> [String] {
        var extensions: [String] = []
        if settings.enableRedisExtension { extensions.append("redis") }
        if settings.enableImagickExtension { extensions.append("imagick") }
        if settings.enableXdebugExtension { extensions.append("xdebug") }
        if settings.enableSSH2Extension { extensions.append("ssh2") }
        return extensions
    }

    private func requiresCustomPHPRuntimeImage(settings: PHPSettings) -> Bool {
        !selectedPHPExtensions(from: settings).isEmpty ||
        !selectedPECLPHPExtensions(from: settings).isEmpty ||
        settings.installZipBinaryTools ||
        settings.installLibarchiveTools ||
        settings.installICUFullData ||
        settings.installGitTool ||
        settings.installCurlWgetTools ||
        settings.installEditorsNanoVim ||
        settings.installTreeTool ||
        settings.installRsyncTool ||
        settings.installFFmpegTool ||
        settings.installGhostscriptTool ||
        settings.installImageMagickTools ||
        settings.installNodeJSTools ||
        settings.installComposerTool ||
        (settings.enableGD && settings.enableGDWebP) ||
        (settings.enableGD && settings.enableGDAvif)
    }

    private func ensurePHPRuntimeImage(for config: ServerConfiguration) async throws -> String {
        guard requiresCustomPHPRuntimeImage(settings: config.phpSettings) else {
            return config.phpDockerImage
        }

        let signature = phpRuntimeSignature(baseImage: config.phpDockerImage, settings: config.phpSettings)
        let imageTag = "dockamp-php-runtime:\(signature)"

        let imageExists = (try? await executeCommand("docker", arguments: ["image", "inspect", imageTag])) != nil
        if imageExists {
            await cleanupOldPHPRuntimeImages(keeping: imageTag)
            return imageTag
        }

        let buildContainerName = "\(config.phpContainerName)_imagebuild"
        let provisionCommand = phpExtensionBootstrapCommand(settings: config.phpSettings, runPHPFPMAtEnd: false)

        do {
            _ = try? await executeCommand("docker", arguments: ["rm", "-f", buildContainerName])
            _ = try await executeCommand("docker", arguments: [
                "run", "--name", buildContainerName, config.phpDockerImage, "sh", "-c", provisionCommand
            ])
            _ = try await executeCommand("docker", arguments: [
                "commit",
                "--change", "CMD [\"php-fpm\"]",
                buildContainerName,
                imageTag
            ])
            _ = try? await executeCommand("docker", arguments: ["rm", "-f", buildContainerName])
            await cleanupOldPHPRuntimeImages(keeping: imageTag)
            return imageTag
        } catch {
            _ = try? await executeCommand("docker", arguments: ["rm", "-f", buildContainerName])
            throw error
        }
    }

    private func cleanupOldPHPRuntimeImages(keeping imageTag: String) async {
        let keepImageID = try? await executeCommand("docker", arguments: [
            "image", "inspect", imageTag, "--format", "{{.Id}}"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard let output = try? await executeCommand("docker", arguments: [
            "images",
            "dockamp-php-runtime",
            "--format",
            "{{.Repository}}:{{.Tag}} {{.ID}}"
        ]) else {
            return
        }

        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let namePart = parts.first else { continue }
            let namedImage = String(namePart)
            let imageID = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

            if namedImage == imageTag {
                continue
            }
            if let keepImageID, !keepImageID.isEmpty, imageID == keepImageID {
                continue
            }

            if !imageID.isEmpty,
               let consumers = try? await executeCommand("docker", arguments: ["ps", "-a", "--filter", "ancestor=\(imageID)", "-q"]),
               !consumers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            if namedImage.hasSuffix(":<none>") {
                if !imageID.isEmpty {
                    _ = try? await executeCommand("docker", arguments: ["image", "rm", imageID])
                }
            } else {
                _ = try? await executeCommand("docker", arguments: ["image", "rm", namedImage])
            }
        }

        _ = try? await executeCommand("docker", arguments: ["image", "prune", "-f"])
    }

    private func phpRuntimeSignature(baseImage: String, settings: PHPSettings) -> String {
        var parts: [String] = []
        parts.append("builder=v2")
        parts.append("base=\(baseImage)")
        parts.append("ext=\(selectedPHPExtensions(from: settings).sorted().joined(separator: ","))")
        parts.append("pecl=\(selectedPECLPHPExtensions(from: settings).sorted().joined(separator: ","))")
        parts.append("ziptools=\(settings.installZipBinaryTools)")
        parts.append("libarchive=\(settings.installLibarchiveTools)")
        parts.append("icufull=\(settings.installICUFullData)")
        parts.append("git=\(settings.installGitTool)")
        parts.append("curlwget=\(settings.installCurlWgetTools)")
        parts.append("editors=\(settings.installEditorsNanoVim)")
        parts.append("tree=\(settings.installTreeTool)")
        parts.append("rsync=\(settings.installRsyncTool)")
        parts.append("ffmpeg=\(settings.installFFmpegTool)")
        parts.append("ghostscript=\(settings.installGhostscriptTool)")
        parts.append("imagemagick=\(settings.installImageMagickTools)")
        parts.append("node=\(settings.installNodeJSTools)")
        parts.append("composer=\(settings.installComposerTool)")
        parts.append("gdwebp=\(settings.enableGDWebP)")
        parts.append("gdavif=\(settings.enableGDAvif)")
        let payload = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    private func appendResourceArgs(cpus: String, memory: String, to args: inout [String]) {
        let trimmedCPUs = cpus.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCPUs.isEmpty {
            args += ["--cpus", trimmedCPUs]
        }
        if !trimmedMemory.isEmpty {
            args += ["--memory", trimmedMemory]
        }
    }

    private func trimmedDirectiveText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimMultiline(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func indentDirectives(_ value: String, spaces: Int) -> String {
        let trimmed = trimmedDirectiveText(value)
        guard !trimmed.isEmpty else { return "" }
        let indent = String(repeating: " ", count: spaces)
        return "\n" + trimmed
            .components(separatedBy: .newlines)
            .map { "\(indent)\($0)" }
            .joined(separator: "\n")
    }

    private func escapeForSingleQuotedShell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\"'\"'")
    }

    private func createApacheRequireDirective(_ config: ServerConfiguration) -> String {
        if config.apacheSettings.restrictToSpecificIPs {
            let ipRules = parseAllowListValues(config.apacheSettings.allowedIPs)
            if !ipRules.isEmpty {
                return "Require ip \(ipRules.joined(separator: " "))"
            }
            return "Require all denied"
        }
        return config.apacheSettings.requireAllGranted ? "Require all granted" : "Require all denied"
    }

    private func createApacheDirectoryOptions(_ settings: ApacheSettings) -> String {
        var values: [String] = []
        if settings.optionIndexes { values.append("Indexes") }
        if settings.optionIncludes { values.append("Includes") }
        if settings.optionExecCGI { values.append("ExecCGI") }
        if settings.optionSymLinksIfOwnerMatch { values.append("SymLinksIfOwnerMatch") }
        if settings.optionIncludesNoExec { values.append("IncludesNOEXEC") }
        if settings.optionFollowSymLinks { values.append("FollowSymLinks") }
        if settings.optionMultiViews { values.append("MultiViews") }
        return values.isEmpty ? "None" : values.joined(separator: " ")
    }

    private func parseAllowListValues(_ raw: String) -> [String] {
        raw
            .replacingOccurrences(of: ",", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func createApacheHeaderDirectives(_ settings: ApacheSettings) -> String {
        var lines: [String] = []
        if settings.headerXFrameOptionsEnabled {
            lines.append("Header always set X-Frame-Options \"\(settings.headerXFrameOptionsValue)\"")
        }
        if settings.headerXContentTypeOptionsEnabled {
            lines.append("Header always set X-Content-Type-Options \"nosniff\"")
        }
        if settings.headerReferrerPolicyEnabled {
            lines.append("Header always set Referrer-Policy \"\(settings.headerReferrerPolicyValue)\"")
        }
        if settings.headerCSPEnabled {
            lines.append("Header always set Content-Security-Policy \"\(settings.headerCSPValue.replacingOccurrences(of: "\"", with: "\\\""))\"")
        }
        return lines.joined(separator: "\n")
    }

    private func createApacheProxyPassDirectives(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    private func escapeForDoubleQuotedApache(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    // MARK: - Command Execution
    
    func executeCommand(_ command: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()

            let possiblePaths = [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                "/usr/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"
            ]

            if command == "docker" {
                guard let dockerPath = possiblePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
                    throw DockerError.notInstalled
                }
                process.executableURL = URL(fileURLWithPath: dockerPath)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
            }

            var environment = ProcessInfo.processInfo.environment
            let paths = [
                "/usr/local/bin",
                "/opt/homebrew/bin",
                "/usr/bin",
                "/bin",
                "/Applications/Docker.app/Contents/Resources/bin",
                environment["PATH"] ?? ""
            ].joined(separator: ":")
            environment["PATH"] = paths

            let possibleSockets = [
                "unix://\(NSHomeDirectory())/.orbstack/run/docker.sock",
                "unix://\(NSHomeDirectory())/.docker/run/docker.sock",
                "unix:///var/run/docker.sock"
            ]

            let foundSocket = possibleSockets.first { socket in
                let socketPath = socket.replacingOccurrences(of: "unix://", with: "")
                return FileManager.default.fileExists(atPath: socketPath) && FileManager.default.isReadableFile(atPath: socketPath)
            }

            if let foundSocket {
                environment["DOCKER_HOST"] = foundSocket
            } else if environment["DOCKER_HOST"] == nil {
                environment["DOCKER_HOST"] = "unix://\(NSHomeDirectory())/.orbstack/run/docker.sock"
            }

            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            final class DataAccumulator {
                private let queue = DispatchQueue(label: "dockamp.command.output.accumulator")
                private var data = Data()

                func append(_ chunk: Data) {
                    queue.sync {
                        data.append(chunk)
                    }
                }

                func value() -> Data {
                    queue.sync { data }
                }
            }

            let outputData = DataAccumulator()
            let errorData = DataAccumulator()

            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                outputData.append(chunk)
            }

            errorPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                errorData.append(chunk)
            }

            try process.run()
            process.waitUntilExit()

            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil

            let remainingOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingOutput.isEmpty {
                outputData.append(remainingOutput)
            }

            let remainingError = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingError.isEmpty {
                errorData.append(remainingError)
            }

            let outputString = String(data: outputData.value(), encoding: .utf8) ?? ""
            let errorString = String(data: errorData.value(), encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                let stderrText = errorString.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = outputString.trimmingCharacters(in: .whitespacesAndNewlines)
                let message: String
                if !stderrText.isEmpty {
                    message = stderrText
                } else if !stdoutText.isEmpty {
                    message = stdoutText
                } else {
                    message = "Command exited with status \(process.terminationStatus)."
                }
                throw DockerError.commandFailed(message)
            }

            return outputString
        }.value
    }
}

// MARK: - Errors

enum DockerError: LocalizedError {
    case notInstalled
    case commandFailed(String)
    case containerNotFound
    
    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Docker is not installed. Please install OrbStack or Docker Desktop for macOS."
        case .commandFailed(let message):
            return "Docker command failed: \(message)"
        case .containerNotFound:
            return "Container was not found."
        }
    }
}
