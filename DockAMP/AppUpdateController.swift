import AppKit
import Combine
import SwiftUI

struct AppUpdate: Decodable, Equatable {
    let version: String
    let build: Int
    let downloadURL: URL

    static func decode(_ data: Data) throws -> AppUpdate {
        let update = try JSONDecoder().decode(AppUpdate.self, from: data)
        let parts = update.version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              update.version.count <= 128, update.build > 0,
              update.downloadURL.scheme == "https",
              let host = update.downloadURL.host?.lowercased(),
              host == "kevintobler.ch" || host.hasSuffix(".kevintobler.ch"),
              update.downloadURL.user == nil, update.downloadURL.password == nil,
              update.downloadURL.port == nil || update.downloadURL.port == 443 else {
            throw UpdateError.invalidFeed
        }
        return update
    }

    func isNewer(than version: String, build installedBuild: String) -> Bool {
        let comparison = self.version.compare(version, options: .numeric)
        if comparison != .orderedSame { return comparison == .orderedDescending }
        return build > (Int(installedBuild) ?? 0)
    }
}

enum UpdateError: LocalizedError {
    case invalidFeed
    var errorDescription: String? { "The update server returned invalid update information." }
}

@MainActor
final class AppUpdateController: ObservableObject {
    static let shared = AppUpdateController()
    static let feedURL = URL(string: "https://kevintobler.ch/files/updates/dockamp.json")!
    @Published private(set) var checking = false
    @Published private(set) var available: AppUpdate?
    @Published var automaticChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticChecks, forKey: "AppUpdateAutomaticChecks")
            if automaticChecks { checkIfDue() }
        }
    }
    private var timer: Timer?

    private init() {
        automaticChecks = UserDefaults.standard.bool(forKey: "AppUpdateAutomaticChecks")
    }

    func start() {
        guard timer == nil else { return }
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkIfDue() }
        }
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: "AppUpdateLastAttempt") as? Date ?? .distantPast
        if automaticChecks && Date().timeIntervalSince(last) >= 86400 { check(manual: false) }
    }

    func check(manual: Bool = true) {
        guard !checking else { return }
        checking = true
        UserDefaults.standard.set(Date(), forKey: "AppUpdateLastAttempt")
        Task {
            defer { checking = false }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 25
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                var request = URLRequest(url: Self.feedURL, cachePolicy: .reloadIgnoringLocalCacheData)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https", http.expectedContentLength <= 1_048_576 else {
                    throw UpdateError.invalidFeed
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < 1_048_576 else { throw UpdateError.invalidFeed }
                    data.append(byte)
                }
                let update = try AppUpdate.decode(data)
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                if update.isNewer(than: version, build: build) {
                    available = update
                    let identity = update.version + ":" + String(update.build)
                    if manual || UserDefaults.standard.string(forKey: "AppUpdateLastNotified") != identity {
                        UserDefaults.standard.set(identity, forKey: "AppUpdateLastNotified")
                        let alert = NSAlert()
                        alert.messageText = "DockAMP update available"
                        alert.informativeText = "Version \(update.version) (Build \(update.build)) is available. Open the download in your browser and install it manually."
                        alert.addButton(withTitle: "Download")
                        alert.addButton(withTitle: "Later")
                        present(alert) { response in
                            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(update.downloadURL) }
                        }
                    }
                } else {
                    available = nil
                    if manual {
                        showMessage("DockAMP is up to date", text: "Installed version: \(version) (Build \(build)).")
                    }
                }
            } catch {
                if manual { showMessage("Update check failed", text: error.localizedDescription) }
            }
        }
    }

    private func showMessage(_ title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        present(alert) { _ in }
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let parent = NSApp.mainWindow ?? NSApp.keyWindow
        NSApp.activate(ignoringOtherApps: true)
        var positioningTimer: Timer?
        if let parent {
            let parentFrame = parent.frame
            alert.layout()
            let dialog = alert.window
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    dialog.setFrameOrigin(NSPoint(
                        x: parentFrame.midX - dialog.frame.width / 2,
                        y: parentFrame.midY - dialog.frame.height / 2
                    ))
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            positioningTimer = timer
        }
        let response = alert.runModal()
        positioningTimer?.invalidate()
        completion(response)
    }
}

struct AppUpdateCommands: Commands {
    @ObservedObject private var updates = AppUpdateController.shared

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for App Updates...") { updates.check() }
                .disabled(updates.checking)
            Toggle("Automatically Check for App Updates", isOn: $updates.automaticChecks)
        }
    }
}
