import SwiftUI

struct ImageUpdateCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dockerManager = DockerManager.shared

    @State private var managedImages: [ManagedImageInfo] = []
    @State private var selectedImageIDs: Set<String> = []
    @State private var isLoading = false
    @State private var isUpdatingImages = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image Update Center")
                        .font(.title2.bold())
                    Text("Update DockAMP-managed Docker images in one place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await loadImages() }
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

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Managed Images", systemImage: "arrow.down.circle")
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

                if managedImages.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No managed images found",
                        systemImage: "shippingbox",
                        description: Text("Create a server or refresh after Docker is running.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(managedImages) { image in
                                ImageUpdateCenterRow(
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
                }

                if isLoading || isUpdatingImages {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text(isUpdatingImages ? "Pulling selected images..." : "Checking managed images...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 760, minHeight: 560)
        .alert("Image update failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            await loadImages()
        }
    }

    private func loadImages() async {
        isLoading = true
        defer { isLoading = false }

        do {
            managedImages = try await dockerManager.managedImageUpdateItems()
            selectedImageIDs = Set(managedImages.filter { $0.status == .missing }.map(\.id))
        } catch {
            present(error)
        }
    }

    private func updateSelectedImages() async {
        isUpdatingImages = true
        defer { isUpdatingImages = false }

        do {
            try await dockerManager.updateManagedImages(references: Array(selectedImageIDs))
            await loadImages()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

private struct ImageUpdateCenterRow: View {
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
