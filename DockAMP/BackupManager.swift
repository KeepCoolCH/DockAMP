import Foundation
import Combine

struct DockAMPBackupManifest: Codable {
    var version: Int
    var createdAt: Date
    var servers: [BackupServerEntry]
    var includesConfiguration: Bool
    var includesDocumentRoots: Bool
    var includesDatabaseDumps: Bool
    var databaseDumps: [BackupDatabaseDumpEntry]

    init(
        version: Int,
        createdAt: Date,
        servers: [BackupServerEntry],
        includesConfiguration: Bool,
        includesDocumentRoots: Bool,
        includesDatabaseDumps: Bool,
        databaseDumps: [BackupDatabaseDumpEntry]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.servers = servers
        self.includesConfiguration = includesConfiguration
        self.includesDocumentRoots = includesDocumentRoots
        self.includesDatabaseDumps = includesDatabaseDumps
        self.databaseDumps = databaseDumps
    }

    private enum CodingKeys: String, CodingKey {
        case version, createdAt, servers, includesConfiguration, includesDocumentRoots, includesDatabaseDumps, databaseDumps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        servers = try container.decode([BackupServerEntry].self, forKey: .servers)
        includesConfiguration = try container.decode(Bool.self, forKey: .includesConfiguration)
        includesDocumentRoots = try container.decode(Bool.self, forKey: .includesDocumentRoots)
        includesDatabaseDumps = try container.decodeIfPresent(Bool.self, forKey: .includesDatabaseDumps) ?? false
        databaseDumps = try container.decodeIfPresent([BackupDatabaseDumpEntry].self, forKey: .databaseDumps) ?? []
    }
}

struct BackupServerEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var documentRoot: String
}

struct BackupDatabaseDumpEntry: Codable, Identifiable, Hashable {
    var id: UUID { serverID }
    var serverID: UUID
    var serverName: String
    var databaseType: DatabaseType
    var attachmentMode: DatabaseAttachmentMode
    var databaseName: String
    var relativePath: String
}

struct BackupArchiveInfo: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let createdAt: Date?
    let size: Int64

    var displayName: String { url.lastPathComponent }
}

struct RestorePreview: Identifiable {
    var id: String { archiveURL.path }
    let archiveURL: URL
    let manifest: DockAMPBackupManifest
}

enum BackupInterval: String, CaseIterable, Codable, Identifiable {
    case manual
    case daily
    case weekly
    case monthly

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.manual.rawValue:
            self = .manual
        case Self.daily.rawValue:
            self = .daily
        case Self.weekly.rawValue:
            self = .weekly
        case Self.monthly.rawValue, "yearly":
            self = .monthly
        default:
            self = .manual
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "Manual only"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    var dueInterval: TimeInterval? {
        switch self {
        case .manual: return nil
        case .daily: return 86_400
        case .weekly: return 604_800
        case .monthly: return 2_592_000
        }
    }
}

struct BackupSettings: Codable, Hashable {
    var interval: BackupInterval = .manual
    var retention: Int = 7
    var includeConfiguration: Bool = true
    var includeDocumentRoots: Bool = true
    var includeDatabaseDumps: Bool = true
    var lastRun: Date?
    var lastStatus: String = ""
    var lastError: String = ""
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    @Published private(set) var settings = BackupSettings()

    private let fileManager = FileManager.default
    private let appDirectory: URL
    private let backupDirectory: URL
    private let settingsURL: URL
    private var schedulerTask: Task<Void, Never>?
    private var isAutomaticBackupRunning = false

    private init() {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        appDirectory = documentsDirectory.appendingPathComponent("DockAMP", isDirectory: true)
        backupDirectory = appDirectory.appendingPathComponent("backups", isDirectory: true)
        settingsURL = appDirectory.appendingPathComponent("backup_settings.json")
        try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        loadSettings()
    }

