import SwiftUI

struct WebServerConfigView: View {
    @ObservedObject var viewModel: ServerViewModel
    @State private var mountRows: [MountRowEntry] = []
    
    var body: some View {
        Form {
            Section("Web Server Type") {
                Picker("Server", selection: $viewModel.configuration.webServerType) {
                    ForEach(WebServerType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                
                Text("Choose between Apache or Nginx as web server")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Port Configuration") {
                HStack {
                    TextField("Port", value: $viewModel.configuration.webServerPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Default: 8080")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(verbatim: "The port where the web server is reachable (localhost:\(viewModel.configuration.webServerPort))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Container Resources (Web Server)") {
                LabeledContent("CPU Cores (--cpus)") {
                    TextField("e.g. 1.5", text: $viewModel.configuration.webServerCPUs)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("RAM Limit (--memory)") {
                    TextField("e.g. 512m or 1g", text: $viewModel.configuration.webServerMemoryLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            
            Section("Document Root") {
                HStack {
                    TextField("Path", text: $viewModel.configuration.webServerDocumentRoot)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Choose...") {
                        selectDocumentRoot()
                    }
                }
                
                Text("The local directory mounted as web root")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                if FileManager.default.fileExists(atPath: viewModel.configuration.webServerDocumentRoot) {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Directory exists")
                            .font(.caption)
                    }
                } else {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Directory does not exist - it will be created automatically")
                            .font(.caption)
                    }
                }

                HStack {
                    Button("Repair Permissions") {
                        Task {
                            await viewModel.fixDocumentRootPermissions()
                        }
                    }
                    .disabled(viewModel.isFixingPermissions)

                    if viewModel.isFixingPermissions {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                Text("Sets safe read permissions for Apache, keeps execute bits, and makes .htaccess readable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Additional bind mounts for Web + PHP containers")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if mountRows.isEmpty {
                    Text("No additional mounts configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach($mountRows) { $row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Host Path")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("/Users/.../folder", text: $row.hostPath)
                            .textFieldStyle(.roundedBorder)

                        Text("Container Path")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("/var/www/folder", text: $row.containerPath)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Toggle("Read only (ro)", isOn: $row.readOnly)
                                .toggleStyle(.switch)
                                .help("Block write access inside container")
                            Spacer()
                            Button(role: .destructive) {
                                removeMountRow(row.id)
                            } label: {
                                Label("Remove", systemImage: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    addMountRow()
                } label: {
                    Label("Add Mount", systemImage: "plus.circle")
                }

                Text("Example: Host `/Users/.../files` -> Container `/var/www/files`")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Host / Docker Parameter") {
                Text("Additional `docker run` parameters for the web server container (one line = one argument).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $viewModel.configuration.webServerAdditionalRunArgs)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }

            if viewModel.configuration.webServerType == .apache {
                Section("Apache MPM") {
                    Picker("MPM", selection: $viewModel.configuration.apacheSettings.mpmType) {
                        Text("event").tag(ApacheMPMType.event)
                        Text("worker").tag(ApacheMPMType.worker)
                        Text("prefork").tag(ApacheMPMType.prefork)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("StartServers") {
                        TextField("", value: $viewModel.configuration.apacheSettings.startServers, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledContent("ServerLimit") {
                        TextField("", value: $viewModel.configuration.apacheSettings.serverLimit, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledContent("ThreadsPerChild") {
                        TextField("", value: $viewModel.configuration.apacheSettings.threadsPerChild, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledContent("MinSpareThreads") {
                        TextField("", value: $viewModel.configuration.apacheSettings.minSpareThreads, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledContent("MaxSpareThreads") {
                        TextField("", value: $viewModel.configuration.apacheSettings.maxSpareThreads, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                    LabeledContent("MaxRequestWorkers") {
                        TextField("", value: $viewModel.configuration.apacheSettings.maxRequestWorkers, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                    }
                }

                Section("Apache Module & Security") {
                    Toggle("Enable mod_deflate (compression)", isOn: $viewModel.configuration.apacheSettings.enableDeflate)
                    Toggle("Enable mod_rewrite", isOn: $viewModel.configuration.apacheSettings.enableRewrite)
                    Toggle("Enable mod_expires", isOn: $viewModel.configuration.apacheSettings.enableExpires)
                    if viewModel.configuration.apacheSettings.enableExpires {
                        LabeledContent("ExpiresDefault") {
                            TextField("access plus 7 days", text: $viewModel.configuration.apacheSettings.expiresDefault)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                    }
                    Toggle("ServerTokens Prod", isOn: $viewModel.configuration.apacheSettings.serverTokensProd)
                    Toggle("ServerSignature Off", isOn: $viewModel.configuration.apacheSettings.serverSignatureOff)
                    Toggle("TraceEnable Off", isOn: $viewModel.configuration.apacheSettings.traceEnableOff)
                    Toggle("FileETag enabled", isOn: $viewModel.configuration.apacheSettings.fileETagEnabled)
                    Toggle("Require all granted", isOn: $viewModel.configuration.apacheSettings.requireAllGranted)
                    Toggle("Allow only specific IPs", isOn: $viewModel.configuration.apacheSettings.restrictToSpecificIPs)
                    Toggle("AllowOverride All", isOn: $viewModel.configuration.apacheSettings.allowOverrideAll)

                    if viewModel.configuration.apacheSettings.restrictToSpecificIPs {
                        Text("Allowed IPs/CIDRs (e.g. `192.168.1.10`, `10.0.0.0/24`; separated by spaces, commas, or new lines)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $viewModel.configuration.apacheSettings.allowedIPs)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }

                    Text("mod_proxy and mod_proxy_fcgi are enabled automatically for PHP-FPM.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Apache Connection Tuning") {
                    Toggle("KeepAlive enabled", isOn: $viewModel.configuration.apacheSettings.keepAliveEnabled)

                    LabeledContent("Max KeepAlive Requests") {
                        TextField("", value: $viewModel.configuration.apacheSettings.maxKeepAliveRequests, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("KeepAlive Timeout (s)") {
                        TextField("", value: $viewModel.configuration.apacheSettings.keepAliveTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    Toggle("EnableSendfile", isOn: $viewModel.configuration.apacheSettings.enableSendfile)
                    Toggle("EnableMMAP", isOn: $viewModel.configuration.apacheSettings.enableMMAP)
                }

                Section("Apache Timeouts") {
                    LabeledContent("Timeout (s)") {
                        TextField("", value: $viewModel.configuration.apacheSettings.timeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    LabeledContent("ProxyTimeout (s)") {
                        TextField("", value: $viewModel.configuration.apacheSettings.proxyTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    LabeledContent("RequestReadTimeout") {
                        TextField("header=20-40,MinRate=500 body=20,MinRate=500", text: $viewModel.configuration.apacheSettings.requestReadTimeout)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 360)
                    }
                }

                Section("Apache Request Limits") {
                    LabeledContent("LimitRequestBody") {
                        TextField("0", value: $viewModel.configuration.apacheSettings.limitRequestBody, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    LabeledContent("LimitRequestFields") {
                        TextField("", value: $viewModel.configuration.apacheSettings.limitRequestFields, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    LabeledContent("LimitRequestLine") {
                        TextField("", value: $viewModel.configuration.apacheSettings.limitRequestLine, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Apache Logging") {
                    LabeledContent("LogLevel") {
                        TextField("warn", text: $viewModel.configuration.apacheSettings.logLevel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                    LabeledContent("ErrorLog Target") {
                        TextField("/proc/self/fd/2", text: $viewModel.configuration.apacheSettings.errorLogTarget)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    LabeledContent("CustomLog Target") {
                        TextField("/proc/self/fd/1", text: $viewModel.configuration.apacheSettings.customLogTarget)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    Text("CustomLog Format")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.configuration.apacheSettings.customLogFormat)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 70)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }

                Section("Apache Security Headers") {
                    Toggle("X-Frame-Options", isOn: $viewModel.configuration.apacheSettings.headerXFrameOptionsEnabled)
                    if viewModel.configuration.apacheSettings.headerXFrameOptionsEnabled {
                        LabeledContent("X-Frame-Options Value") {
                            TextField("SAMEORIGIN", text: $viewModel.configuration.apacheSettings.headerXFrameOptionsValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                    }

                    Toggle("X-Content-Type-Options nosniff", isOn: $viewModel.configuration.apacheSettings.headerXContentTypeOptionsEnabled)
                    Toggle("Referrer-Policy", isOn: $viewModel.configuration.apacheSettings.headerReferrerPolicyEnabled)
                    if viewModel.configuration.apacheSettings.headerReferrerPolicyEnabled {
                        LabeledContent("Referrer-Policy Value") {
                            TextField("strict-origin-when-cross-origin", text: $viewModel.configuration.apacheSettings.headerReferrerPolicyValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                    }
                    Toggle("Content-Security-Policy", isOn: $viewModel.configuration.apacheSettings.headerCSPEnabled)
                    if viewModel.configuration.apacheSettings.headerCSPEnabled {
                        TextEditor(text: $viewModel.configuration.apacheSettings.headerCSPValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                }

                Section("Apache Proxy") {
                    Toggle("ProxyPreserveHost", isOn: $viewModel.configuration.apacheSettings.proxyPreserveHost)
                    Toggle("SSLProxyEngine", isOn: $viewModel.configuration.apacheSettings.sslProxyEngineEnabled)
                    Text("Additional ProxyPass/ProxyPassReverse rules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $viewModel.configuration.apacheSettings.proxyPassRules)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }

                Section("Apache Directory Options") {
                    Toggle("Indexes", isOn: $viewModel.configuration.apacheSettings.optionIndexes)
                    Toggle("Disable DirectoryIndex (force directory listing)", isOn: $viewModel.configuration.apacheSettings.forceDirectoryListing)
                    Toggle("Includes", isOn: $viewModel.configuration.apacheSettings.optionIncludes)
                    Toggle("ExecCGI", isOn: $viewModel.configuration.apacheSettings.optionExecCGI)
                    Toggle("SymLinksIfOwnerMatch", isOn: $viewModel.configuration.apacheSettings.optionSymLinksIfOwnerMatch)
                    Toggle("IncludesNoExec", isOn: $viewModel.configuration.apacheSettings.optionIncludesNoExec)
                    Toggle("FollowSymLinks", isOn: $viewModel.configuration.apacheSettings.optionFollowSymLinks)
                    Toggle("MultiViews", isOn: $viewModel.configuration.apacheSettings.optionMultiViews)
                }

                Section("Apache Advanced Directives") {
                    Text("Additional VirtualHost directives")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.configuration.apacheSettings.virtualHostDirectives)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                    Text("Global additional Apache directives")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.configuration.apacheSettings.additionalDirectives)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            } else {
                Section("Nginx Module & Security") {
                    Toggle("Enable gzip", isOn: $viewModel.configuration.nginxSettings.gzipEnabled)
                    Toggle("Autoindex (Directory Listing)", isOn: $viewModel.configuration.nginxSettings.autoIndexEnabled)
                    Toggle("sendfile", isOn: $viewModel.configuration.nginxSettings.sendfileEnabled)
                    Toggle("tcp_nopush", isOn: $viewModel.configuration.nginxSettings.tcpNopushEnabled)
                    Toggle("tcp_nodelay", isOn: $viewModel.configuration.nginxSettings.tcpNodelayEnabled)
                }

                Section("Nginx Worker & Connection") {
                    LabeledContent("worker_processes") {
                        TextField("auto", text: $viewModel.configuration.nginxSettings.workerProcesses)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("worker_connections") {
                        TextField("", value: $viewModel.configuration.nginxSettings.workerConnections, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("keepalive_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.keepaliveTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Nginx Request & FastCGI") {
                    LabeledContent("client_max_body_size") {
                        TextField("e.g. 64m", text: $viewModel.configuration.nginxSettings.clientMaxBodySize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("try_files") {
                        TextField("$uri $uri/ /index.php?$query_string", text: $viewModel.configuration.nginxSettings.tryFilesRule)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 320)
                    }

                    LabeledContent("gzip_min_length") {
                        TextField("", value: $viewModel.configuration.nginxSettings.gzipMinLength, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("client_body_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.clientBodyTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("client_header_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.clientHeaderTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("send_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.sendTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Nginx FastCGI Timeouts & Buffers") {
                    LabeledContent("fastcgi_connect_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.fastcgiConnectTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("fastcgi_send_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.fastcgiSendTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("fastcgi_read_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.fastcgiReadTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("fastcgi_buffer_size") {
                        TextField("32k", text: $viewModel.configuration.nginxSettings.fastcgiBufferSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("fastcgi_buffers count") {
                        TextField("", value: $viewModel.configuration.nginxSettings.fastcgiBuffersCount, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("fastcgi_buffers size") {
                        TextField("16k", text: $viewModel.configuration.nginxSettings.fastcgiBuffersSize)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Nginx Proxy Timeouts") {
                    LabeledContent("proxy_connect_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.proxyConnectTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("proxy_send_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.proxySendTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }

                    LabeledContent("proxy_read_timeout (s)") {
                        TextField("", value: $viewModel.configuration.nginxSettings.proxyReadTimeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Nginx Logging") {
                    Toggle("access_log enabled", isOn: $viewModel.configuration.nginxSettings.accessLogEnabled)

                    LabeledContent("error_log level") {
                        TextField("warn", text: $viewModel.configuration.nginxSettings.errorLogLevel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                    }
                }

                Section("Nginx Security Headers") {
                    Toggle("X-Frame-Options", isOn: $viewModel.configuration.nginxSettings.headerXFrameOptionsEnabled)
                    if viewModel.configuration.nginxSettings.headerXFrameOptionsEnabled {
                        LabeledContent("X-Frame-Options Value") {
                            TextField("SAMEORIGIN", text: $viewModel.configuration.nginxSettings.headerXFrameOptionsValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                    }

                    Toggle("X-Content-Type-Options nosniff", isOn: $viewModel.configuration.nginxSettings.headerXContentTypeOptionsEnabled)

                    Toggle("Referrer-Policy", isOn: $viewModel.configuration.nginxSettings.headerReferrerPolicyEnabled)
                    if viewModel.configuration.nginxSettings.headerReferrerPolicyEnabled {
                        LabeledContent("Referrer-Policy Value") {
                            TextField("strict-origin-when-cross-origin", text: $viewModel.configuration.nginxSettings.headerReferrerPolicyValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                        }
                    }

                    Toggle("Content-Security-Policy", isOn: $viewModel.configuration.nginxSettings.headerCSPEnabled)
                    if viewModel.configuration.nginxSettings.headerCSPEnabled {
                        TextEditor(text: $viewModel.configuration.nginxSettings.headerCSPValue)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 70)
                            .padding(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                    }
                }

                Section("Nginx Static Cache") {
                    Toggle("Static File Cache enabled", isOn: $viewModel.configuration.nginxSettings.staticCacheEnabled)
                    if viewModel.configuration.nginxSettings.staticCacheEnabled {
                        LabeledContent("expires") {
                            TextField("e.g. 7d", text: $viewModel.configuration.nginxSettings.staticCacheExpires)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                        }
                    }
                }

                Section("Nginx Advanced Directives") {
                    Text("Additional directives in `server` block")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.configuration.nginxSettings.additionalServerDirectives)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                    Text("Additional directives in `location /` block")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.configuration.nginxSettings.additionalLocationDirectives)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )

                    Text("Additional full `location` blocks")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextEditor(text: $viewModel.configuration.nginxSettings.additionalLocationBlocks)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 130)
                        .padding(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                }
            }

            Section {
                Button("Save Changes") {
                    commitPendingEdits()
                    syncConfigurationFromMountRows()
                    viewModel.saveConfiguration()
                }
                .buttonStyle(.borderedProminent)
                
                if viewModel.isRunning {
                    Text("⚠️ Server must be restarted for changes to take effect")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncMountRowsFromConfiguration()
        }
        .onChange(of: viewModel.configuration.id) { _, _ in
            syncMountRowsFromConfiguration()
        }
        .onChange(of: mountRows) { _, _ in
            syncConfigurationFromMountRows()
        }
    }
    
    private func commitPendingEdits() {
        NSApp.keyWindow?.endEditing(for: nil)
        NSApp.mainWindow?.endEditing(for: nil)
    }

    private func selectDocumentRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Select the document root directory"
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.configuration.webServerDocumentRoot = url.path
        }
    }

    private func addMountRow() {
        mountRows.append(MountRowEntry())
    }

    private func removeMountRow(_ id: UUID) {
        mountRows.removeAll { $0.id == id }
    }

    private func syncMountRowsFromConfiguration() {
        mountRows = parseMountRows(from: viewModel.configuration.additionalContainerMounts)
    }

    private func syncConfigurationFromMountRows() {
        viewModel.configuration.additionalContainerMounts = serializeMountRows(mountRows)
    }

    private func parseMountRows(from raw: String) -> [MountRowEntry] {
        raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                let components = line.components(separatedBy: ":")
                guard components.count >= 2 else { return nil }
                let host = components[0]
                let container = components[1]
                let readOnly = components.dropFirst(2).contains("ro")
                return MountRowEntry(hostPath: host, containerPath: container, readOnly: readOnly)
            }
    }

    private func serializeMountRows(_ rows: [MountRowEntry]) -> String {
        rows
            .map { row -> String? in
                let host = row.hostPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let container = row.containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !host.isEmpty, !container.isEmpty else { return nil }
                return row.readOnly ? "\(host):\(container):ro" : "\(host):\(container)"
            }
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private struct MountRowEntry: Identifiable, Equatable {
        var id = UUID()
        var hostPath: String = ""
        var containerPath: String = ""
        var readOnly: Bool = false
    }
}

#Preview {
    WebServerConfigView(viewModel: ServerViewModel(configuration: ServerConfiguration()))
}
