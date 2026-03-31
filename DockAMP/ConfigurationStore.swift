import Foundation
import Combine

@MainActor
class ConfigurationStore: ObservableObject {
    static let shared = ConfigurationStore()
    
    @Published var configurations: [ServerConfiguration] = []
    @Published var selectedConfiguration: ServerConfiguration?
    
    private let appDirectory: URL
    private let serversDirectory: URL
    private let databasesDirectory: URL
    private let databaseConfigFileURL: URL
    private let legacyCentralDatabaseConfigFileURL: URL
    private let legacySaveURL: URL
    private let legacyOldRootSaveURL: URL
    
    private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        appDirectory = documentsDirectory.appendingPathComponent("DockAMP", isDirectory: true)
        serversDirectory = appDirectory.appendingPathComponent("servers", isDirectory: true)
        databasesDirectory = appDirectory.appendingPathComponent("databases", isDirectory: true)
        databaseConfigFileURL = databasesDirectory.appendingPathComponent("global_database.json")
        legacyCentralDatabaseConfigFileURL = databasesDirectory.appendingPathComponent("database_configurations.json")
        legacySaveURL = appDirectory.appendingPathComponent("dockamp_configurations.json")
        legacyOldRootSaveURL = documentsDirectory.appendingPathComponent("dockamp_configurations.json")
        prepareStorageDirectories()
        
        loadConfigurations()
        
