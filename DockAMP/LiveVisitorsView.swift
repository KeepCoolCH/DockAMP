import SwiftUI

struct LiveVisitorsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var configStore = ConfigurationStore.shared
    @StateObject private var dockerManager = DockerManager.shared

    @State private var activities: [LiveVisitorServerActivity] = []
    @State private var isLoading = false
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
                .disabled(isLoading)

                Button("Close") {
                    dismiss()
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                if activities.isEmpty && !isLoading {
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
            .overlay {
                if isLoading {
                    ProgressView("Loading activity...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                await loadActivity(showSpinner: false)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func loadActivity(showSpinner: Bool = true) async {
        if showSpinner { isLoading = true }
        defer {
            if showSpinner { isLoading = false }
        }

        do {
            activities = try await dockerManager.liveVisitorActivity(for: configStore.configurations)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
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
                        Text("\(activity.containerName) · :\(activity.webPort)")
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
