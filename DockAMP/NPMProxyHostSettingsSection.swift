import SwiftUI

struct NPMProxyHostSettingsSection: View {
    @ObservedObject var viewModel: ServerViewModel

    var body: some View {
        Section("Nginx Proxy Manager") {
            Toggle("Automatically manage Proxy Host in NPM", isOn: $viewModel.configuration.npmProxyEnabled)

            HStack {
                Button(viewModel.configuration.npmProxyEnabled ? "Create / Update Proxy Host" : "Apply and Remove Managed Host") {
                    Task { await viewModel.syncNPMProxyHost() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isProxySyncing)

                Button("Adopt Existing NPM Host") {
                    Task { await viewModel.adoptExistingNPMProxyHost() }
                }
                .disabled(viewModel.isProxySyncing)

                if viewModel.isProxySyncing {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Text("Status: \(statusLabel)")
                    .font(.caption)
                if let hostID = viewModel.configuration.npmProxyHostID {
                    Text("Managed host ID: \(hostID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !viewModel.configuration.npmProxyError.isEmpty {
                Text(viewModel.configuration.npmProxyError)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var statusLabel: String {
        switch viewModel.configuration.npmProxyStatus {
        case "ssl": return "HTTPS"
        case "http": return "HTTP"
        case "disabled": return "Disabled"
        case "error": return "Error"
        default: return "Not created"
        }
    }
}
