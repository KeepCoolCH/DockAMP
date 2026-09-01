import SwiftUI

struct LiveVisitorsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var dockerManager = DockerManager.shared

    @State private var activities: [LiveVisitorServerActivity] = []
    @State private var isLoading = false
    @State private var speedLoadingServerIDs: Set<UUID> = []
    @State private var autoRefresh = true
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live Visitors")
                        .font(.title2.bold())
                    Text("Active visitors from the last 5 minutes based on web server access logs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("Auto-Refresh", isOn: $autoRefresh)

                Button {
                    Task { await loadActivity() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                if activities.isEmpty {
                    ContentUnavailableView(
                        "No active visitors found",
                        systemImage: "eye",
                        description: Text("Start a server and make a web request to see live activity.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(activities) { activity in
                            LiveVisitorServerCard(activity: activity)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .alert("Live visitors failed", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            await loadActivity()
        }
        .task(id: autoRefresh) {
            guard autoRefresh else { return }
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await loadActivity()
            }
        }
    }

    private func loadActivity() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let configurations = configStore.configurations

        guard !configurations.isEmpty else {
            activities.removeAll()
            return
        }

        let output = try? await dockerManager.executeCommand(
            "docker",
            arguments: ["ps", "--format", "{{.Names}}"]
        )
        let runningContainerNames = Set(
            (output ?? "")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        )
        let runningConfigurations = configurations.filter {
            runningContainerNames.contains($0.primaryContainerName)
        }
        let runningIDs = Set(runningConfigurations.map(\.id))
        activities.removeAll { !runningIDs.contains($0.id) }

        for config in runningConfigurations {
            guard !Task.isCancelled else { return }
            let activity = await dockerManager.liveVisitorActivity(
                for: config,
                includeNetworkRate: false
            )
            activities.removeAll { $0.id == config.id }
            if let activity { activities.append(activity) }
            sortActivitiesByServerOrder()
            loadNetworkRate(for: config)
        }
    }

    private func sortActivitiesByServerOrder() {
        let positions = Dictionary(
            uniqueKeysWithValues: configStore.configurations.enumerated().map { ($0.element.id, $0.offset) }
        )
        activities.sort {
            (positions[$0.id] ?? Int.max) < (positions[$1.id] ?? Int.max)
        }
    }

    private func loadNetworkRate(for config: ServerConfiguration) {
        guard speedLoadingServerIDs.insert(config.id).inserted else { return }
        Task {
            let rate = await dockerManager.liveVisitorNetworkRate(for: config)
            speedLoadingServerIDs.remove(config.id)
            guard let index = activities.firstIndex(where: { $0.id == config.id }) else { return }
            let current = activities[index]
            activities[index] = LiveVisitorServerActivity(
                id: current.id,
                serverName: current.serverName,
                webPort: current.webPort,
                containerName: current.containerName,
                status: current.status,
                rxRate: rate.rx,
                txRate: rate.tx,
                activeVisitors: current.activeVisitors
            )
        }
    }
}

private struct LiveVisitorServerCard: View {
    let activity: LiveVisitorServerActivity

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activity.serverName)
                            .font(.headline)
                        Text(activity.containerName + " · :" + String(activity.webPort))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MetricPill(label: "Visitors", value: "\(activity.activeVisitors.count)", systemImage: "person.2")
                    MetricPill(label: "Speed", value: "↓ \(activity.rxRate) · ↑ \(activity.txRate)", systemImage: "speedometer")
                }

                if activity.activeVisitors.isEmpty {
                    Text("No active visitors found.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        ForEach(activity.activeVisitors) { visitor in
                            LiveVisitorRow(visitor: visitor)
                            if visitor.id != activity.activeVisitors.last?.id {
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

private struct MetricPill: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LiveVisitorRow: View {
    let visitor: LiveVisitorEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(visitor.ip)
                        .font(.system(.caption, design: .monospaced).bold())
                    Text(visitorClientLabel(visitor.userAgent))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(visitor.userAgent.isEmpty ? "Unknown client" : visitor.userAgent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 230, alignment: .leading)

            Text("\(visitor.method) \(visitor.path)")
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text("\(visitor.status) · \(visitor.requests)x · \(visitor.lastSeenSecondsAgo)s")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }
}

private func visitorClientLabel(_ agent: String) -> String {
    if agent.range(of: "Mobile|Android|iPhone|iPad", options: .regularExpression) != nil { return "Mobile" }
    if agent.range(of: "Safari", options: .caseInsensitive) != nil,
       agent.range(of: "Chrome|Chromium|Edg", options: .regularExpression) == nil { return "Safari" }
    if agent.range(of: "Edg", options: .caseInsensitive) != nil { return "Edge" }
    if agent.range(of: "Chrome|Chromium", options: .regularExpression) != nil { return "Chrome" }
    if agent.range(of: "Firefox", options: .caseInsensitive) != nil { return "Firefox" }
    return agent.isEmpty ? "Client" : "Browser"
}
