import SwiftUI

struct ContainerCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dockerManager = DockerManager.shared

    @State private var snapshot = ContainerCenterSnapshot(managed: [], other: [])
    @State private var selectedLogContainer: String?
    @State private var logs = ""
    @State private var isLoading = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView([.vertical, .horizontal]) {
                content
                    .frame(minWidth: 1280, alignment: .leading)
                    .padding()
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading containers...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(minWidth: 1320, minHeight: 720)
        .alert("Container Center failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            await loadContainers()
        }
        .task(id: selectedLogContainer) {
            guard let name = selectedLogContainer else { return }
            while selectedLogContainer == name && !Task.isCancelled {
                await loadLogs(for: name, showSpinner: false)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Container Center")
                    .font(.title2.bold())
                Text("Manage DockAMP and other Docker containers from one place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await loadContainers() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading || isBusy)

            Button("Close") {
                dismiss()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            ContainerCenterSection(
                title: "DockAMP managed containers",
                subtitle: "These containers belong to the DockAMP configuration.",
                containers: snapshot.managed,
                isBusy: isBusy,
                onOpenPort: openPort,
                onAction: { container, action in
                    Task { await runAction(action, for: container) }
                },
                onLogs: { container in
                    Task { await loadLogs(for: container.name) }
                }
            )

            ContainerCenterSection(
                title: "Other containers",
                subtitle: "These containers were not created by DockAMP.",
                containers: snapshot.other,
                isBusy: isBusy,
                allowDelete: true,
                onOpenPort: openPort,
                onAction: { container, action in
                    Task { await runAction(action, for: container) }
                },
                onLogs: { container in
                    Task { await loadLogs(for: container.name) }
                }
            )

            if let selectedLogContainer {
                GroupBox("Container Logs") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(selectedLogContainer)
                                .font(.system(.caption, design: .monospaced).bold())
                            Spacer()
                            Button {
                                Task { await loadLogs(for: selectedLogContainer, showSpinner: false) }
                            } label: {
                                Label("Refresh Logs", systemImage: "arrow.clockwise")
                            }
                            Button("Close Logs") {
                                self.selectedLogContainer = nil
                                logs = ""
                            }
                        }

                        ScrollView {
                            Text(logs.isEmpty ? "No logs available" : logs)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .frame(minHeight: 220, maxHeight: 320)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(4)
                }
            }
        }
    }

    private func loadContainers(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        defer {
            if showSpinner { isLoading = false }
        }

        do {
            snapshot = try await dockerManager.containerCenterSnapshot()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func runAction(_ action: String, for container: ContainerCenterItem) async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await dockerManager.runContainerCenterAction(containerName: container.name, action: action)
            await loadContainers(showSpinner: false)
            if selectedLogContainer == container.name {
                await loadLogs(for: container.name, showSpinner: false)
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func loadLogs(for name: String, showSpinner: Bool = true) async {
        selectedLogContainer = name
        if showSpinner { isLoading = true }
        defer {
            if showSpinner { isLoading = false }
        }

        do {
            logs = try await dockerManager.containerCenterLogs(containerName: name)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func openPort(_ port: ContainerCenterPort) {
        if let url = URL(string: "http://localhost:\(port.hostPort)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct ContainerCenterSection: View {
    let title: String
    let subtitle: String
    let containers: [ContainerCenterItem]
    let isBusy: Bool
    var allowDelete = false
    let onOpenPort: (ContainerCenterPort) -> Void
    let onAction: (ContainerCenterItem, String) -> Void
    let onLogs: (ContainerCenterItem) -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if containers.isEmpty {
                    ContentUnavailableView("No containers found", systemImage: "shippingbox")
                        .frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    VStack(spacing: 0) {
                        ForEach(containers) { container in
                            ContainerCenterRow(
                                container: container,
                                isBusy: isBusy,
                                allowDelete: allowDelete,
                                onOpenPort: onOpenPort,
                                onAction: onAction,
                                onLogs: onLogs
                            )
                            if container.id != containers.last?.id {
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
}

private struct ContainerCenterRow: View {
    let container: ContainerCenterItem
    let isBusy: Bool
    let allowDelete: Bool
    let onOpenPort: (ContainerCenterPort) -> Void
    let onAction: (ContainerCenterItem, String) -> Void
    let onLogs: (ContainerCenterItem) -> Void

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
            GridRow {
                HStack(spacing: 8) {
                    Circle()
                        .fill(container.isRunning ? Color.green : Color.secondary)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name)
                            .font(.system(.body, design: .monospaced).bold())
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(container.role ?? container.image)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(width: 300, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Image")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(container.image)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(width: 260, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Status")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(containerStateLabel(container.state))
                        .font(.caption.bold())
                    Text(container.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Ports")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if container.ports.isEmpty {
                        Text("No published ports")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(container.ports) { port in
                                Button(port.label) {
                                    onOpenPort(port)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
                .frame(width: 210, alignment: .leading)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if container.isRunning {
                            Button("Stop") { onAction(container, "stop") }
                                .disabled(isBusy)
                            Button("Restart") { onAction(container, "restart") }
                                .disabled(isBusy)
                        } else {
                            Button("Start") { onAction(container, "start") }
                                .buttonStyle(.borderedProminent)
                                .disabled(isBusy)
                        }
                        Button("Logs") { onLogs(container) }
                            .disabled(isBusy)
                    }

                    if allowDelete {
                        Button("Delete", role: .destructive) {
                            onAction(container, "delete")
                        }
                        .disabled(isBusy)
                    }
                }
                .frame(width: 220, alignment: .trailing)
            }
        }
        .padding(10)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private func containerStateLabel(_ value: String) -> String {
    switch value {
    case "running": return "Running"
    case "exited": return "Stopped"
    case "created": return "Created"
    case "restarting": return "Restarting"
    case "paused": return "Paused"
    case "dead": return "Dead"
    default: return value.isEmpty ? "Unknown" : value.capitalized
    }
}