    func listBackups() -> [BackupArchiveInfo] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "gz" && $0.lastPathComponent.hasPrefix("dockamp-backup-") }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                return BackupArchiveInfo(
                    url: url,
                    createdAt: values?.creationDate,
                    size: Int64(values?.fileSize ?? 0)
                )
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    func updateSettings(_ updated: BackupSettings) {
        var normalized = updated
        normalized.retention = max(1, normalized.retention)
        settings = normalized
        saveSettings()
    }

    func startAutomaticBackups() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runAutomaticBackupIfDue()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func runAutomaticBackupIfDue() async {
        guard !isAutomaticBackupRunning, let dueInterval = settings.interval.dueInterval else { return }
        let lastRun = settings.lastRun ?? .distantPast
        guard Date().timeIntervalSince(lastRun) >= dueInterval else { return }

        isAutomaticBackupRunning = true
        defer { isAutomaticBackupRunning = false }

        do {
            let archive = try await createBackup(
                includeConfiguration: settings.includeConfiguration,
                includeDocumentRoots: settings.includeDocumentRoots,
                includeDatabaseDumps: settings.includeDatabaseDumps
            )
            try pruneBackups(keeping: settings.retention)
            settings.lastRun = Date()
            settings.lastStatus = "Created \(archive.lastPathComponent)"
            settings.lastError = ""
            saveSettings()
        } catch {
            settings.lastRun = Date()
            settings.lastStatus = "Failed"
            settings.lastError = error.localizedDescription
            saveSettings()
        }
    }

    func createBackup(includeConfiguration: Bool, includeDocumentRoots: Bool, includeDatabaseDumps: Bool) async throws -> URL {
        let stamp = Self.timestamp()
        let backupRootName = "dockamp-backup-\(stamp)"
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("dockamp-backup-\(stamp)-\(UUID().uuidString)", isDirectory: true)
        let backupRoot = stagingRoot.appendingPathComponent(backupRootName, isDirectory: true)
        let configTarget = backupRoot.appendingPathComponent("config", isDirectory: true)
        let rootsTarget = backupRoot.appendingPathComponent("document-roots", isDirectory: true)
        let databasesTarget = backupRoot.appendingPathComponent("databases", isDirectory: true)
        try fileManager.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let configs = ConfigurationStore.shared.configurations
        var databaseDumps: [BackupDatabaseDumpEntry] = []

        if includeDatabaseDumps {
            try fileManager.createDirectory(at: databasesTarget, withIntermediateDirectories: true)
            databaseDumps = try await createDatabaseDumps(for: configs, in: databasesTarget)
        }

        let manifest = DockAMPBackupManifest(
            version: 1,
            createdAt: Date(),
            servers: configs.map {
                BackupServerEntry(id: $0.id, name: $0.name, documentRoot: $0.webServerDocumentRoot)
            },
            includesConfiguration: includeConfiguration,
            includesDocumentRoots: includeDocumentRoots,
            includesDatabaseDumps: includeDatabaseDumps,
            databaseDumps: databaseDumps
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: backupRoot.appendingPathComponent("manifest.json"))

        if includeConfiguration, fileManager.fileExists(atPath: appDirectory.path) {
            try fileManager.createDirectory(at: configTarget, withIntermediateDirectories: true)
            for item in try fileManager.contentsOfDirectory(at: appDirectory, includingPropertiesForKeys: nil) {
                guard item.lastPathComponent != "backups" else { continue }
                try copyReplacing(from: item, to: configTarget.appendingPathComponent(item.lastPathComponent))
            }
        }

        if includeDocumentRoots {
            try fileManager.createDirectory(at: rootsTarget, withIntermediateDirectories: true)
            for config in configs {
                let source = URL(fileURLWithPath: config.webServerDocumentRoot, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = rootsTarget.appendingPathComponent(config.id.uuidString, isDirectory: true)
                try copyReplacing(from: source, to: target)
            }
        }

        let archiveURL = backupDirectory.appendingPathComponent("dockamp-backup-\(stamp).tar.gz")
        try await run("/usr/bin/tar", arguments: [
            "-czf",
            archiveURL.path,
            "-C",
            stagingRoot.path,
            backupRootName
        ])
        try? fileManager.removeItem(at: stagingRoot)
        return archiveURL
    }

    func exportBackup(_ backup: BackupArchiveInfo, to destination: URL) throws {
        try copyReplacing(from: backup.url, to: destination.appendingPathComponent(backup.url.lastPathComponent))
    }

    func previewRestore(from archiveURL: URL) async throws -> RestorePreview {
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("dockamp-restore-preview-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", arguments: ["-xzf", archiveURL.path, "-C", stagingRoot.path])
        let backupRoot = try backupRoot(in: stagingRoot)
        let manifestURL = backupRoot.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DockAMPBackupManifest.self, from: data)
        try? fileManager.removeItem(at: stagingRoot)
        return RestorePreview(archiveURL: archiveURL, manifest: manifest)
    }

    func restore(_ preview: RestorePreview, restoreConfiguration: Bool, restoreDocumentRoots: Bool, restoreDatabaseDumps: Bool) async throws {
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("dockamp-restore-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", arguments: ["-xzf", preview.archiveURL.path, "-C", stagingRoot.path])
        let backupRoot = try backupRoot(in: stagingRoot)

        if restoreConfiguration {
            let configSource = backupRoot.appendingPathComponent("config", isDirectory: true)
            if fileManager.fileExists(atPath: configSource.path) {
                try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
                for item in try fileManager.contentsOfDirectory(at: configSource, includingPropertiesForKeys: nil) {
                    try copyReplacing(from: item, to: appDirectory.appendingPathComponent(item.lastPathComponent))
                }
            }
        }

        if restoreDocumentRoots {
            let rootsSource = backupRoot.appendingPathComponent("document-roots", isDirectory: true)
            for server in preview.manifest.servers {
                let source = rootsSource.appendingPathComponent(server.id.uuidString, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: server.documentRoot, isDirectory: true)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try copyReplacing(from: source, to: destination)
            }
        }

        if restoreConfiguration {
            ConfigurationStore.shared.loadConfigurations()
        }

        if restoreDatabaseDumps {
            try await importDatabaseDumps(preview.manifest.databaseDumps, from: backupRoot)
        }

        try? fileManager.removeItem(at: stagingRoot)

        ConfigurationStore.shared.loadConfigurations()
        if let first = ConfigurationStore.shared.configurations.first {
            ConfigurationStore.shared.selectedConfiguration = first
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func loadSettings() {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try JSONDecoder().decode(BackupSettings.self, from: data)
        } catch {
            settings = BackupSettings()
        }
    }

    private func saveSettings() {
        do {
            try fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(settings)
            try data.write(to: settingsURL)
        } catch {
            print("Error saving backup settings: \(error)")
        }
    }

    private func pruneBackups(keeping count: Int) throws {
        let backups = listBackups()
        guard backups.count > count else { return }
        for backup in backups.dropFirst(count) {
            try fileManager.removeItem(at: backup.url)
        }
    }

    private func backupRoot(in stagingRoot: URL) throws -> URL {
        let legacyPayload = stagingRoot.appendingPathComponent("payload", isDirectory: true)
        if fileManager.fileExists(atPath: legacyPayload.appendingPathComponent("manifest.json").path) {
            return legacyPayload
        }

        let contents = try fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
        if let backupRoot = contents.first(where: {
            $0.lastPathComponent.hasPrefix("dockamp-backup-")
                && fileManager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path)
        }) {
            return backupRoot
        }

        throw DockerError.commandFailed("Backup manifest not found.")
    }

    private func createDatabaseDumps(for configs: [ServerConfiguration], in targetDirectory: URL) async throws -> [BackupDatabaseDumpEntry] {
        var dumps: [BackupDatabaseDumpEntry] = []

        for config in configs where config.databaseAttachmentMode != .none {
            let target = databaseTarget(for: config)
            let status = await DockerManager.shared.getContainerStatus(target.containerName)
            guard status == .running else {
                throw DockerError.commandFailed("Database container '\(target.containerName)' is not running. Start it before creating SQL dumps.")
            }

            let relativePath = "\(config.id.uuidString).sql"
            let dumpURL = targetDirectory.appendingPathComponent(relativePath)

            switch target.databaseType {
            case .mysql, .mariadb:
                try await dumpMySQLDatabase(target, to: dumpURL)
            case .postgres:
                try await dumpPostgresDatabase(target, to: dumpURL)
            }

            dumps.append(BackupDatabaseDumpEntry(
                serverID: config.id,
                serverName: config.name,
                databaseType: target.databaseType,
                attachmentMode: config.databaseAttachmentMode,
                databaseName: target.databaseName,
                relativePath: "databases/\(relativePath)"
            ))
        }

        return dumps
    }

    private func importDatabaseDumps(_ dumps: [BackupDatabaseDumpEntry], from payloadRoot: URL) async throws {
        let configsByID = Dictionary(uniqueKeysWithValues: ConfigurationStore.shared.configurations.map { ($0.id, $0) })

        for dump in dumps {
            guard let config = configsByID[dump.serverID] else {
                throw DockerError.commandFailed("No server configuration found for database dump '\(dump.serverName)'. Restore the configuration first or recreate the server.")
            }

            let target = databaseTarget(for: config)
            let status = await DockerManager.shared.getContainerStatus(target.containerName)
            guard status == .running else {
                throw DockerError.commandFailed("Database container '\(target.containerName)' is not running. Start it before restoring SQL dumps.")
            }

            let dumpURL = payloadRoot.appendingPathComponent(dump.relativePath)
            guard fileManager.fileExists(atPath: dumpURL.path) else {
                throw DockerError.commandFailed("SQL dump not found in backup: \(dump.relativePath)")
            }

            switch target.databaseType {
            case .mysql, .mariadb:
                try await restoreMySQLDatabase(target, from: dumpURL)
            case .postgres:
                try await restorePostgresDatabase(target, from: dumpURL)
            }
        }
    }

    private func dumpMySQLDatabase(_ target: DatabaseBackupTarget, to dumpURL: URL) async throws {
        let command = [
            "docker exec",
            "-e MYSQL_PWD=\(shellQuoted(target.rootPassword))",
            shellQuoted(target.containerName),
            "sh -c",
            shellQuoted("if command -v mariadb-dump >/dev/null 2>&1; then dump=mariadb-dump; else dump=mysqldump; fi; exec \"$dump\" -uroot --single-transaction --routines --triggers --databases \"$1\""),
            "dockamp-dump",
            shellQuoted(target.databaseName),
            ">",
            shellQuoted(dumpURL.path)
        ].joined(separator: " ")

        try await run("/bin/sh", arguments: ["-lc", command])
    }

    private func dumpPostgresDatabase(_ target: DatabaseBackupTarget, to dumpURL: URL) async throws {
        let command = [
            "docker exec",
            "-e PGPASSWORD=\(shellQuoted(target.rootPassword))",
            shellQuoted(target.containerName),
            "pg_dump",
            "-U postgres",
            "-d \(shellQuoted(target.databaseName))",
            "--clean --if-exists --no-owner --no-privileges",
            ">",
            shellQuoted(dumpURL.path)
        ].joined(separator: " ")

        try await run("/bin/sh", arguments: ["-lc", command])
    }

    private func restoreMySQLDatabase(_ target: DatabaseBackupTarget, from dumpURL: URL) async throws {
        let command = [
            "docker exec -i",
            "-e MYSQL_PWD=\(shellQuoted(target.rootPassword))",
            shellQuoted(target.containerName),
            "mysql -uroot",
            "<",
            shellQuoted(dumpURL.path)
        ].joined(separator: " ")

        try await run("/bin/sh", arguments: ["-lc", command])
    }

    private func restorePostgresDatabase(_ target: DatabaseBackupTarget, from dumpURL: URL) async throws {
        let createCommand = [
            "docker exec",
            "-e PGPASSWORD=\(shellQuoted(target.rootPassword))",
            shellQuoted(target.containerName),
            "createdb -U postgres",
            shellQuoted(target.databaseName),
            "2>/dev/null || true"
        ].joined(separator: " ")
        try await run("/bin/sh", arguments: ["-lc", createCommand])

        let importCommand = [
            "docker exec -i",
            "-e PGPASSWORD=\(shellQuoted(target.rootPassword))",
            shellQuoted(target.containerName),
            "psql -U postgres -d",
            shellQuoted(target.databaseName),
            "<",
            shellQuoted(dumpURL.path)
        ].joined(separator: " ")
        try await run("/bin/sh", arguments: ["-lc", importCommand])
    }

    private func databaseTarget(for config: ServerConfiguration) -> DatabaseBackupTarget {
        switch config.databaseAttachmentMode {
        case .global:
            let shared = SharedDatabaseStore.shared.settings
            return DatabaseBackupTarget(
                containerName: DockerManager.sharedDatabaseContainerName,
                databaseType: shared.databaseType,
                databaseName: config.databaseSettings.databaseName,
                rootPassword: shared.databaseSettings.rootPassword
            )
        case .dedicated:
            return DatabaseBackupTarget(
                containerName: config.dbContainerName,
                databaseType: config.databaseType,
                databaseName: config.databaseSettings.databaseName,
                rootPassword: config.databaseSettings.rootPassword
            )
        case .none:
            return DatabaseBackupTarget(
                containerName: "",
                databaseType: .mysql,
                databaseName: "",
                rootPassword: ""
            )
        }
    }
}

private struct DatabaseBackupTarget {
    var containerName: String
    var databaseType: DatabaseType
    var databaseName: String
    var rootPassword: String
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func copyReplacing(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    try fileManager.copyItem(at: source, to: destination)
}

private func run(_ executable: String, arguments: [String]) async throws {
    try await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Command failed."
            throw DockerError.commandFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }.value
}
