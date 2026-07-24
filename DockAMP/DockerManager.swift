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

    private var netStatsCache: [String: (date: Date, rxBytes: Double, txBytes: Double)] = [:]
    
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

    // MARK: - Container Center

    func containerCenterSnapshot() async throws -> ContainerCenterSnapshot {
        let output = try await executeCommand("docker", arguments: [
            "ps", "-a",
            "--format", "{{json .}}"
        ])

        let rows = output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> DockerPSRow? in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(DockerPSRow.self, from: data)
            }

        let roleMap = containerCenterManagedRoles()
        let items: [ContainerCenterItem] = rows.map { row in
            let name = row.names.trimmingCharacters(in: .whitespacesAndNewlines)
            return ContainerCenterItem(
                name: name,
                image: row.image,
                state: row.state,
                statusText: row.status,
                ports: parseContainerCenterPorts(row.ports),
                isManaged: roleMap[name] != nil,
                role: roleMap[name]
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return ContainerCenterSnapshot(
            managed: items.filter { $0.isManaged },
            other: items.filter { !$0.isManaged }
        )
    }

    func runContainerCenterAction(containerName: String, action: String) async throws {
        let name = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidContainerName(name) else {
            throw DockerError.commandFailed("Invalid container name.")
        }

        switch action {
        case "start":
            _ = try await executeCommand("docker", arguments: ["start", name])
        case "stop":
            _ = try await executeCommand("docker", arguments: ["stop", "-t", "5", name])
        case "restart":
            _ = try await executeCommand("docker", arguments: ["restart", "-t", "5", name])
        case "delete":
            _ = try await executeCommand("docker", arguments: ["rm", "-f", name])
        default:
            throw DockerError.commandFailed("Unknown container action.")
        }
    }

    func containerCenterLogs(containerName: String, tail: Int = 200) async throws -> String {
        let name = containerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidContainerName(name) else {
            throw DockerError.commandFailed("Invalid container name.")
        }
        return try await executeCommand("docker", arguments: [
            "logs", "--tail", "\(max(1, min(tail, 1000)))", name
        ])
    }

    func listComposeYAMLFiles() throws -> [ComposeYAMLFile] {
        let directory = try composeYAMLDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try urls
            .filter { ["yml", "yaml"].contains($0.pathExtension.lowercased()) }
            .map { url in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return ComposeYAMLFile(
                    name: url.lastPathComponent,
                    size: Int64(values.fileSize ?? 0),
                    modified: values.contentModificationDate ?? Date.distantPast
                )
            }
            .sorted {
                $0.modified > $1.modified
            }
    }

    func readComposeYAMLFile(named name: String) throws -> String {
        let url = try composeYAMLFileURL(named: name, mustExist: true)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func saveComposeYAMLFile(name: String, content: String) throws -> ComposeYAMLFile {
        let finalName = sanitizedComposeYAMLName(name)
        guard !finalName.isEmpty else {
            throw DockerError.commandFailed("Compose file name is empty.")
        }

        let formatted = normalizedComposeYAMLContent(content)
        guard !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DockerError.commandFailed("Compose content is empty.")
        }

        let url = try nextAvailableComposeYAMLURL(baseName: finalName)
        try formatted.write(to: url, atomically: true, encoding: .utf8)
        return try composeYAMLFileInfo(url)
    }

    func saveDockerRunAsComposeYAML(name: String, command: String) throws -> ComposeYAMLFile {
        let content = try dockerRunCommandToComposeYAML(command)
        return try saveComposeYAMLFile(name: name, content: content)
    }

    func updateComposeYAMLFile(named name: String, content: String) throws -> ComposeYAMLFile {
        let url = try composeYAMLFileURL(named: name, mustExist: true)
        let formatted = normalizedComposeYAMLContent(content)
        guard !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DockerError.commandFailed("Compose content is empty.")
        }
        try formatted.write(to: url, atomically: true, encoding: .utf8)
        return try composeYAMLFileInfo(url)
    }

    func copyComposeYAMLFile(named name: String) throws -> ComposeYAMLFile {
        let source = try composeYAMLFileURL(named: name, mustExist: true)
        let target = try nextAvailableComposeYAMLURL(baseName: source.deletingPathExtension().lastPathComponent + "-copy.yml")
        try FileManager.default.copyItem(at: source, to: target)
        return try composeYAMLFileInfo(target)
    }

    func renameComposeYAMLFile(named name: String, to newName: String) throws -> ComposeYAMLFile {
        let source = try composeYAMLFileURL(named: name, mustExist: true)
        let sanitized = sanitizedComposeYAMLName(newName)
        guard !sanitized.isEmpty else {
            throw DockerError.commandFailed("New Compose file name is empty.")
        }
        let target = try composeYAMLFileURL(named: sanitized, mustExist: false)
        guard source == target || !FileManager.default.fileExists(atPath: target.path) else {
            throw DockerError.commandFailed("A Compose file with this name already exists.")
        }
        try FileManager.default.moveItem(at: source, to: target)
        return try composeYAMLFileInfo(target)
    }

    func deleteComposeYAMLFile(named name: String) throws {
        let url = try composeYAMLFileURL(named: name, mustExist: true)
        try FileManager.default.removeItem(at: url)
    }

    func runComposeYAMLFile(named name: String) async throws -> String {
        let url = try composeYAMLFileURL(named: name, mustExist: true)
        if let simpleRun = try await simpleComposeDockerRunArguments(for: url) {
            return try await executeCommand("docker", arguments: ["run"] + simpleRun)
        }

        let projectName = "dockamp_cc_\(composeProjectSlug(url.deletingPathExtension().lastPathComponent))"
        return try await executeCommand("docker", arguments: [
            "compose",
            "-p", projectName,
            "-f", url.path,
            "up", "-d"
        ])
    }

    private func containerCenterManagedRoles() -> [String: String] {
        var roles: [String: String] = [:]

        for config in ConfigurationStore.shared.configurations {
            roles[config.webContainerName] = "\(config.name) · Web"
            roles[config.phpContainerName] = "\(config.name) · PHP"
            switch config.databaseAttachmentMode {
            case .none:
                break
            case .global:
                roles[Self.sharedDatabaseContainerName] = "Shared Database"
            case .dedicated:
                roles[config.dbContainerName] = "\(config.name) · Database"
            }
        }

        roles[Self.phpMyAdminContainerName] = "phpMyAdmin"
        if ProxyManagerStore.shared.settings.mode == .internal {
            roles[Self.proxyManagerContainerName] = "Proxy Manager"
        }

        return roles
    }

    private func parseContainerCenterPorts(_ rawPorts: String) -> [ContainerCenterPort] {
        let pattern = #"(?:(?:0\.0\.0\.0|\[::\]|::):)?(\d+)->(\d+)/(tcp|udp)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = rawPorts as NSString
        let matches = regex.matches(in: rawPorts, range: NSRange(location: 0, length: text.length))

        var seen = Set<ContainerCenterPort>()
        for match in matches where match.numberOfRanges == 4 {
            let port = ContainerCenterPort(
                hostPort: text.substring(with: match.range(at: 1)),
                containerPort: text.substring(with: match.range(at: 2)),
                protocolName: text.substring(with: match.range(at: 3))
            )
            seen.insert(port)
        }

        return seen.sorted { lhs, rhs in
            (Int(lhs.hostPort) ?? 0, lhs.containerPort) < (Int(rhs.hostPort) ?? 0, rhs.containerPort)
        }
    }

    private func isValidContainerName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    private func composeYAMLDirectory() throws -> URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let directory = documentsDirectory
            .appendingPathComponent("DockAMP", isDirectory: true)
            .appendingPathComponent("compose-container-center", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func composeYAMLFileURL(named name: String, mustExist: Bool) throws -> URL {
        let sanitized = sanitizedComposeYAMLName(name)
        guard sanitized.range(of: #"^[A-Za-z0-9_.-]+\.ya?ml$"#, options: .regularExpression) != nil else {
            throw DockerError.commandFailed("Invalid Compose file name.")
        }
        let url = try composeYAMLDirectory().appendingPathComponent(sanitized)
        if mustExist && !FileManager.default.fileExists(atPath: url.path) {
            throw DockerError.commandFailed("Compose file not found.")
        }
        return url
    }

    private func sanitizedComposeYAMLName(_ name: String) -> String {
        let base = URL(fileURLWithPath: name).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = base
            .replacingOccurrences(of: #"[^A-Za-z0-9_.-]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !cleaned.isEmpty else { return "" }
        if cleaned.range(of: #"\.ya?ml$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return cleaned
        }
        return cleaned + ".yml"
    }

    private func nextAvailableComposeYAMLURL(baseName: String) throws -> URL {
        let sanitized = sanitizedComposeYAMLName(baseName)
        let directory = try composeYAMLDirectory()
        let baseURL = directory.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let stem = baseURL.deletingPathExtension().lastPathComponent
        let ext = baseURL.pathExtension
        for index in 1...999 {
            let candidate = directory.appendingPathComponent("\(stem)-\(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw DockerError.commandFailed("Unable to find a free Compose file name.")
    }

    private func composeYAMLFileInfo(_ url: URL) throws -> ComposeYAMLFile {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return ComposeYAMLFile(
            name: url.lastPathComponent,
            size: Int64(values.fileSize ?? 0),
            modified: values.contentModificationDate ?? Date()
        )
    }

    private func normalizedComposeYAMLContent(_ content: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func dockerRunCommandToComposeYAML(_ command: String) throws -> String {
        var tokens = try shellTokens(command)
        if tokens.first == "docker" {
            tokens.removeFirst()
        }
        if tokens.first == "container" {
            tokens.removeFirst()
        }
        guard tokens.first == "run" else {
            throw DockerError.commandFailed("Please enter a docker run command.")
        }
        tokens.removeFirst()

        var service = DockerRunComposeService()
        let boolFlags: Set<String> = ["-d", "--detach", "--rm", "--tty", "-t", "--interactive", "-i"]
        var index = 0

        func optionParts(_ token: String) -> (key: String, value: String?) {
            if let range = token.range(of: "=") {
                return (String(token[..<range.lowerBound]), String(token[range.upperBound...]))
            }
            return (token, nil)
        }

        func nextValue(_ key: String, _ inline: String?) throws -> String {
            if let inline { return inline }
            index += 1
            guard index < tokens.count else {
                throw DockerError.commandFailed("Missing value for \(key).")
            }
            return tokens[index]
        }

        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                break
            }
            guard token.hasPrefix("-") else {
                break
            }
            let parts = optionParts(token)
            switch parts.key {
            case "--name":
                service.name = try nextValue(parts.key, parts.value)
            case "-p", "--publish":
                service.ports.append(try nextValue(parts.key, parts.value))
            case "-v", "--volume":
                service.volumes.append(normalizeDockerRunVolumeSpec(try nextValue(parts.key, parts.value)))
            case "--mount":
                service.volumes.append(dockerRunMountToCompose(try nextValue(parts.key, parts.value)))
            case "-e", "--env":
                service.environment.append(try nextValue(parts.key, parts.value))
            case "--env-file":
                service.envFile.append(expandHomePath(try nextValue(parts.key, parts.value)))
            case "--dns":
                service.dns.append(try nextValue(parts.key, parts.value))
            case "--restart":
                service.restart = try nextValue(parts.key, parts.value)
            case "--network", "--net":
                let network = try nextValue(parts.key, parts.value)
                if ["bridge", "host", "none"].contains(network) || network.hasPrefix("container:") {
                    service.networkMode = network
                } else {
                    service.networks.append(network)
                }
            case "--add-host":
                service.extraHosts.append(try nextValue(parts.key, parts.value))
            case "--hostname", "-h":
                service.hostname = try nextValue(parts.key, parts.value)
            case "--label", "-l":
                service.labels.append(try nextValue(parts.key, parts.value))
            case "--user", "-u":
                service.user = try nextValue(parts.key, parts.value)
            case "--workdir", "-w":
                service.workingDir = try nextValue(parts.key, parts.value)
            case "--entrypoint":
                service.entrypoint = try nextValue(parts.key, parts.value)
            case "--health-cmd":
                service.healthcheck["test"] = ["CMD-SHELL", try nextValue(parts.key, parts.value)]
            case "--health-interval":
                service.healthcheck["interval"] = try nextValue(parts.key, parts.value)
            case "--health-timeout":
                service.healthcheck["timeout"] = try nextValue(parts.key, parts.value)
            case "--health-retries":
                service.healthcheck["retries"] = try nextValue(parts.key, parts.value)
            case "--health-start-period":
                service.healthcheck["start_period"] = try nextValue(parts.key, parts.value)
            case "--no-healthcheck":
                service.healthcheck["disable"] = true
            case "--cpus":
                service.cpus = try nextValue(parts.key, parts.value)
            case "--memory", "-m":
                service.memLimit = try nextValue(parts.key, parts.value)
            case "--privileged":
                service.privileged = true
            case "--read-only":
                service.readOnly = true
            case "--tmpfs":
                service.tmpfs.append(try nextValue(parts.key, parts.value))
            case "--shm-size":
                service.shmSize = try nextValue(parts.key, parts.value)
            case "--init":
                service.initEnabled = true
            case "--platform":
                service.platform = try nextValue(parts.key, parts.value)
            default:
                if !boolFlags.contains(parts.key), parts.value == nil, index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    index += 1
                }
            }
            index += 1
        }

        guard index < tokens.count else {
            throw DockerError.commandFailed("No image found in docker run command.")
        }

        service.image = tokens[index]
        service.command = Array(tokens.dropFirst(index + 1))
        return composeYAML(from: service)
    }

    private func composeYAML(from service: DockerRunComposeService) -> String {
        let serviceName = composeProjectSlug(
            service.name.isEmpty
                ? service.image.split(separator: "/").last?.split(separator: ":").first.map(String.init) ?? "container"
                : service.name
        )
        var lines = [
            "services:",
            "  \(composeScalar(serviceName)):",
            "    image: \(composeScalar(service.image))"
        ]
        if !service.name.isEmpty { lines.append("    container_name: \(composeScalar(service.name))") }
        if !service.restart.isEmpty { lines.append("    restart: \(composeScalar(service.restart))") }

        let scalarPairs = [
            ("hostname", service.hostname),
            ("user", service.user),
            ("working_dir", service.workingDir),
            ("entrypoint", service.entrypoint),
            ("cpus", service.cpus),
            ("mem_limit", service.memLimit),
            ("shm_size", service.shmSize),
            ("platform", service.platform)
        ]
        for (key, value) in scalarPairs where !value.isEmpty {
            lines.append("    \(key): \(composeScalar(value))")
        }

        appendYAMLList("ports", service.ports, to: &lines)
        appendYAMLList("volumes", service.volumes, to: &lines)
        appendYAMLList("environment", service.environment, to: &lines)
        appendYAMLList("env_file", service.envFile, to: &lines)
        appendYAMLList("dns", service.dns, to: &lines)
        appendYAMLList("extra_hosts", service.extraHosts, to: &lines)
        appendYAMLList("labels", service.labels, to: &lines)
        appendYAMLList("tmpfs", service.tmpfs, to: &lines)

        if !service.networkMode.isEmpty {
            lines.append("    network_mode: \(composeScalar(service.networkMode))")
        }
        appendYAMLList("networks", service.networks, to: &lines)

        if service.privileged { lines.append("    privileged: true") }
        if service.readOnly { lines.append("    read_only: true") }
        if service.initEnabled { lines.append("    init: true") }
        if !service.healthcheck.isEmpty {
            lines.append("    healthcheck:")
            appendYAMLDictionary(service.healthcheck, indent: 6, to: &lines)
        }
        if !service.command.isEmpty {
            lines.append("    command: \(composeScalar(service.command.joined(separator: " ")))")
        }
        if !service.networks.isEmpty {
            lines.append("networks:")
            for network in service.networks {
                lines.append("  \(composeScalar(network)):")
                lines.append("    external: true")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func appendYAMLList(_ key: String, _ values: [String], to lines: inout [String]) {
        guard !values.isEmpty else { return }
        lines.append("    \(key):")
        for value in values {
            lines.append("      - \(composeScalar(value))")
        }
    }

    private func appendYAMLDictionary(_ dict: [String: Any], indent: Int, to lines: inout [String]) {
        let space = String(repeating: " ", count: indent)
        for key in dict.keys.sorted() {
            let value = dict[key]
            if let array = value as? [String] {
                lines.append("\(space)\(key):")
                for item in array {
                    lines.append("\(space)  - \(composeScalar(item))")
                }
            } else if let bool = value as? Bool {
                lines.append("\(space)\(key): \(bool ? "true" : "false")")
            } else if let text = value {
                lines.append("\(space)\(key): \(composeScalar("\(text)"))")
            }
        }
    }

    private func composeScalar(_ value: String) -> String {
        guard !value.isEmpty else { return "\"\"" }
        if value.range(of: #"^[A-Za-z0-9_./:@-]+$"#, options: .regularExpression) != nil {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func shellTokens(_ command: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaped = false

        for character in command.replacingOccurrences(of: "\\\n", with: " ") {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }

        if quote != nil {
            throw DockerError.commandFailed("Unclosed quote in docker run command.")
        }
        if isEscaped {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        guard !tokens.isEmpty else {
            throw DockerError.commandFailed("Docker run command is empty.")
        }
        return tokens
    }

    private func normalizeDockerRunVolumeSpec(_ spec: String) -> String {
        if spec == "~" || spec.hasPrefix("~/") {
            return expandHomePath(spec)
        }
        if spec.hasPrefix("~/"), let colon = spec.firstIndex(of: ":") {
            let source = String(spec[..<colon])
            let rest = String(spec[colon...])
            return expandHomePath(source) + rest
        }
        return spec
    }

    private func dockerRunMountToCompose(_ spec: String) -> String {
        let parts = spec.split(separator: ",").reduce(into: [String: String]()) { result, chunk in
            let pair = chunk.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                result[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let target = parts["target"] ?? parts["dst"] ?? parts["destination"] else {
            return spec
        }
        let source = parts["source"] ?? parts["src"] ?? parts["from"]
        let readOnly = ["true", "1", "yes"].contains((parts["readonly"] ?? parts["ro"] ?? "").lowercased())
        if let source {
            return "\(expandHomePath(source)):\(target)\(readOnly ? ":ro" : "")"
        }
        return spec
    }

    private func expandHomePath(_ value: String) -> String {
        if value == "~" { return NSHomeDirectory() }
        if value.hasPrefix("~/") {
            return NSHomeDirectory() + String(value.dropFirst())
        }
        return value
    }

    private func composeProjectSlug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return slug.isEmpty ? "compose" : slug
    }

    private func simpleComposeDockerRunArguments(for url: URL) async throws -> [String]? {
        let raw = try await executeCommand("docker", arguments: [
            "compose",
            "-f", url.path,
            "config",
            "--format", "json",
            "--no-interpolate",
            "--no-normalize",
            "--no-path-resolution"
        ])

        guard
            let data = raw.data(using: .utf8),
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            isSimpleComposeContainer(root),
            let services = root["services"] as? [String: Any],
            let first = services.first,
            let service = first.value as? [String: Any],
            let image = nonEmptyString(service["image"])
        else {
            return nil
        }

        let containerName = nonEmptyString(service["container_name"])
            ?? composeProjectSlug(url.deletingPathExtension().lastPathComponent)
        var args = ["-d", "--name", containerName]

        appendOption("--restart", service["restart"], to: &args)
        appendOption("--hostname", service["hostname"], to: &args)
        appendOption("--user", service["user"], to: &args)
        appendOption("--workdir", service["working_dir"], to: &args)
        appendOption("--entrypoint", service["entrypoint"], to: &args)
        appendOption("--cpus", service["cpus"], to: &args)
        appendOption("--memory", service["mem_limit"], to: &args)
        appendOption("--shm-size", service["shm_size"], to: &args)
        appendOption("--platform", service["platform"], to: &args)

        for item in service["ports"] as? [Any] ?? [] {
            if let spec = composePortRunArgument(item), !spec.isEmpty {
                args += ["-p", spec]
            }
        }

        for item in service["volumes"] as? [Any] ?? [] {
            if let spec = composeVolumeRunArgument(item), !spec.isEmpty {
                args += ["-v", spec]
            }
        }

        appendList("-e", service["environment"], to: &args)
        appendList("--env-file", service["env_file"], to: &args)
        appendList("--dns", service["dns"], to: &args)
        appendList("--add-host", service["extra_hosts"], to: &args)
        appendList("--label", service["labels"], to: &args)
        appendList("--tmpfs", service["tmpfs"], to: &args)
        appendOption("--network", service["network_mode"], to: &args)

        if service["privileged"] as? Bool == true { args.append("--privileged") }
        if service["read_only"] as? Bool == true { args.append("--read-only") }
        if service["init"] as? Bool == true { args.append("--init") }
        args += composeHealthcheckRunArguments(service["healthcheck"])

        args.append(image)
        if let command = service["command"] as? [Any] {
            args += command.map { "\($0)" }
        } else if let command = nonEmptyString(service["command"]) {
            args += ["sh", "-c", command]
        }

        return args
    }

    private func isSimpleComposeContainer(_ root: [String: Any]) -> Bool {
        guard let services = root["services"] as? [String: Any], services.count == 1 else {
            return false
        }
        for key in ["volumes", "networks", "configs", "secrets"] where hasMeaningfulValue(root[key]) {
            return false
        }
        guard let service = services.first?.value as? [String: Any] else {
            return false
        }
        for key in ["depends_on", "links", "extends", "profiles", "networks"] where hasMeaningfulValue(service[key]) {
            return false
        }
        return nonEmptyString(service["image"]) != nil
    }

    private func composePortRunArgument(_ item: Any) -> String? {
        if let text = item as? String { return text }
        guard let dict = item as? [String: Any], let target = nonEmptyString(dict["target"]) else {
            return nil
        }
        var spec = target
        if let published = nonEmptyString(dict["published"]) {
            spec = "\(published):\(target)"
            if let hostIP = nonEmptyString(dict["host_ip"]) ?? nonEmptyString(dict["hostIp"]) {
                spec = "\(hostIP):\(spec)"
            }
        }
        if let proto = nonEmptyString(dict["protocol"]), proto != "tcp" {
            spec += "/\(proto)"
        }
        return spec
    }

    private func composeVolumeRunArgument(_ item: Any) -> String? {
        if let text = item as? String { return text }
        guard let dict = item as? [String: Any], let target = nonEmptyString(dict["target"]) else {
            return nil
        }
        let type = nonEmptyString(dict["type"])
        guard type == nil || type == "bind" || type == "volume" else {
            return nil
        }
        guard let source = nonEmptyString(dict["source"]) else {
            return nil
        }
        let isReadOnly = dict["read_only"] as? Bool == true || nonEmptyString(dict["mode"]) == "ro"
        return "\(source):\(target)\(isReadOnly ? ":ro" : "")"
    }

    private func composeHealthcheckRunArguments(_ value: Any?) -> [String] {
        guard let dict = value as? [String: Any], !dict.isEmpty else { return [] }
        if dict["disable"] as? Bool == true { return ["--no-healthcheck"] }

        var args: [String] = []
        if let test = dict["test"] as? [Any], let first = test.first.map({ "\($0)".uppercased() }),
           first == "CMD" || first == "CMD-SHELL" {
            args += ["--health-cmd", test.dropFirst().map { "\($0)" }.joined(separator: " ")]
        } else if let test = nonEmptyString(dict["test"]) {
            args += ["--health-cmd", test]
        }

        let mapping = [
            ("interval", "--health-interval"),
            ("timeout", "--health-timeout"),
            ("retries", "--health-retries"),
            ("start_period", "--health-start-period")
        ]
        for (source, flag) in mapping {
            appendOption(flag, dict[source], to: &args)
        }
        return args
    }

    private func appendOption(_ flag: String, _ value: Any?, to args: inout [String]) {
        guard let text = nonEmptyString(value) else { return }
        args += [flag, text]
    }

    private func appendList(_ flag: String, _ value: Any?, to args: inout [String]) {
        if let dict = value as? [String: Any] {
            for key in dict.keys.sorted() {
                args += [flag, "\(key)=\(dict[key] ?? "")"]
            }
            return
        }
        for item in value as? [Any] ?? [] {
            if let dict = item as? [String: Any], let path = nonEmptyString(dict["path"]) {
                args += [flag, path]
            } else if let text = nonEmptyString(item) {
                args += [flag, text]
            }
        }
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let text = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func hasMeaningfulValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let array = value as? [Any] { return !array.isEmpty }
        if let dict = value as? [String: Any] { return !dict.isEmpty }
        if let text = value as? String { return !text.isEmpty }
        if value is NSNull { return false }
        return true
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

    func managedImageUpdateItems() async throws -> [ManagedImageInfo] {
        let targets = managedImageTargets()
        var items: [ManagedImageInfo] = []

        for target in targets.sorted(by: { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) {
            let imageID = try? await executeCommand("docker", arguments: [
                "image", "inspect",
                target.reference,
                "--format", "{{.Id}}"
            ]).trimmingCharacters(in: .whitespacesAndNewlines)

            items.append(
                ManagedImageInfo(
                    id: target.reference,
                    label: target.label,
                    reference: target.reference,
                    usedBy: target.usedBy.sorted(),
                    status: (imageID?.isEmpty == false) ? .installed : .missing,
                    localImageID: imageID?.isEmpty == false ? imageID : nil
                )
            )
        }

        return items
    }

    func updateManagedImages(references: [String]) async throws {
        let uniqueReferences = Array(Set(references)).sorted()
        guard !uniqueReferences.isEmpty else { return }

        for reference in uniqueReferences {
            _ = try await executeCommand("docker", arguments: ["pull", reference])
        }
    }

    func unusedImages() async throws -> [DockerImageCleanupItem] {
        let output = try await executeCommand("docker", arguments: [
            "images",
            "--no-trunc",
            "--filter", "dangling=true",
            "--format", "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"
        ])

        return output
            .components(separatedBy: .newlines)
            .compactMap { line -> DockerImageCleanupItem? in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 5 else { return nil }
                return DockerImageCleanupItem(
                    id: parts[0],
                    repository: parts[1],
                    tag: parts[2],
                    imageID: parts[0],
                    size: parts[3],
                    createdSince: parts[4]
                )
            }
    }

    func removeUnusedImage(id: String) async throws {
        _ = try await executeCommand("docker", arguments: ["image", "rm", id])
    }

    func pruneUnusedImages() async throws {
        _ = try await executeCommand("docker", arguments: ["image", "prune", "-f"])
    }

    func unusedVolumes() async throws -> [DockerVolumeCleanupItem] {
        let namesOutput = try await executeCommand("docker", arguments: [
            "volume", "ls",
            "--filter", "dangling=true",
            "--format", "{{.Name}}"
        ])

        let names = namesOutput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var volumes: [DockerVolumeCleanupItem] = []
        for name in names {
            let inspect = (try? await executeCommand("docker", arguments: [
                "volume", "inspect",
                name,
                "--format", "{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}"
            ]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? "\(name)\t\t"
            let parts = inspect.components(separatedBy: "\t")
            volumes.append(
                DockerVolumeCleanupItem(
                    id: name,
                    name: parts.indices.contains(0) ? parts[0] : name,
                    driver: parts.indices.contains(1) ? parts[1] : "",
                    mountpoint: parts.indices.contains(2) ? parts[2] : ""
                )
            )
        }

        return volumes
    }

    func removeUnusedVolume(name: String) async throws {
        _ = try await executeCommand("docker", arguments: ["volume", "rm", name])
    }

    func containerDirectories(for config: ServerConfiguration, path: String) async throws -> ContainerDirectoryListing {
        let normalizedPath = normalizeContainerPath(path)
        let command = "find \"$1\" -mindepth 1 -maxdepth 1 -type d -exec basename {} \\; 2>/dev/null | sort -f; exit 0"
        let webStatus = await getContainerStatus(config.webContainerName)
        let output: String

        if webStatus == .running {
            output = try await executeCommand("docker", arguments: [
                "exec",
                config.webContainerName,
                "sh",
                "-c",
                command,
                "dockamp-container-browser",
                normalizedPath
            ])
        } else {
            let image = "\(config.webServerType.dockerImage):latest"
            output = try await executeCommand("docker", arguments: [
                "run",
                "--rm",
                "--entrypoint", "sh",
                image,
                "-c",
                command,
                "dockamp-container-browser",
                normalizedPath
            ])
        }

        let directories = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("/") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return ContainerDirectoryListing(
            path: normalizedPath,
            parent: normalizedPath == "/" ? nil : parentContainerPath(normalizedPath),
            directories: directories
        )
    }

    private struct ManagedImageTarget {
        var label: String
        var reference: String
        var usedBy: Set<String>
    }

    private func managedImageTargets() -> [ManagedImageTarget] {
        var targets: [String: ManagedImageTarget] = [:]

        func add(_ reference: String, label: String, usedBy: String) {
            let trimmedReference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedReference.isEmpty else { return }

            if var existing = targets[trimmedReference] {
                existing.usedBy.insert(usedBy)
                targets[trimmedReference] = existing
            } else {
                targets[trimmedReference] = ManagedImageTarget(
                    label: label,
                    reference: trimmedReference,
                    usedBy: [usedBy]
                )
            }
        }

        for config in ConfigurationStore.shared.configurations {
            add("\(config.webServerType.dockerImage):latest", label: "\(config.webServerType.rawValue) Web Server", usedBy: config.name)
            add(config.phpDockerImage, label: "PHP \(config.phpVersion)", usedBy: config.name)

            if requiresCustomPHPRuntimeImage(settings: config.phpSettings) {
                let signature = phpRuntimeSignature(baseImage: config.phpDockerImage, settings: config.phpSettings)
                add("dockamp-php-runtime:\(signature)", label: "DockAMP PHP Runtime", usedBy: config.name)
            }

            switch config.databaseAttachmentMode {
            case .none:
                break
            case .global:
                let shared = SharedDatabaseStore.shared.settings
                add("\(shared.databaseType.dockerImage):latest", label: "\(shared.databaseType.rawValue) Global Database", usedBy: "Global Database")
            case .dedicated:
                add("\(config.databaseType.dockerImage):latest", label: "\(config.databaseType.rawValue) Dedicated Database", usedBy: config.name)
            }
        }

        add("phpmyadmin:latest", label: "phpMyAdmin", usedBy: "Database Admin")
        add("jc21/nginx-proxy-manager:latest", label: "Nginx Proxy Manager", usedBy: "Proxy Manager")

        return Array(targets.values)
    }

    private func normalizeContainerPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let absolute = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        let parts = absolute
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .reduce(into: [Substring]()) { result, part in
                if part == ".." {
                    _ = result.popLast()
                } else {
                    result.append(part)
                }
            }
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func parentContainerPath(_ path: String) -> String {
        let normalized = normalizeContainerPath(path)
        guard normalized != "/" else { return "/" }
        let url = URL(fileURLWithPath: normalized)
        let parent = url.deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }
    
    // MARK: - Logs
    
    func getContainerLogs(_ containerName: String, tail: Int = 100) async throws -> String {
        let escapedContainerName = escapeForSingleQuotedShell(containerName)
        let command = "docker logs --tail \(tail) '\(escapedContainerName)' 2>&1"
        return try await executeCommand("sh", arguments: ["-lc", command])
    }

    func liveVisitorActivity(for configs: [ServerConfiguration]) async throws -> [LiveVisitorServerActivity] {
        var activities: [LiveVisitorServerActivity] = []

        for config in configs {
            let containerName = config.webContainerName
            let status = await getContainerStatus(containerName)
            guard status == .running else { continue }

            let logs = (try? await getContainerLogs(containerName, tail: 300)) ?? ""
            let rate = await containerNetworkRate(containerName)
            let visitors = activeVisitors(from: logs)

            activities.append(LiveVisitorServerActivity(
                id: config.id,
                serverName: config.name,
                webPort: config.webServerPort,
                containerName: containerName,
                status: status,
                rxRate: rate.rx,
                txRate: rate.tx,
                activeVisitors: visitors
            ))
        }

        return activities.sorted {
            if $0.activeVisitors.count != $1.activeVisitors.count {
                return $0.activeVisitors.count > $1.activeVisitors.count
            }
            return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
        }
    }

    private func activeVisitors(from logs: String) -> [LiveVisitorEntry] {
        let cutoff = Date().addingTimeInterval(-300)
        var visitors: [String: ParsedAccessLogEntry] = [:]
        var requestCounts: [String: Int] = [:]

        for line in logs.split(separator: "\n").map(String.init) {
            guard let entry = parseAccessLogLine(line), entry.timestamp >= cutoff else { continue }
            let key = "\(entry.ip)|\(entry.userAgent)"
            requestCounts[key, default: 0] += 1
            if let current = visitors[key], current.timestamp > entry.timestamp {
                continue
            }
            visitors[key] = entry
        }

        let now = Date()
        return visitors
            .map { key, entry in
                LiveVisitorEntry(
                    ip: entry.ip,
                    userAgent: entry.userAgent,
                    method: entry.method,
                    path: entry.path,
                    status: entry.status,
                    lastSeenSecondsAgo: max(0, Int(now.timeIntervalSince(entry.timestamp))),
                    requests: requestCounts[key, default: 1]
                )
            }
            .sorted { $0.lastSeenSecondsAgo < $1.lastSeenSecondsAgo }
    }

    private func parseAccessLogLine(_ line: String) -> ParsedAccessLogEntry? {
        let pattern = #"^(\S+) \S+ \S+ \[([^\]]+)\] "([A-Z]+) (\S+)[^"]*" (\d{3}) (\S+)(?: "([^"]*)" "([^"]*)")?(?: "([^"]*)" "([^"]*)")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }

        func group(_ index: Int) -> String {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: line) else { return "" }
            return String(line[range])
        }

        var ip = group(1)
        for candidate in [group(9), group(10)] {
            let forwardedIP = candidate.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            if !forwardedIP.isEmpty && forwardedIP != "-" {
                ip = forwardedIP
                break
            }
        }

        let timestamp = parseAccessLogDate(group(2)) ?? Date()
        return ParsedAccessLogEntry(
            ip: ip,
            timestamp: timestamp,
            method: group(3),
            path: group(4),
            status: group(5),
            userAgent: group(8)
        )
    }

    private func parseAccessLogDate(_ rawValue: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MMM/yyyy:HH:mm:ss Z"
        return formatter.date(from: rawValue)
    }

    private func containerNetworkRate(_ containerName: String) async -> (rx: String, tx: String) {
        guard let output = try? await executeCommand("docker", arguments: [
            "stats",
            "--no-stream",
            "--format", "{{.NetIO}}",
            containerName
        ]) else {
            return ("0 B/s", "0 B/s")
        }

        let parts = output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2 else { return ("0 B/s", "0 B/s") }

        let now = Date()
        let rxBytes = parseDockerByteSize(parts[0])
        let txBytes = parseDockerByteSize(parts[1])
        let previous = netStatsCache[containerName]
        netStatsCache[containerName] = (now, rxBytes, txBytes)

        guard let previous else {
            return ("0 B/s", "0 B/s")
        }

        let elapsed = max(now.timeIntervalSince(previous.date), 0.001)
        let rxRate = max(0, (rxBytes - previous.rxBytes) / elapsed)
        let txRate = max(0, (txBytes - previous.txBytes) / elapsed)
        return (formatByteRate(rxRate), formatByteRate(txRate))
    }

    private func parseDockerByteSize(_ value: String) -> Double {
        let compact = value.replacingOccurrences(of: " ", with: "")
        let pattern = #"^([0-9.]+)([A-Za-z]+)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: compact, range: NSRange(compact.startIndex..., in: compact)),
              let numberRange = Range(match.range(at: 1), in: compact) else {
            return 0
        }

        let number = Double(compact[numberRange]) ?? 0
        let unit: String
        if let unitRange = Range(match.range(at: 2), in: compact) {
            unit = String(compact[unitRange]).lowercased()
        } else {
            unit = "b"
        }

        let factors: [String: Double] = [
            "b": 1,
            "kb": 1_000,
            "mb": 1_000_000,
            "gb": 1_000_000_000,
            "tb": 1_000_000_000_000,
            "kib": 1_024,
            "mib": 1_048_576,
            "gib": 1_073_741_824,
            "tib": 1_099_511_627_776
        ]

        return number * (factors[unit] ?? 1)
    }

    private func formatByteRate(_ bytesPerSecond: Double) -> String {
        var value = max(0, bytesPerSecond)
        for unit in ["B/s", "KB/s", "MB/s", "GB/s"] {
            if value < 1_000 || unit == "GB/s" {
                if unit == "B/s" {
                    return "\(Int(value)) \(unit)"
                }
                return String(format: "%.1f %@", value, unit)
            }
            value /= 1_000
        }
        return "0 B/s"
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

private struct ParsedAccessLogEntry {
    let ip: String
    let timestamp: Date
    let method: String
    let path: String
    let status: String
    let userAgent: String
}

private struct DockerPSRow: Decodable {
    let names: String
    let image: String
    let state: String
    let status: String
    let ports: String

    private enum CodingKeys: String, CodingKey {
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case ports = "Ports"
    }
}

private struct DockerRunComposeService {
    var name = ""
    var image = ""
    var ports: [String] = []
    var volumes: [String] = []
    var environment: [String] = []
    var envFile: [String] = []
    var dns: [String] = []
    var restart = ""
    var networkMode = ""
    var networks: [String] = []
    var extraHosts: [String] = []
    var labels: [String] = []
    var hostname = ""
    var user = ""
    var workingDir = ""
    var entrypoint = ""
    var healthcheck: [String: Any] = [:]
    var cpus = ""
    var memLimit = ""
    var privileged = false
    var readOnly = false
    var tmpfs: [String] = []
    var shmSize = ""
    var initEnabled = false
    var platform = ""
    var command: [String] = []
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
