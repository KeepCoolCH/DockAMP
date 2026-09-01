import Foundation
import Combine

struct ComposeExportSummary: Hashable {
    let path: String
    let exists: Bool
    let files: [String]
    let exportedAt: Date?
}

@MainActor
final class ComposeExportManager: ObservableObject {
    static let shared = ComposeExportManager()

    private let fileManager = FileManager.default
    private let exportDirectory: URL
    private static let manifestDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private init() {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        exportDirectory = documentsDirectory
            .appendingPathComponent("DockAMP", isDirectory: true)
            .appendingPathComponent("compose-export", isDirectory: true)
    }

    func summary() -> ComposeExportSummary {
        let manifestURL = exportDirectory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? Self.manifestDecoder.decode(ComposeExportManifest.self, from: data) else {
            return ComposeExportSummary(path: exportDirectory.path, exists: false, files: [], exportedAt: nil)
        }
        return ComposeExportSummary(path: exportDirectory.path, exists: true, files: manifest.files, exportedAt: manifest.exportedAt)
    }

    @discardableResult
    func exportNow() throws -> ComposeExportSummary {
        try resetExportDirectory()

        let servers = ConfigurationStore.shared.configurations
        let sharedDatabase = SharedDatabaseStore.shared.settings
        let proxy = ProxyManagerStore.shared.settings
        var allCompose = ComposeDocument()
        var files: [String] = []

        if servers.contains(where: { $0.databaseAttachmentMode == .global }) {
            var databaseCompose = ComposeDocument()
            addSharedDatabase(to: &databaseCompose, settings: sharedDatabase)
            addSharedDatabase(to: &allCompose, settings: sharedDatabase)
            try writeCompose(databaseCompose, relativePath: "globals/database.yml")
            files.append("globals/database.yml")
        }

        if proxy.isEnabled && proxy.mode == .internal {
            var proxyCompose = ComposeDocument()
            addProxyManager(to: &proxyCompose, settings: proxy)
            addProxyManager(to: &allCompose, settings: proxy)
            try writeCompose(proxyCompose, relativePath: "globals/proxy-manager.yml")
            files.append("globals/proxy-manager.yml")
        }

        for server in servers {
            try writeManagedPythonRequirements(for: server)
            var serverCompose = ComposeDocument()
            if server.databaseAttachmentMode == .global {
                addSharedDatabase(to: &serverCompose, settings: sharedDatabase)
                attachSharedDatabase(in: &serverCompose, to: server.networkName)
            }
            addServer(server, to: &serverCompose)
            addServer(server, to: &allCompose)
            if server.databaseAttachmentMode == .global {
                attachSharedDatabase(in: &allCompose, to: server.networkName)
            }

            let filename = "servers/\(slug(server.name))-\(server.id.uuidString.prefix(8).lowercased()).yml"
            try writeCompose(serverCompose, relativePath: filename)
            files.append(filename)
        }

        try writeCompose(allCompose, relativePath: "docker-compose.yml")
        files.insert("docker-compose.yml", at: 0)
        try writeReadme(files: files)

        files.append("README-RECOVERY.md")
        let manifest = ComposeExportManifest(path: exportDirectory.path, exportedAt: Date(), files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: exportDirectory.appendingPathComponent("manifest.json"))

        return summary()
    }

