import SwiftUI
import UniformTypeIdentifiers

struct SystemMaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dockerManager = DockerManager.shared
    @StateObject private var backupManager = BackupManager.shared
    @StateObject private var composeExportManager = ComposeExportManager.shared

    @State private var managedImages: [ManagedImageInfo] = []
    @State private var selectedImageIDs: Set<String> = []
    @State private var unusedImages: [DockerImageCleanupItem] = []
    @State private var unusedVolumes: [DockerVolumeCleanupItem] = []
    @State private var backups: [BackupArchiveInfo] = []
    @State private var backupSettings = BackupSettings()
    @State private var includeConfigurationBackup = true
    @State private var includeDocumentRootsBackup = true
    @State private var includeDatabaseDumpsBackup = true
    @State private var composeExportSummary = ComposeExportSummary(path: "", exists: false, files: [], exportedAt: nil)
    @State private var isExportingCompose = false
    @State private var isRunningBackup = false
    @State private var restorePreview: RestorePreview?
    @State private var restoreConfiguration = true
    @State private var restoreDocumentRoots = true
    @State private var restoreDatabaseDumps = true
    @State private var isLoading = false
    @State private var isUpdatingImages = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Maintenance")
                        .font(.title2.bold())
                    Text("Back up DockAMP, export recovery YAMLs, and clean up unused Docker resources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await loadAll() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || isUpdatingImages)

                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    backupRestoreSection
                    composeExportSection
                    unusedImagesSection
                    unusedVolumesSection
                }
                .padding()
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .overlay {
            if isLoading {
                ProgressView("Loading Docker resources...")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .alert("Action failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            await loadAll()
        }
    }

    private var backupRestoreSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Backup & Restore", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline)
                    Spacer()
                    Button {
                        Task { await createBackup() }
                    } label: {
                        Label("Create Backup", systemImage: "archivebox")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunningBackup || (!includeConfigurationBackup && !includeDocumentRootsBackup && !includeDatabaseDumpsBackup))

                    Button {
                        chooseRestoreArchive()
                    } label: {
                        Label("Restore...", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isRunningBackup)
                }

                HStack(spacing: 18) {
                    Toggle("DockAMP Configuration", isOn: $includeConfigurationBackup)
                    Toggle("Website Document Roots", isOn: $includeDocumentRootsBackup)
                    Toggle("Database SQL Dumps", isOn: $includeDatabaseDumpsBackup)
                    if isRunningBackup {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        Text("Automatic Backups")
                            .font(.headline)
                        Picker("", selection: $backupSettings.interval) {
                            ForEach(BackupInterval.allCases) { interval in
                                Text(interval.displayName).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }

                    GridRow {
                        Text("Versions to Keep")
                            .font(.headline)
                        Stepper(value: $backupSettings.retention, in: 1...365) {
                            Text("\(backupSettings.retention)")
                                .frame(width: 32, alignment: .leading)
                        }
                    }

                    GridRow {
                        Text("Automatic Includes")
                            .font(.headline)
                        HStack(spacing: 18) {
                            Toggle("DockAMP Configuration", isOn: $backupSettings.includeConfiguration)
                            Toggle("Website Document Roots", isOn: $backupSettings.includeDocumentRoots)
                            Toggle("Database SQL Dumps", isOn: $backupSettings.includeDatabaseDumps)
                        }
                    }
                }

                HStack {
                    Button {
                        backupManager.updateSettings(backupSettings)
                    } label: {
                        Label("Save Backup Settings", systemImage: "checkmark.circle")
                    }
                    .disabled(
                        backupSettings == backupManager.settings
                            || (!backupSettings.includeConfiguration && !backupSettings.includeDocumentRoots && !backupSettings.includeDatabaseDumps)
                    )

                    Spacer()

                    Text(automaticBackupStatus)
                        .font(.caption)
                        .foregroundStyle(backupManager.settings.lastError.isEmpty ? Color.secondary : Color.orange)
                }

                if backups.isEmpty {
                    Text("No local backups yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(backups) { backup in
                            HStack(spacing: 12) {
                                Image(systemName: "doc.zipper")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(backup.displayName)
                                        .font(.headline)
                                    Text(backupSubtitle(backup))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Export...") {
                                    exportBackup(backup)
                                }
                            }
                            .padding(10)

                            if backup.id != backups.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                Text("Backups are stored in `~/Documents/DockAMP/backups` as `.tar.gz` archives.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .sheet(item: $restorePreview) { preview in
            restorePreviewSheet(preview)
        }
        .onAppear {
            syncBackupSettings()
        }
        .onReceive(backupManager.$settings) { _ in
            syncBackupSettings()
        }
    }

    private var composeExportSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Recovery Compose Export", systemImage: "doc.text")
                        .font(.headline)

                    Spacer()

                    if isExportingCompose {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        openComposeExportFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .disabled(!composeExportSummary.exists)

                    Button {
                        exportRecoveryCompose()
                    } label: {
                        Label("Recreate YAMLs", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isExportingCompose)
                }

                Text("Docker Compose files for emergency recovery are written from the current DockAMP configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    composeExportInfoTile("Target Folder", value: abbreviatedPath(composeExportSummary.path))
                    composeExportInfoTile("Last Export", value: composeExportLastExportText)
                    composeExportInfoTile("Files", value: "\(composeExportSummary.files.count)")
                }

                Text("Exports are stored in `~/Documents/DockAMP/compose-export` and include a combined `docker-compose.yml` plus per-server YAMLs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private func composeExportInfoTile(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var managedImagesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Image Update Center", systemImage: "arrow.down.circle")
                        .font(.headline)

                    Spacer()

                    Button(selectedImageIDs.count == managedImages.count ? "Deselect All" : "Select All") {
                        if selectedImageIDs.count == managedImages.count {
                            selectedImageIDs.removeAll()
                        } else {
                            selectedImageIDs = Set(managedImages.map(\.id))
                        }
                    }
                    .disabled(managedImages.isEmpty || isUpdatingImages)

                    Button {
                        Task { await updateSelectedImages() }
                    } label: {
                        Label("Update Selected", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImageIDs.isEmpty || isUpdatingImages)
                }

                if managedImages.isEmpty {
                    ContentUnavailableView(
                        "No managed images found",
                        systemImage: "shippingbox",
                        description: Text("Create a server or refresh after Docker is running.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    VStack(spacing: 0) {
                        ForEach(managedImages) { image in
                            ManagedImageRow(
                                image: image,
                                isSelected: selectedImageIDs.contains(image.id),
                                toggle: {
                                    if selectedImageIDs.contains(image.id) {
                                        selectedImageIDs.remove(image.id)
                                    } else {
                                        selectedImageIDs.insert(image.id)
                                    }
                                }
                            )
                            if image.id != managedImages.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }

                if isUpdatingImages {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Pulling selected images...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(4)
        }
    }

    private var unusedImagesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Unused Images", systemImage: "trash")
                        .font(.headline)
                    Spacer()
                    Button("Prune All", role: .destructive) {
                        Task { await pruneImages() }
                    }
                    .disabled(unusedImages.isEmpty || isLoading)
                }

                if unusedImages.isEmpty {
                    Text("No dangling images found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(unusedImages) { image in
                            CleanupImageRow(image: image) {
                                Task { await removeImage(image) }
                            }
                            if image.id != unusedImages.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(4)
        }
    }

    private var unusedVolumesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("Unused Volumes", systemImage: "externaldrive.badge.minus")
                    .font(.headline)

                if unusedVolumes.isEmpty {
                    Text("No unused volumes found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(unusedVolumes) { volume in
                            CleanupVolumeRow(volume: volume) {
                                Task { await removeVolume(volume) }
                            }
                            if volume.id != unusedVolumes.last?.id {
                                Divider()
                            }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(4)
        }
    }

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        await loadManagedImages()
        await loadUnusedImages()
        await loadUnusedVolumes()
        backups = backupManager.listBackups()
        composeExportSummary = composeExportManager.summary()
        syncBackupSettings()
    }

    private func loadManagedImages() async {
        do {
            managedImages = try await dockerManager.managedImageUpdateItems()
            selectedImageIDs = Set(managedImages.filter { $0.status == .missing }.map(\.id))
        } catch {
            managedImages = []
            selectedImageIDs = []
        }
    }

    private func loadUnusedImages() async {
        do {
            unusedImages = try await dockerManager.unusedImages()
        } catch {
            unusedImages = []
            present(error)
        }
    }

    private func loadUnusedVolumes() async {
        do {
            unusedVolumes = try await dockerManager.unusedVolumes()
        } catch {
            unusedVolumes = []
        }
    }

    private func exportRecoveryCompose() {
        isExportingCompose = true
        do {
            composeExportSummary = try composeExportManager.exportNow()
        } catch {
            present(error)
        }
        isExportingCompose = false
    }

    private func openComposeExportFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: composeExportSummary.path))
    }

    private func createBackup() async {
        isRunningBackup = true
        defer { isRunningBackup = false }

        do {
            _ = try await backupManager.createBackup(
                includeConfiguration: includeConfigurationBackup,
                includeDocumentRoots: includeDocumentRootsBackup,
                includeDatabaseDumps: includeDatabaseDumpsBackup
            )
            backups = backupManager.listBackups()
        } catch {
            present(error)
        }
    }

    private func syncBackupSettings() {
        backupSettings = backupManager.settings
    }

    private func exportBackup(_ backup: BackupArchiveInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose where to export the backup"

        if panel.runModal() == .OK, let destination = panel.url {
            do {
                try backupManager.exportBackup(backup, to: destination)
            } catch {
                present(error)
            }
        }
    }

    private func chooseRestoreArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip]
        panel.message = "Choose a DockAMP backup archive"

        guard panel.runModal() == .OK, let archiveURL = panel.url else { return }

        Task {
            isRunningBackup = true
            defer { isRunningBackup = false }

            do {
                restorePreview = try await backupManager.previewRestore(from: archiveURL)
                restoreConfiguration = restorePreview?.manifest.includesConfiguration == true
                restoreDocumentRoots = restorePreview?.manifest.includesDocumentRoots == true
                restoreDatabaseDumps = restorePreview?.manifest.includesDatabaseDumps == true
            } catch {
                present(error)
            }
        }
    }

    private func restorePreviewSheet(_ preview: RestorePreview) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Restore Backup")
                        .font(.title2.bold())
                    Text(preview.archiveURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    restorePreview = nil
                }
                Button("Restore", role: .destructive) {
                    Task { await runRestore(preview) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunningBackup || (!restoreConfiguration && !restoreDocumentRoots && !restoreDatabaseDumps))
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Toggle("Restore DockAMP Configuration", isOn: $restoreConfiguration)
                    .disabled(!preview.manifest.includesConfiguration)
                Toggle("Restore Website Document Roots", isOn: $restoreDocumentRoots)
                    .disabled(!preview.manifest.includesDocumentRoots)
                Toggle("Restore Database SQL Dumps", isOn: $restoreDatabaseDumps)
                    .disabled(!preview.manifest.includesDatabaseDumps || preview.manifest.databaseDumps.isEmpty)

                if preview.manifest.includesDatabaseDumps {
                    Text("\(preview.manifest.databaseDumps.count) database dump\(preview.manifest.databaseDumps.count == 1 ? "" : "s") in this backup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Servers in backup")
                    .font(.headline)

                List(preview.manifest.servers) { server in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                            .font(.headline)
                        Text(server.documentRoot)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(minHeight: 260)

                Text("Restore replaces matching configuration files and selected document-root folders. Database restore imports SQL into running database containers.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .padding()
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private func runRestore(_ preview: RestorePreview) async {
        isRunningBackup = true
        defer { isRunningBackup = false }

        do {
            try await backupManager.restore(
                preview,
                restoreConfiguration: restoreConfiguration,
                restoreDocumentRoots: restoreDocumentRoots,
                restoreDatabaseDumps: restoreDatabaseDumps
            )
            restorePreview = nil
            await loadAll()
        } catch {
            present(error)
        }
    }

    private func updateSelectedImages() async {
        isUpdatingImages = true
        defer { isUpdatingImages = false }

        do {
            try await dockerManager.updateManagedImages(references: Array(selectedImageIDs))
            await loadAll()
        } catch {
            present(error)
        }
    }

    private func pruneImages() async {
        do {
            try await dockerManager.pruneUnusedImages()
            await loadAll()
        } catch {
            present(error)
        }
    }

    private func removeImage(_ image: DockerImageCleanupItem) async {
        do {
            try await dockerManager.removeUnusedImage(id: image.imageID)
            await loadAll()
        } catch {
            present(error)
        }
    }

    private func removeVolume(_ volume: DockerVolumeCleanupItem) async {
        do {
            try await dockerManager.removeUnusedVolume(name: volume.name)
            await loadAll()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private func backupSubtitle(_ backup: BackupArchiveInfo) -> String {
        let size = ByteCountFormatter.string(fromByteCount: backup.size, countStyle: .file)
        guard let createdAt = backup.createdAt else { return size }
        return "\(createdAt.formatted(date: .abbreviated, time: .shortened)) - \(size)"
    }

    private var automaticBackupStatus: String {
        let settings = backupManager.settings
        let lastRun = settings.lastRun?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        if settings.interval == .manual {
            return "Automatic backups disabled. Last backup: \(lastRun)"
        }
        if !settings.lastError.isEmpty {
            return "Last automatic backup: \(lastRun) - \(settings.lastError)"
        }
        let status = settings.lastStatus.isEmpty ? "No automatic backup yet" : settings.lastStatus
        return "\(settings.interval.displayName). Last backup: \(lastRun) - \(status)"
    }

    private var composeExportLastExportText: String {
        composeExportSummary.exportedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path.isEmpty ? "~/Documents/DockAMP/compose-export" : path
    }
}

private struct ManagedImageRow: View {
    let image: ManagedImageInfo
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                .labelsHidden()

            VStack(alignment: .leading, spacing: 3) {
                Text(image.label)
                    .font(.headline)
                Text(image.reference)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Used by: \(image.usedBy.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Label(image.status.displayName, systemImage: statusIcon)
                .foregroundStyle(statusColor)
                .labelStyle(.titleAndIcon)
        }
        .padding(10)
    }

    private var statusIcon: String {
        switch image.status {
        case .installed:
            return "checkmark.circle.fill"
        case .missing:
            return "exclamationmark.circle.fill"
        case .unverified:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch image.status {
        case .installed:
            return .green
        case .missing:
            return .orange
        case .unverified:
            return .secondary
        }
    }
}

private struct CleanupImageRow: View {
    let image: DockerImageCleanupItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(image.displayName)
                    .font(.headline)
                Text("\(image.size) • \(image.createdSince)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Delete", role: .destructive, action: remove)
        }
        .padding(10)
    }
}

private struct CleanupVolumeRow: View {
    let volume: DockerVolumeCleanupItem
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(volume.name)
                    .font(.headline)
                Text(volume.mountpoint.isEmpty ? volume.driver : "\(volume.driver) • \(volume.mountpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Delete", role: .destructive, action: remove)
        }
        .padding(10)
    }
}

#Preview {
    SystemMaintenanceView()
}
