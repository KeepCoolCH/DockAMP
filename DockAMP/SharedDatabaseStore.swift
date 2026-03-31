import Foundation
import Combine

struct SharedDatabaseSettings: Codable {
    var databaseType: DatabaseType = .mysql
    var databasePort: Int = 3306
    var databaseSettings: DatabaseSettings = DatabaseSettings()
    var cpus: String = ""
    var memoryLimit: String = ""

    init() {}

    private enum CodingKeys: String, CodingKey {
        case databaseType, databasePort, rootPassword, cpus, memoryLimit
        case databaseSettings
    }

    init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        databaseType = try container.decodeIfPresent(DatabaseType.self, forKey: .databaseType) ?? databaseType
        databasePort = try container.decodeIfPresent(Int.self, forKey: .databasePort) ?? databasePort
        cpus = try container.decodeIfPresent(String.self, forKey: .cpus) ?? cpus
        memoryLimit = try container.decodeIfPresent(String.self, forKey: .memoryLimit) ?? memoryLimit

        if let legacySettings = try container.decodeIfPresent(DatabaseSettings.self, forKey: .databaseSettings) {
            databaseSettings = legacySettings
        }

        if let rootPassword = try container.decodeIfPresent(String.self, forKey: .rootPassword) {
            databaseSettings.rootPassword = rootPassword
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(databaseType, forKey: .databaseType)
        try container.encode(databasePort, forKey: .databasePort)
        try container.encode(databaseSettings.rootPassword, forKey: .rootPassword)
        try container.encode(cpus, forKey: .cpus)
        try container.encode(memoryLimit, forKey: .memoryLimit)
    }
}

@MainActor
class SharedDatabaseStore: ObservableObject {
    static let shared = SharedDatabaseStore()

    @Published var settings = SharedDatabaseSettings()

    private let saveURL: URL
    private let legacyURLs: [URL]

    private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let appDirectory = documentsDirectory.appendingPathComponent("DockAMP", isDirectory: true)
        let databasesDirectory = appDirectory.appendingPathComponent("databases", isDirectory: true)
        saveURL = databasesDirectory.appendingPathComponent("global_database.json")
        legacyURLs = [
            databasesDirectory.appendingPathComponent("database_configurations.json"),
            databasesDirectory.appendingPathComponent("dockamp_database.json"),
            appDirectory.appendingPathComponent("dockamp_database.json"),
            documentsDirectory.appendingPathComponent("dockamp_database.json")
        ]

        prepareStorageDirectory(at: databasesDirectory)
        load()
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            var envelope = loadEnvelopeFromDisk() ?? DatabaseConfigurationsEnvelope()
            envelope.globalSettings = settings

            let data = try encoder.encode(envelope)
            try data.write(to: saveURL)
        } catch {
            print("Error saving database settings: \(error)")
        }
    }

    private func load() {
        if let envelope = loadEnvelopeFromDisk(), let global = envelope.globalSettings {
            settings = global
            return
        }

        if let migrated = loadLegacySharedSettings() {
            settings = migrated
            save()
            return
        }

        settings = SharedDatabaseSettings()
    }

    private func loadEnvelopeFromDisk() -> DatabaseConfigurationsEnvelope? {
        let candidates = [saveURL] + legacyURLs

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard let data = try? Data(contentsOf: candidate),
                  let envelope = try? JSONDecoder().decode(DatabaseConfigurationsEnvelope.self, from: data) else {
                continue
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let normalized = try? encoder.encode(envelope) {
                try? normalized.write(to: saveURL)
            }

            if candidate != saveURL {
                try? FileManager.default.removeItem(at: candidate)
            }

            return envelope
        }

        return nil
    }

    private func loadLegacySharedSettings() -> SharedDatabaseSettings? {
        let decoder = JSONDecoder()
        for legacyURL in legacyURLs where FileManager.default.fileExists(atPath: legacyURL.path) {
            if let data = try? Data(contentsOf: legacyURL),
               let settings = try? decoder.decode(SharedDatabaseSettings.self, from: data) {
                return settings
            }
        }
        return nil
    }

    private func prepareStorageDirectory(at directory: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("Error creating DockAMP directory: \(error)")
        }
    }
}