        if configurations.isEmpty {
            let defaultConfig = ServerConfiguration(name: "Development Server")
            configurations.append(defaultConfig)
            selectedConfiguration = defaultConfig
            saveConfigurations()
        } else {
            selectedConfiguration = configurations.first
        }
    }

    private func prepareStorageDirectories() {
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: serversDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: databasesDirectory, withIntermediateDirectories: true)
        } catch {
            print("Error creating DockAMP folder structure: \(error)")
        }
    }
    
    // MARK: - Persistence
    
    func saveConfigurations() {
        for config in configurations {
            saveServerConfigurationFile(for: config)
        }
        saveDatabaseConfigurationsFile()
        removeOrphanedConfigurationFiles()
    }
    
    func loadConfigurations() {
        let splitConfigs = loadSplitConfigurations()
        if !splitConfigs.isEmpty {
            configurations = splitConfigs
            return
        }

        let legacyConfigs = loadLegacyConfigurations()
        if !legacyConfigs.isEmpty {
            configurations = legacyConfigs
            saveConfigurations()
            try? FileManager.default.removeItem(at: legacySaveURL)
            try? FileManager.default.removeItem(at: legacyOldRootSaveURL)
            return
        }

        configurations = []
    }
    
    // MARK: - CRUD Operations
    
    func addConfiguration(_ config: ServerConfiguration) {
        configurations.append(config)
        selectedConfiguration = config
        saveConfigurations()
    }
    
    func updateConfiguration(_ config: ServerConfiguration) {
        if let index = configurations.firstIndex(where: { $0.id == config.id }) {
            var updatedConfig = config
            updatedConfig.updatedAt = Date()
            configurations[index] = updatedConfig
            
            if selectedConfiguration?.id == config.id {
                selectedConfiguration = updatedConfig
            }
            
            saveConfigurations()
        }
    }
    
    func deleteConfiguration(_ config: ServerConfiguration) {
        configurations.removeAll { $0.id == config.id }
        
        if selectedConfiguration?.id == config.id {
            selectedConfiguration = configurations.first
        }

        try? FileManager.default.removeItem(at: serverFileURL(for: config.id))
        saveConfigurations()
    }

    // MARK: - File Layout

    private func serverFileURL(for id: UUID) -> URL {
        serversDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func dedicatedDatabaseFileURL(for id: UUID) -> URL {
        databasesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - Read/Write

    private func saveServerConfigurationFile(for config: ServerConfiguration) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let serverConfig = ServerConfigurationFile(
                id: config.id,
                name: config.name,
                createdAt: config.createdAt,
                updatedAt: config.updatedAt,
                autoStartOnAppLaunch: config.autoStartOnAppLaunch,
                webServerType: config.webServerType,
                webServerPort: config.webServerPort,
                webServerDocumentRoot: config.webServerDocumentRoot,
                additionalContainerMounts: config.additionalContainerMounts,
                webServerCPUs: config.webServerCPUs,
                webServerMemoryLimit: config.webServerMemoryLimit,
                webServerAdditionalRunArgs: config.webServerAdditionalRunArgs,
                apacheSettings: config.apacheSettings,
                nginxSettings: config.nginxSettings,
                phpVersion: config.phpVersion,
                phpCPUs: config.phpCPUs,
                phpMemoryLimit: config.phpMemoryLimit,
                phpSettings: config.phpSettings,
                databaseConfigRef: config.id
            )
            let serverData = try encoder.encode(serverConfig)
            try serverData.write(to: serverFileURL(for: config.id))
        } catch {
            print("Error saving server file (\(config.name)): \(error)")
        }
    }

    private func saveDatabaseConfigurationsFile() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            var envelope = loadDatabaseConfigurationsEnvelope()

            let sharedRootPassword = SharedDatabaseStore.shared.settings.databaseSettings.rootPassword
            envelope.serverConfigs = Dictionary(
                uniqueKeysWithValues: configurations
                    .filter { $0.databaseAttachmentMode != .dedicated }
                    .map { config in
                        var settings = config.databaseSettings
                        if config.databaseAttachmentMode == .global {
                            settings.rootPassword = sharedRootPassword
                        }

                        return (config.id.uuidString, DatabaseConfigurationFile(
                            databaseAttachmentMode: config.databaseAttachmentMode,
                            databaseType: config.databaseType,
                            databasePort: config.databasePort,
                            dedicatedDatabaseCPUs: config.dedicatedDatabaseCPUs,
                            dedicatedDatabaseMemoryLimit: config.dedicatedDatabaseMemoryLimit,
                            databaseSettings: settings
                        ))
                    }
            )

            let data = try encoder.encode(envelope)
            try data.write(to: databaseConfigFileURL)

            for config in configurations where config.databaseAttachmentMode == .dedicated {
                try saveDedicatedDatabaseConfigurationFile(for: config)
            }

            for config in configurations where config.databaseAttachmentMode != .dedicated {
                try? FileManager.default.removeItem(at: dedicatedDatabaseFileURL(for: config.id))
            }
        } catch {
            print("Error saving database configurations: \(error)")
        }
    }

    private func saveDedicatedDatabaseConfigurationFile(for config: ServerConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]

        let dbConfig = DatabaseConfigurationFile(
            databaseAttachmentMode: config.databaseAttachmentMode,
            databaseType: config.databaseType,
            databasePort: config.databasePort,
            dedicatedDatabaseCPUs: config.dedicatedDatabaseCPUs,
            dedicatedDatabaseMemoryLimit: config.dedicatedDatabaseMemoryLimit,
            databaseSettings: config.databaseSettings
        )
        let dbData = try encoder.encode(dbConfig)
        try dbData.write(to: dedicatedDatabaseFileURL(for: config.id))
    }

    private func loadSplitConfigurations() -> [ServerConfiguration] {
        let fileManager = FileManager.default
        guard let serverFiles = try? fileManager.contentsOfDirectory(
            at: serversDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        let dbEnvelope = loadDatabaseConfigurationsEnvelope()
        var loaded: [ServerConfiguration] = []

        for fileURL in serverFiles where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let config: ServerConfiguration
                if let splitServer = try? decoder.decode(ServerConfigurationFile.self, from: data) {
                    config = splitServer.toServerConfiguration()
                } else {
                    config = try decoder.decode(ServerConfiguration.self, from: data)
                }
                var merged = config

                if let dbConfig = loadDatabaseConfiguration(for: config.id, from: dbEnvelope) {
                    merged.databaseAttachmentMode = dbConfig.databaseAttachmentMode
                    merged.databaseType = dbConfig.databaseType
                    merged.databasePort = dbConfig.databasePort
                    merged.dedicatedDatabaseCPUs = dbConfig.dedicatedDatabaseCPUs
                    merged.dedicatedDatabaseMemoryLimit = dbConfig.dedicatedDatabaseMemoryLimit
                    merged.databaseSettings = dbConfig.databaseSettings

                    if merged.databaseAttachmentMode == .global {
                        merged.databasePort = SharedDatabaseStore.shared.settings.databasePort
                        merged.databaseSettings.rootPassword = SharedDatabaseStore.shared.settings.databaseSettings.rootPassword
                    }
                }

                loaded.append(merged)
            } catch {
                print("Error loading file \(fileURL.lastPathComponent): \(error)")
            }
        }

        return loaded.sorted { $0.createdAt < $1.createdAt }
    }

    private func loadDatabaseConfiguration(for id: UUID, from envelope: DatabaseConfigurationsEnvelope) -> DatabaseConfigurationFile? {
        let decoder = JSONDecoder()
        let dedicatedURL = dedicatedDatabaseFileURL(for: id)

        if FileManager.default.fileExists(atPath: dedicatedURL.path),
           let data = try? Data(contentsOf: dedicatedURL),
           let dedicatedConfig = try? decoder.decode(DatabaseConfigurationFile.self, from: data) {
            return dedicatedConfig
        }

        return envelope.serverConfigs[id.uuidString]
    }

    private func loadDatabaseConfigurationsEnvelope() -> DatabaseConfigurationsEnvelope {
        let decoder = JSONDecoder()

        let centralCandidates = [databaseConfigFileURL, legacyCentralDatabaseConfigFileURL]
        for candidate in centralCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let data = try? Data(contentsOf: candidate),
               let envelope = try? decoder.decode(DatabaseConfigurationsEnvelope.self, from: data) {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let normalizedData = try? encoder.encode(envelope) {
                    try? normalizedData.write(to: databaseConfigFileURL)
                }
                if candidate != databaseConfigFileURL {
                    try? FileManager.default.removeItem(at: candidate)
                }
                return envelope
            }
        }

        var migrated = DatabaseConfigurationsEnvelope()

        if let legacyFiles = try? FileManager.default.contentsOfDirectory(at: databasesDirectory, includingPropertiesForKeys: nil) {
            for file in legacyFiles where file.pathExtension == "json" {
                let filename = file.lastPathComponent
                if filename == databaseConfigFileURL.lastPathComponent || filename == "dockamp_database.json" {
                    continue
                }
                guard let uuidString = filename.split(separator: ".").first.map(String.init), UUID(uuidString: uuidString) != nil else {
                    continue
                }
                if let data = try? Data(contentsOf: file),
                   let dbConfig = try? decoder.decode(DatabaseConfigurationFile.self, from: data) {
                    if dbConfig.databaseAttachmentMode == .dedicated {
                        try? data.write(to: dedicatedDatabaseFileURL(for: UUID(uuidString: uuidString)!))
                    } else {
                        migrated.serverConfigs[uuidString] = dbConfig
                    }
                }
            }
        }

        let legacyGlobalCandidates = [
            databasesDirectory.appendingPathComponent("dockamp_database.json"),
            appDirectory.appendingPathComponent("dockamp_database.json"),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("dockamp_database.json")
        ].compactMap { $0 }

        for legacyURL in legacyGlobalCandidates where migrated.globalSettings == nil {
            if FileManager.default.fileExists(atPath: legacyURL.path),
               let data = try? Data(contentsOf: legacyURL),
               let settings = try? decoder.decode(SharedDatabaseSettings.self, from: data) {
                migrated.globalSettings = settings
                break
            }
        }

        if !migrated.serverConfigs.isEmpty || migrated.globalSettings != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(migrated) {
                try? data.write(to: databaseConfigFileURL)
            }
        }

        return migrated
    }

    private func loadLegacyConfigurations() -> [ServerConfiguration] {
        let decoder = JSONDecoder()
        let legacyURLs = [legacySaveURL, legacyOldRootSaveURL]

        for url in legacyURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let configs = try decoder.decode([ServerConfiguration].self, from: data)
                return configs
            } catch {
                print("Error loading legacy configuration from \(url.lastPathComponent): \(error)")
            }
        }

        return []
    }

    private func removeOrphanedConfigurationFiles() {
        let expectedNames = Set(configurations.map { "\($0.id.uuidString).json" })
        removeOrphanedFiles(in: serversDirectory, expectedNames: expectedNames)

        let expectedDedicatedNames = Set(
            configurations
                .filter { $0.databaseAttachmentMode == .dedicated }
                .map { "\($0.id.uuidString).json" }
        )

        if let files = try? FileManager.default.contentsOfDirectory(at: databasesDirectory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                let name = file.lastPathComponent
                let isCentral = name == databaseConfigFileURL.lastPathComponent
                let isActiveDedicated = expectedDedicatedNames.contains(name)
                if !isCentral && !isActiveDedicated {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private func removeOrphanedFiles(in directory: URL, expectedNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return
        }
        for file in files where file.pathExtension == "json" {
            if !expectedNames.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

struct DatabaseConfigurationsEnvelope: Codable {
    var globalSettings: SharedDatabaseSettings?
    var serverConfigs: [String: DatabaseConfigurationFile] = [:]
}

struct DatabaseConfigurationFile: Codable {
    var databaseAttachmentMode: DatabaseAttachmentMode
    var databaseType: DatabaseType
    var databasePort: Int
    var dedicatedDatabaseCPUs: String
    var dedicatedDatabaseMemoryLimit: String
    var databaseSettings: DatabaseSettings

    init(
        databaseAttachmentMode: DatabaseAttachmentMode = .global,
        databaseType: DatabaseType = .mysql,
        databasePort: Int = 3306,
        dedicatedDatabaseCPUs: String = "",
        dedicatedDatabaseMemoryLimit: String = "",
        databaseSettings: DatabaseSettings = DatabaseSettings()
    ) {
        self.databaseAttachmentMode = databaseAttachmentMode
        self.databaseType = databaseType
        self.databasePort = databasePort
        self.dedicatedDatabaseCPUs = dedicatedDatabaseCPUs
        self.dedicatedDatabaseMemoryLimit = dedicatedDatabaseMemoryLimit
        self.databaseSettings = databaseSettings
    }

    private enum CodingKeys: String, CodingKey {
        case databaseAttachmentMode, databaseType, databasePort, dedicatedDatabaseCPUs, dedicatedDatabaseMemoryLimit, databaseSettings
    }

    private struct ServerDatabaseSettingsFile: Codable {
        var databaseName: String
        var username: String
        var password: String
        var maxConnections: Int
        var queryCache: Bool
    }

    private struct GlobalServerDatabaseFile: Codable {
        var databaseAttachmentMode: DatabaseAttachmentMode
        var databaseType: DatabaseType
        var dedicatedDatabaseCPUs: String
        var dedicatedDatabaseMemoryLimit: String
        var databaseSettings: ServerDatabaseSettingsFile
    }

    init(from decoder: Decoder) throws {
        self.init()

        if let globalStyle = try? GlobalServerDatabaseFile(from: decoder) {
            databaseAttachmentMode = globalStyle.databaseAttachmentMode
            databaseType = globalStyle.databaseType
            dedicatedDatabaseCPUs = globalStyle.dedicatedDatabaseCPUs
            dedicatedDatabaseMemoryLimit = globalStyle.dedicatedDatabaseMemoryLimit
            databaseSettings.databaseName = globalStyle.databaseSettings.databaseName
            databaseSettings.username = globalStyle.databaseSettings.username
            databaseSettings.password = globalStyle.databaseSettings.password
            databaseSettings.maxConnections = globalStyle.databaseSettings.maxConnections
            databaseSettings.queryCache = globalStyle.databaseSettings.queryCache
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        databaseAttachmentMode = try container.decodeIfPresent(DatabaseAttachmentMode.self, forKey: .databaseAttachmentMode) ?? databaseAttachmentMode
        databaseType = try container.decodeIfPresent(DatabaseType.self, forKey: .databaseType) ?? databaseType
        databasePort = try container.decodeIfPresent(Int.self, forKey: .databasePort) ?? databasePort
        dedicatedDatabaseCPUs = try container.decodeIfPresent(String.self, forKey: .dedicatedDatabaseCPUs) ?? dedicatedDatabaseCPUs
        dedicatedDatabaseMemoryLimit = try container.decodeIfPresent(String.self, forKey: .dedicatedDatabaseMemoryLimit) ?? dedicatedDatabaseMemoryLimit

        if let fullSettings = try container.decodeIfPresent(DatabaseSettings.self, forKey: .databaseSettings) {
            databaseSettings = fullSettings
        } else if let serverOnlySettings = try container.decodeIfPresent(ServerDatabaseSettingsFile.self, forKey: .databaseSettings) {
            databaseSettings.databaseName = serverOnlySettings.databaseName
            databaseSettings.username = serverOnlySettings.username
            databaseSettings.password = serverOnlySettings.password
            databaseSettings.maxConnections = serverOnlySettings.maxConnections
            databaseSettings.queryCache = serverOnlySettings.queryCache
        }
    }

    func encode(to encoder: Encoder) throws {
        if databaseAttachmentMode == .global {
            let serverOnlySettings = ServerDatabaseSettingsFile(
                databaseName: databaseSettings.databaseName,
                username: databaseSettings.username,
                password: databaseSettings.password,
                maxConnections: databaseSettings.maxConnections,
                queryCache: databaseSettings.queryCache
            )
            let slim = GlobalServerDatabaseFile(
                databaseAttachmentMode: databaseAttachmentMode,
                databaseType: databaseType,
                dedicatedDatabaseCPUs: dedicatedDatabaseCPUs,
                dedicatedDatabaseMemoryLimit: dedicatedDatabaseMemoryLimit,
                databaseSettings: serverOnlySettings
            )
            try slim.encode(to: encoder)
            return
        }

        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(databaseAttachmentMode, forKey: .databaseAttachmentMode)
        try container.encode(databaseType, forKey: .databaseType)
        try container.encode(databasePort, forKey: .databasePort)
        try container.encode(dedicatedDatabaseCPUs, forKey: .dedicatedDatabaseCPUs)
        try container.encode(dedicatedDatabaseMemoryLimit, forKey: .dedicatedDatabaseMemoryLimit)
        try container.encode(databaseSettings, forKey: .databaseSettings)
    }
}

private struct ServerConfigurationFile: Codable {
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var autoStartOnAppLaunch: Bool = false
    var webServerType: WebServerType
    var webServerPort: Int
    var webServerDocumentRoot: String
    var additionalContainerMounts: String?
    var webServerCPUs: String
    var webServerMemoryLimit: String
    var webServerAdditionalRunArgs: String
    var apacheSettings: ApacheSettings
    var nginxSettings: NginxSettings
    var phpVersion: String
    var phpCPUs: String
    var phpMemoryLimit: String
    var phpSettings: PHPSettings
    var databaseConfigRef: UUID

    func toServerConfiguration() -> ServerConfiguration {
        var config = ServerConfiguration(name: name)
        config.id = id
        config.name = name
        config.createdAt = createdAt
        config.updatedAt = updatedAt
        config.autoStartOnAppLaunch = autoStartOnAppLaunch
        config.webServerType = webServerType
        config.webServerPort = webServerPort
        config.webServerDocumentRoot = webServerDocumentRoot
        config.additionalContainerMounts = additionalContainerMounts ?? ""
        config.webServerCPUs = webServerCPUs
        config.webServerMemoryLimit = webServerMemoryLimit
        config.webServerAdditionalRunArgs = webServerAdditionalRunArgs
        config.apacheSettings = apacheSettings
        config.nginxSettings = nginxSettings
        config.phpVersion = phpVersion
        config.phpCPUs = phpCPUs
        config.phpMemoryLimit = phpMemoryLimit
        config.phpSettings = phpSettings
        return config
    }
}
