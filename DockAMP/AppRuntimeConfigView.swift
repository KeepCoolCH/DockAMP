import SwiftUI

struct AppRuntimeConfigView: View {
    @ObservedObject var viewModel: ServerViewModel

    var body: some View {
        Form {
            Section(viewModel.configuration.serverType.rawValue) {
                if viewModel.configuration.serverType == .python {
                    Picker("Version", selection: $viewModel.configuration.pythonSettings.version) {
                        ForEach(["3.13", "3.12", "3.11", "3.10", "3.9"], id: \.self) {
                            Text("Python \($0)").tag($0)
                        }
                    }
                    Picker("Framework", selection: $viewModel.configuration.pythonSettings.framework) {
                        ForEach(PythonFramework.allCases) { framework in
                            Text(framework.displayName).tag(framework)
                        }
                    }
                    .onChange(of: viewModel.configuration.pythonSettings.framework) { oldValue, newValue in
                        applyPythonFrameworkDefaults(from: oldValue, to: newValue)
                    }
                    numericField("Internal Port", value: $viewModel.configuration.pythonSettings.containerPort)
                    textField("Start Command", text: $viewModel.configuration.pythonSettings.startCommand)
                    LabeledContent("Requirements") {
                        TextEditor(text: $viewModel.configuration.pythonSettings.requirements)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                    }
                } else {
                    Picker("Version", selection: $viewModel.configuration.nodeSettings.version) {
                        ForEach(["24", "22", "20", "18"], id: \.self) {
                            Text("Node.js \($0)").tag($0)
                        }
                    }
                    Picker("Framework", selection: $viewModel.configuration.nodeSettings.framework) {
                        ForEach(NodeFramework.allCases) { framework in
                            Text(framework.displayName).tag(framework)
                        }
                    }
                    .onChange(of: viewModel.configuration.nodeSettings.framework) { oldValue, newValue in
                        applyNodeFrameworkDefaults(from: oldValue, to: newValue)
                    }
                    numericField("Internal Port", value: $viewModel.configuration.nodeSettings.containerPort)
                    textField("Start Command", text: $viewModel.configuration.nodeSettings.startCommand)
                    textField("Install Command", text: $viewModel.configuration.nodeSettings.installCommand)
                    Toggle("Use node_modules volume", isOn: $viewModel.configuration.nodeSettings.useNodeModulesVolume)
                }
            }

            NPMProxyHostSettingsSection(viewModel: viewModel)

            Section("Container") {
                textField("CPU Cores (--cpus)", text: $viewModel.configuration.webServerCPUs)
                textField("RAM Limit (--memory)", text: $viewModel.configuration.webServerMemoryLimit)
                textField("Additional docker run arguments", text: $viewModel.configuration.webServerAdditionalRunArgs)
            }

            Text("Runtime changes are applied when the app container is restarted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func textField(_ label: String, text: Binding<String>) -> some View {
        LabeledContent(label) {
            TextField("", text: text).textFieldStyle(.roundedBorder).frame(minWidth: 260)
        }
    }

    private func numericField(_ label: String, value: Binding<Int>) -> some View {
        LabeledContent(label) {
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 110)
        }
    }

    private func applyPythonFrameworkDefaults(from oldValue: PythonFramework, to newValue: PythonFramework) {
        let knownCommands = Set(PythonFramework.allCases.map(\.startCommand))
        let knownRequirements = Set(PythonFramework.allCases.map(\.suggestedRequirements) + ["fastapi\nuvicorn"])
        let currentCommand = viewModel.configuration.pythonSettings.startCommand
        let currentRequirements = viewModel.configuration.pythonSettings.requirements
        if currentCommand.isEmpty || knownCommands.contains(currentCommand) || currentCommand == oldValue.startCommand {
            viewModel.configuration.pythonSettings.startCommand = newValue.startCommand
        }
        if currentRequirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || knownRequirements.contains(currentRequirements)
            || currentRequirements == oldValue.suggestedRequirements {
            viewModel.configuration.pythonSettings.requirements = newValue.suggestedRequirements
        }
        viewModel.configuration.pythonSettings.containerPort = newValue.containerPort
    }

    private func applyNodeFrameworkDefaults(from oldValue: NodeFramework, to newValue: NodeFramework) {
        let knownCommands = Set(NodeFramework.allCases.map(\.startCommand))
        let knownInstalls = Set(NodeFramework.allCases.map(\.installCommand))
        let currentCommand = viewModel.configuration.nodeSettings.startCommand
        let currentInstall = viewModel.configuration.nodeSettings.installCommand
        if currentCommand.isEmpty || knownCommands.contains(currentCommand) || currentCommand == oldValue.startCommand {
            viewModel.configuration.nodeSettings.startCommand = newValue.startCommand
        }
        if currentInstall.isEmpty || knownInstalls.contains(currentInstall) || currentInstall == oldValue.installCommand {
            viewModel.configuration.nodeSettings.installCommand = newValue.installCommand
        }
        viewModel.configuration.nodeSettings.containerPort = newValue.containerPort
    }
}
