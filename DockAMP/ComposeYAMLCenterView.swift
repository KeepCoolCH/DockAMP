import SwiftUI
import UniformTypeIdentifiers

struct ComposeYAMLCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dockerManager = DockerManager.shared

    @State private var files: [ComposeYAMLFile] = []
    @State private var selectedFileName: String?
    @State private var editorName = "compose.yml"
    @State private var editorContent = defaultComposeContent
    @State private var isEditingExisting = false
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showingImporter = false
    @State private var showingRename = false
    @State private var showingDockerRun = false
    @State private var renameText = ""
    @State private var dockerRunName = "container.yml"
    @State private var dockerRunCommand = "docker run -d --name my-container -p 8088:80 nginx:latest"

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            editor
        }
        .frame(minWidth: 1180, minHeight: 720)
        .alert("Compose YAML failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $showingRename) {
            renameSheet
        }
        .sheet(isPresented: $showingDockerRun) {
            dockerRunSheet
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.yaml, .text, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .task {
            loadFiles()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Compose YAMLs")
                        .font(.title2.bold())
                    Text("Saved files for Docker Compose stacks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            List(selection: $selectedFileName) {
                ForEach(files) { file in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name)
                            .font(.system(.body, design: .monospaced).bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(formatBytes(file.size)) · \(file.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(file.name)
                    .contextMenu {
                        Button("Run") { Task { await runSelected(file.name) } }
                        Button("Copy") { copy(file.name) }
                        Button("Rename") {
                            selectedFileName = file.name
                            renameText = file.name
                            showingRename = true
                        }
                        Button("Delete", role: .destructive) { delete(file.name) }
                    }
                }
            }
            .onChange(of: selectedFileName) { _, name in
                if let name {
                    loadFile(name)
                }
            }

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        newFile()
                    } label: {
                        Label("New", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        dockerRunName = "container.yml"
                        dockerRunCommand = "docker run -d --name my-container -p 8088:80 nginx:latest"
                        showingDockerRun = true
                    } label: {
                        Label("Docker Run", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 8) {

                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }

                    Button {
                        loadFiles()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }

            }
            .padding()
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isEditingExisting ? "Edit Compose YAML" : "New Compose YAML")
                        .font(.headline)
                    Text("Files are stored in ~/Documents/DockAMP/compose-container-center.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isBusy {
                    ProgressView()
                        .scaleEffect(0.8)
                }

                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)

                Button {
                    Task { await runCurrent() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(isBusy)

                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Name") {
                    TextField("compose.yml", text: $editorName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                        .disabled(isEditingExisting)
                }

                TextEditor(text: $editorContent)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }

                HStack {
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Copy") {
                        if let name = selectedFileName {
                            copy(name)
                        }
                    }
                    .disabled(!isEditingExisting || isBusy)

                    Button("Rename") {
                        renameText = selectedFileName ?? editorName
                        showingRename = true
                    }
                    .disabled(!isEditingExisting || isBusy)

                    Button("Delete", role: .destructive) {
                        if let name = selectedFileName {
                            delete(name)
                        }
                    }
                    .disabled(!isEditingExisting || isBusy)
                }
            }
            .padding()
        }
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Compose YAML")
                .font(.headline)
            TextField("compose.yml", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
            HStack {
                Spacer()
                Button("Cancel") { showingRename = false }
                Button("Rename") {
                    if let selectedFileName {
                        rename(selectedFileName, to: renameText)
                    }
                    showingRename = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 420)
    }

    private var dockerRunSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Docker Run to Compose YAML")
                .font(.headline)

            Text("Paste a docker run command. DockAMP converts it to a saved Compose YAML.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Name") {
                TextField("container.yml", text: $dockerRunName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 380)
            }

            TextEditor(text: $dockerRunCommand)
                .font(.system(.body, design: .monospaced))
                .frame(width: 620, height: 180)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    showingDockerRun = false
                }
                Button("Convert & Save") {
                    saveDockerRun()
                    showingDockerRun = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 680)
    }

    private func loadFiles() {
        do {
            files = try dockerManager.listComposeYAMLFiles()
        } catch {
            present(error)
        }
    }

    private func loadFile(_ name: String) {
        do {
            editorContent = try dockerManager.readComposeYAMLFile(named: name)
            editorName = name
            isEditingExisting = true
            statusMessage = nil
        } catch {
            present(error)
        }
    }

    private func newFile() {
        selectedFileName = nil
        editorName = "compose.yml"
        editorContent = Self.defaultComposeContent
        isEditingExisting = false
        statusMessage = nil
    }

    private func save() {
        do {
            let file = isEditingExisting
                ? try dockerManager.updateComposeYAMLFile(named: editorName, content: editorContent)
                : try dockerManager.saveComposeYAMLFile(name: editorName, content: editorContent)
            loadFiles()
            selectedFileName = file.name
            editorName = file.name
            isEditingExisting = true
            statusMessage = "Saved \(file.name)"
        } catch {
            present(error)
        }
    }

    private func saveDockerRun() {
        do {
            let file = try dockerManager.saveDockerRunAsComposeYAML(name: dockerRunName, command: dockerRunCommand)
            loadFiles()
            selectedFileName = file.name
            loadFile(file.name)
            statusMessage = "Converted \(file.name)"
        } catch {
            present(error)
        }
    }

    private func runCurrent() async {
        if !isEditingExisting {
            save()
        } else {
            do {
                _ = try dockerManager.updateComposeYAMLFile(named: editorName, content: editorContent)
            } catch {
                present(error)
                return
            }
        }
        await runSelected(editorName)
    }

    private func runSelected(_ name: String) async {
        isBusy = true
        defer { isBusy = false }

        do {
            let output = try await dockerManager.runComposeYAMLFile(named: name)
            statusMessage = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Started \(name)"
                : output.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            present(error)
        }
    }

    private func copy(_ name: String) {
        do {
            let file = try dockerManager.copyComposeYAMLFile(named: name)
            loadFiles()
            selectedFileName = file.name
            statusMessage = "Copied \(file.name)"
        } catch {
            present(error)
        }
    }

    private func rename(_ name: String, to newName: String) {
        do {
            let file = try dockerManager.renameComposeYAMLFile(named: name, to: newName)
            loadFiles()
            selectedFileName = file.name
            statusMessage = "Renamed \(file.name)"
        } catch {
            present(error)
        }
    }

    private func delete(_ name: String) {
        do {
            try dockerManager.deleteComposeYAMLFile(named: name)
            loadFiles()
            if selectedFileName == name {
                newFile()
            }
            statusMessage = "Deleted \(name)"
        } catch {
            present(error)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            let file = try dockerManager.saveComposeYAMLFile(name: url.lastPathComponent, content: content)
            loadFiles()
            selectedFileName = file.name
            statusMessage = "Imported \(file.name)"
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let defaultComposeContent = """
    services:
      web:
        image: nginx:latest
        ports:
          - "8088:80"
    """
}
