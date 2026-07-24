import Foundation
import Combine

@MainActor
class ProxyManagerStore: ObservableObject {
    static let shared = ProxyManagerStore()

    @Published var settings = ProxyManagerSettings()

    private let appDirectory: URL
    private let proxyManagerDirectory: URL
    private let saveURL: URL
    private let legacySaveURL: URL
    private let legacyOldRootSaveURL: URL

    private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        appDirectory = documentsDirectory.appendingPathComponent("DockAMP", isDirectory: true)
        proxyManagerDirectory = appDirectory.appendingPathComponent("proxy_manager", isDirectory: true)
        saveURL = proxyManagerDirectory.appendingPathComponent("settings.json")
        legacySaveURL = appDirectory.appendingPathComponent("dockamp_proxy_manager.json")
        legacyOldRootSaveURL = documentsDirectory.appendingPathComponent("dockamp_proxy_manager.json")
        prepareStorageDirectories()
        migrateIfNeeded()
        load()
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            try data.write(to: saveURL)
            _ = try? ComposeExportManager.shared.exportNow()
        } catch {
            print("Error saving Proxy Manager settings: \(error)")
        }
    }

    private func load() {
        do {
            let data = try Data(contentsOf: saveURL)
            let decoder = JSONDecoder()
            settings = try decoder.decode(ProxyManagerSettings.self, from: data)
        } catch {
            settings = ProxyManagerSettings()
        }
    }

    private func prepareStorageDirectories() {
        do {
            try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: proxyManagerDirectory, withIntermediateDirectories: true)
        } catch {
            print("Error creating Proxy Manager directory: \(error)")
        }
    }

    private func migrateIfNeeded() {
        guard !FileManager.default.fileExists(atPath: saveURL.path) else { return }

        let legacyURLs = [legacySaveURL, legacyOldRootSaveURL]
        for oldURL in legacyURLs where FileManager.default.fileExists(atPath: oldURL.path) {
            do {
                try FileManager.default.moveItem(at: oldURL, to: saveURL)
                break
            } catch {
                print("Error migrating Proxy Manager file: \(error)")
            }
        }
    }
}