    private func writeManagedPythonRequirements(for config: ServerConfiguration) throws {
        guard config.serverType == .python else { return }
        let content = config.pythonSettings.requirements.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = documents
            .appendingPathComponent("DockAMP", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try (content + "\n").write(to: directory.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
    }

    private func addServer(_ config: ServerConfiguration, to compose: inout ComposeDocument) {
        compose.networks[config.networkName] = ["name": config.networkName]

        if config.serverType.isAppServer {
            let isPython = config.serverType == .python
            let image = isPython
                ? "python:\(config.pythonSettings.version)-slim"
                : "node:\(config.nodeSettings.version)-slim"
            let containerPort = isPython
                ? config.pythonSettings.containerPort
                : config.nodeSettings.containerPort
            let startCommand = isPython
                ? config.pythonSettings.startCommand
                : config.nodeSettings.startCommand
            var volumes = ["\(config.webServerDocumentRoot):/app"]
            volumes += additionalMounts(from: config.additionalContainerMounts)
            let command: String
            if isPython {
                let managedRequirements = config.pythonSettings.requirements.trimmingCharacters(in: .whitespacesAndNewlines)
                if managedRequirements.isEmpty {
                    command = "if [ -f requirements.txt ]; then python -m pip install --disable-pip-version-check -r requirements.txt; fi; \(startCommand)"
                } else {
                    let requirementsPath = NSHomeDirectory() + "/Documents/DockAMP/runtime/\(config.id.uuidString)/requirements.txt"
                    volumes.append("\(requirementsPath):/dockamp-requirements.txt:ro")
                    command = "python -m pip install --disable-pip-version-check -r /dockamp-requirements.txt; \(startCommand)"
                }
            } else {
                let installCommand = config.nodeSettings.installCommand.trimmingCharacters(in: .whitespacesAndNewlines)
                command = installCommand.isEmpty ? startCommand : "\(installCommand) && \(startCommand)"
            }
            if config.serverType == .node && config.nodeSettings.useNodeModulesVolume {
                let volumeName = "dockamp_node_modules_\(config.id.uuidString.lowercased())"
                compose.volumes[volumeName] = ["name": volumeName]
                volumes.append("\(volumeName):/app/node_modules")
            }
            var app = service(
                image: image,
                containerName: config.primaryContainerName,
                restart: config.autoStartOnAppLaunch,
                ports: ["\(config.webServerPort):\(containerPort)"],
                networks: [config.networkName],
                volumes: volumes
            )
            app["working_dir"] = "/app"
            app["environment"] = ["PORT": "\(containerPort)"]
            app["command"] = ["sh", "-lc", command]
            addResources(cpus: config.webServerCPUs, memory: config.webServerMemoryLimit, to: &app)
            compose.services[config.primaryContainerName] = app

            if config.databaseAttachmentMode == .dedicated {
                compose.services[config.dbContainerName] = databaseService(
                    name: config.dbContainerName, type: config.databaseType,
                    settings: config.databaseSettings, port: config.databasePort,
                    volumeName: config.dbDataVolumeName, network: config.networkName,
                    restart: config.autoStartOnAppLaunch, cpus: config.dedicatedDatabaseCPUs,
                    memory: config.dedicatedDatabaseMemoryLimit, compose: &compose
                )
            }
            return
        }

        let documentRootTarget = config.webServerType == .apache ? "/usr/local/apache2/htdocs" : "/var/www/html"
        var commonVolumes = ["\(config.webServerDocumentRoot):\(documentRootTarget)"]
        commonVolumes += additionalMounts(from: config.additionalContainerMounts)

        var php = service(
            image: config.phpDockerImage,
            containerName: config.phpContainerName,
            restart: config.autoStartOnAppLaunch,
            networks: [config.networkName],
            volumes: commonVolumes
        )
        php["command"] = "php-fpm"
        addResources(cpus: config.phpCPUs, memory: config.phpMemoryLimit, to: &php)
        compose.services[config.phpContainerName] = php

        var web = service(
            image: "\(config.webServerType.dockerImage):latest",
            containerName: config.webContainerName,
            restart: config.autoStartOnAppLaunch,
            ports: ["\(config.webServerPort):80"],
            networks: [config.networkName],
            volumes: commonVolumes
        )
        addResources(cpus: config.webServerCPUs, memory: config.webServerMemoryLimit, to: &web)
        compose.services[config.webContainerName] = web

        if config.databaseAttachmentMode == .dedicated {
            compose.services[config.dbContainerName] = databaseService(
                name: config.dbContainerName,
                type: config.databaseType,
                settings: config.databaseSettings,
                port: config.databasePort,
                volumeName: config.dbDataVolumeName,
                network: config.networkName,
                restart: config.autoStartOnAppLaunch,
                cpus: config.dedicatedDatabaseCPUs,
                memory: config.dedicatedDatabaseMemoryLimit,
                compose: &compose
            )
        }
    }

    private func addSharedDatabase(to compose: inout ComposeDocument, settings: SharedDatabaseSettings) {
        compose.services[DockerManager.sharedDatabaseContainerName] = databaseService(
            name: DockerManager.sharedDatabaseContainerName,
            type: settings.databaseType,
            settings: settings.databaseSettings,
            port: settings.databasePort,
            volumeName: DockerManager.sharedDatabaseVolumeName,
            network: nil,
            restart: true,
            cpus: settings.cpus,
            memory: settings.memoryLimit,
            compose: &compose
        )
    }

    private func addProxyManager(to compose: inout ComposeDocument, settings: ProxyManagerSettings) {
        compose.networks[DockerManager.proxyManagerNetworkName] = ["name": DockerManager.proxyManagerNetworkName]
        let dataSource = settings.useNamedVolumes ? DockerManager.proxyManagerDataVolumeName : settings.dataMountPath
        let leSource = settings.useNamedVolumes ? DockerManager.proxyManagerLEVolumeName : settings.letsEncryptMountPath
        var proxy = service(
            image: "jc21/nginx-proxy-manager:latest",
            containerName: DockerManager.proxyManagerContainerName,
            restart: settings.autoStartOnAppLaunch,
            ports: ["\(settings.httpPort):80", "\(settings.httpsPort):443", "\(settings.adminPort):81"],
            networks: [DockerManager.proxyManagerNetworkName],
            volumes: ["\(dataSource):/data", "\(leSource):/etc/letsencrypt"]
        )
        addResources(cpus: settings.cpus, memory: settings.memoryLimit, to: &proxy)
        compose.services[DockerManager.proxyManagerContainerName] = proxy
        if settings.useNamedVolumes {
            compose.volumes[DockerManager.proxyManagerDataVolumeName] = ["name": DockerManager.proxyManagerDataVolumeName]
            compose.volumes[DockerManager.proxyManagerLEVolumeName] = ["name": DockerManager.proxyManagerLEVolumeName]
        }
    }

    private func databaseService(
        name: String,
        type: DatabaseType,
        settings: DatabaseSettings,
        port: Int,
        volumeName: String,
        network: String?,
        restart: Bool,
        cpus: String,
        memory: String,
        compose: inout ComposeDocument
    ) -> [String: Any] {
        compose.volumes[volumeName] = ["name": volumeName]
        var result = service(
            image: "\(type.dockerImage):latest",
            containerName: name,
            restart: restart,
            ports: ["\(port):\(type.defaultPort)"],
            networks: network.map { [$0] } ?? [],
            volumes: ["\(volumeName):\(databaseDataPath(for: type))"]
        )
        result["environment"] = databaseEnvironment(type: type, settings: settings)
        addResources(cpus: cpus, memory: memory, to: &result)
        if let network {
            compose.networks[network] = ["name": network]
        }
        return result
    }

    private func attachSharedDatabase(in compose: inout ComposeDocument, to network: String) {
        compose.networks[network] = ["name": network]
        guard var database = compose.services[DockerManager.sharedDatabaseContainerName] else { return }
        var networks = database["networks"] as? [String: Any] ?? [:]
        networks[network] = ["aliases": ["db"]]
        database["networks"] = networks
        compose.services[DockerManager.sharedDatabaseContainerName] = database
    }

    private func service(
        image: String,
        containerName: String,
        restart: Bool,
        ports: [String] = [],
        networks: [String] = [],
        volumes: [String] = []
    ) -> [String: Any] {
        var result: [String: Any] = [
            "image": image,
            "container_name": containerName,
            "restart": restart ? "unless-stopped" : "no"
        ]
        if !ports.isEmpty { result["ports"] = ports }
        if !networks.isEmpty { result["networks"] = networks }
        if !volumes.isEmpty { result["volumes"] = volumes }
        return result
    }

    private func databaseEnvironment(type: DatabaseType, settings: DatabaseSettings) -> [String: String] {
        switch type {
        case .postgres:
            return [
                "POSTGRES_PASSWORD": settings.rootPassword,
                "POSTGRES_DB": settings.databaseName,
                "POSTGRES_USER": settings.username
            ]
        case .mysql, .mariadb:
            let prefix = type == .mariadb ? "MARIADB" : "MYSQL"
            return [
                "\(prefix)_ROOT_PASSWORD": settings.rootPassword,
                "\(prefix)_DATABASE": settings.databaseName,
                "\(prefix)_USER": settings.username,
                "\(prefix)_PASSWORD": settings.password
            ]
        }
    }

    private func databaseDataPath(for type: DatabaseType) -> String {
        type == .postgres ? "/var/lib/postgresql/data" : "/var/lib/mysql"
    }

    private func addResources(cpus: String, memory: String, to service: inout [String: Any]) {
        let trimmedCPUs = cpus.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMemory = memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCPUs.isEmpty { service["cpus"] = trimmedCPUs }
        if !trimmedMemory.isEmpty { service["mem_limit"] = trimmedMemory }
    }

    private func additionalMounts(from rawValue: String) -> [String] {
        rawValue
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains(":") }
    }

    private func writeCompose(_ compose: ComposeDocument, relativePath: String) throws {
        let url = exportDirectory.appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try yamlString(for: compose).write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeReadme(files: [String]) throws {
        let fileList = files.map { "- `\($0)`" }.joined(separator: "\n")
        let readme = """
        # DockAMP Recovery Compose Export

        This folder contains Docker Compose files generated from the current DockAMP macOS configuration.

        Use this if DockAMP is unavailable and you want to start the managed containers directly:

        ```sh
        cd \(exportDirectory.path)
        docker compose -f docker-compose.yml up -d
        ```

        Notes:
        - Existing Docker volumes keep their original names.
        - Host mounts are written with their configured host paths.
        - Custom PHP runtime images must exist locally when a server uses custom PHP extensions or tools.
        - The exported YAMLs are recovery files; continue editing servers in DockAMP for normal use.

        Generated files:
        \(fileList)
        """
        try readme.write(to: exportDirectory.appendingPathComponent("README-RECOVERY.md"), atomically: true, encoding: .utf8)
    }

    private func resetExportDirectory() throws {
        if fileManager.fileExists(atPath: exportDirectory.path) {
            try fileManager.removeItem(at: exportDirectory)
        }
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    private func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).split(separator: "-").joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-")).isEmpty
            ? "server"
            : String(scalars).split(separator: "-").joined(separator: "-").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func yamlString(for compose: ComposeDocument) -> String {
        var lines = ["services:"]
        for key in compose.services.keys.sorted() {
            lines.append("  \(yamlScalar(key)):")
            appendYAMLDictionary(compose.services[key] ?? [:], indent: 4, to: &lines)
        }
        if !compose.networks.isEmpty {
            lines.append("networks:")
            for key in compose.networks.keys.sorted() {
                lines.append("  \(yamlScalar(key)):")
                appendYAMLDictionary(compose.networks[key] ?? [:], indent: 4, to: &lines)
            }
        }
        if !compose.volumes.isEmpty {
            lines.append("volumes:")
            for key in compose.volumes.keys.sorted() {
                lines.append("  \(yamlScalar(key)):")
                appendYAMLDictionary(compose.volumes[key] ?? [:], indent: 4, to: &lines)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendYAMLDictionary(_ dict: [String: Any], indent: Int, to lines: inout [String]) {
        for key in dict.keys.sorted() {
            let value = dict[key]!
            let padding = String(repeating: " ", count: indent)
            if let nested = value as? [String: Any] {
                lines.append("\(padding)\(yamlScalar(key)):")
                appendYAMLDictionary(nested, indent: indent + 2, to: &lines)
            } else if let list = value as? [Any] {
                lines.append("\(padding)\(yamlScalar(key)):")
                appendYAMLList(list, indent: indent + 2, to: &lines)
            } else {
                lines.append("\(padding)\(yamlScalar(key)): \(yamlScalar(value))")
            }
        }
    }

    private func appendYAMLList(_ list: [Any], indent: Int, to lines: inout [String]) {
        let padding = String(repeating: " ", count: indent)
        for item in list {
            if let nested = item as? [String: Any] {
                lines.append("\(padding)-")
                appendYAMLDictionary(nested, indent: indent + 2, to: &lines)
            } else {
                lines.append("\(padding)- \(yamlScalar(item))")
            }
        }
    }

    private func yamlScalar(_ value: Any) -> String {
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let int = value as? Int { return String(int) }
        let text = String(describing: value)
        if text.isEmpty { return "\"\"" }
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-")
        if text.unicodeScalars.allSatisfy({ plain.contains($0) }),
           !["true", "false", "null", "yes", "no", "on", "off"].contains(text.lowercased()) {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private struct ComposeDocument {
    var services: [String: [String: Any]] = [:]
    var networks: [String: [String: Any]] = [:]
    var volumes: [String: [String: Any]] = [:]
}

private struct ComposeExportManifest: Codable {
    let path: String
    let exportedAt: Date
    let files: [String]
}
