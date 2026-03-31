import SwiftUI

struct PHPConfigView: View {
    @ObservedObject var viewModel: ServerViewModel
    @StateObject private var phpVersionStore = PHPVersionStore.shared
    
    var body: some View {
        Form {
            Section("PHP Version") {
                Picker("Version", selection: $viewModel.configuration.phpVersion) {
                    ForEach(availablePHPVersions, id: \.self) { version in
                        Text("PHP \(version)").tag(version)
                    }
                }
                .pickerStyle(.menu)
                
                Text("Choose the desired PHP version")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Container Resources (PHP)") {
                LabeledContent("CPU Cores (--cpus)") {
                    TextField("e.g. 1.0", text: $viewModel.configuration.phpCPUs)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("RAM Limit (--memory)") {
                        TextField("e.g. 512m or 1g", text: $viewModel.configuration.phpMemoryLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }
            }
            
            Section("Memory & Performance") {
                LabeledContent("Memory Limit") {
                    TextField("Memory Limit", text: $viewModel.configuration.phpSettings.memoryLimit)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                
                LabeledContent("Max Execution Time") {
                    HStack {
                        TextField("Seconds", value: $viewModel.configuration.phpSettings.maxExecutionTime, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("Seconds")
                            .foregroundStyle(.secondary)
                    }
                }
                
                LabeledContent("Max Input Time") {
                    HStack {
                        TextField("Seconds", value: $viewModel.configuration.phpSettings.maxInputTime, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)
                        Text("Seconds")
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Max Input Vars") {
                    TextField("", value: $viewModel.configuration.phpSettings.maxInputVars, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("Socket Timeout (s)") {
                    TextField("", value: $viewModel.configuration.phpSettings.defaultSocketTimeout, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("realpath_cache_size") {
                    TextField("4096K", text: $viewModel.configuration.phpSettings.realpathCacheSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("realpath_cache_ttl") {
                    TextField("", value: $viewModel.configuration.phpSettings.realpathCacheTTL, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }
            
            Section("Upload Settings") {
                LabeledContent("Upload Max Filesize") {
                    TextField("Upload Max", text: $viewModel.configuration.phpSettings.uploadMaxFilesize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                
                LabeledContent("Post Max Size") {
                    TextField("Post Max", text: $viewModel.configuration.phpSettings.postMaxSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                Toggle("File Uploads enabled", isOn: $viewModel.configuration.phpSettings.fileUploadsEnabled)

                LabeledContent("Max File Uploads") {
                    TextField("", value: $viewModel.configuration.phpSettings.maxFileUploads, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                
                Text("Use values like '64M' or '2G'")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Error Handling") {
                Toggle("Display Errors", isOn: $viewModel.configuration.phpSettings.displayErrors)
                Toggle("Display Startup Errors", isOn: $viewModel.configuration.phpSettings.displayStartupErrors)
                Toggle("Log Errors", isOn: $viewModel.configuration.phpSettings.logErrors)
                
                LabeledContent("Error Reporting") {
                    TextField("Error Reporting", text: $viewModel.configuration.phpSettings.errorReporting)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                LabeledContent("Error Log") {
                    TextField("/proc/self/fd/2", text: $viewModel.configuration.phpSettings.errorLogPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }
                
                Text("Default: E_ALL for development")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Section("Timezone") {
                Picker("Timezone", selection: $viewModel.configuration.phpSettings.timezone) {
                    Text("Europe/Zurich").tag("Europe/Zurich")
                    Text("Europe/Berlin").tag("Europe/Berlin")
                    Text("Europe/Vienna").tag("Europe/Vienna")
                    Text("UTC").tag("UTC")
                    Text("America/New_York").tag("America/New_York")
                    Text("America/Los_Angeles").tag("America/Los_Angeles")
                }
            }

            Section("Security") {
                Toggle("expose_php", isOn: $viewModel.configuration.phpSettings.exposePHP)
                Toggle("allow_url_fopen", isOn: $viewModel.configuration.phpSettings.allowURLFopen)
                Toggle("allow_url_include", isOn: $viewModel.configuration.phpSettings.allowURLInclude)

                LabeledContent("disable_functions") {
                    TextField("e.g. exec,passthru,shell_exec", text: $viewModel.configuration.phpSettings.disableFunctions)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 320)
                }
            }

            Section("Session") {
                LabeledContent("session.save_handler") {
                    TextField("files", text: $viewModel.configuration.phpSettings.sessionSaveHandler)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                }

                LabeledContent("session.save_path") {
                    TextField("/tmp", text: $viewModel.configuration.phpSettings.sessionSavePath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                }

                LabeledContent("session.gc_maxlifetime") {
                    TextField("", value: $viewModel.configuration.phpSettings.sessionGCMaxLifetime, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                Toggle("session.cookie_secure", isOn: $viewModel.configuration.phpSettings.sessionCookieSecure)
                Toggle("session.cookie_httponly", isOn: $viewModel.configuration.phpSettings.sessionCookieHTTPOnly)

                Picker("session.cookie_samesite", selection: $viewModel.configuration.phpSettings.sessionCookieSameSite) {
                    Text("Lax").tag("Lax")
                    Text("Strict").tag("Strict")
                    Text("None").tag("None")
                }
                .pickerStyle(.segmented)
            }

            Section("OPcache") {
                Toggle("opcache.enable", isOn: $viewModel.configuration.phpSettings.opcacheEnabled)

                LabeledContent("opcache.memory_consumption") {
                    TextField("", value: $viewModel.configuration.phpSettings.opcacheMemoryConsumption, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("opcache.max_accelerated_files") {
                    TextField("", value: $viewModel.configuration.phpSettings.opcacheMaxAcceleratedFiles, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                Toggle("opcache.validate_timestamps", isOn: $viewModel.configuration.phpSettings.opcacheValidateTimestamps)

                LabeledContent("opcache.revalidate_freq") {
                    TextField("", value: $viewModel.configuration.phpSettings.opcacheRevalidateFreq, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                Toggle("Enable opcache.jit", isOn: $viewModel.configuration.phpSettings.opcacheJITEnabled)
                LabeledContent("opcache.jit_buffer_size") {
                    TextField("128M", text: $viewModel.configuration.phpSettings.opcacheJITBufferSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
                LabeledContent("opcache.jit") {
                    TextField("1255", text: $viewModel.configuration.phpSettings.opcacheJITMode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            Section("Extensions (Core)") {
                Toggle("Enable MySQL Extensions (mysqli / pdo_mysql)", isOn: $viewModel.configuration.phpSettings.enableMySQLExtensions)
                Toggle("GD (image processing)", isOn: $viewModel.configuration.phpSettings.enableGD)
                Toggle("GD WebP Support", isOn: $viewModel.configuration.phpSettings.enableGDWebP)
                Toggle("GD AVIF Support", isOn: $viewModel.configuration.phpSettings.enableGDAvif)
                Toggle("Intl (internationalization)", isOn: $viewModel.configuration.phpSettings.enableIntl)
                Toggle("ZIP", isOn: $viewModel.configuration.phpSettings.enableZip)
                Toggle("BCMath", isOn: $viewModel.configuration.phpSettings.enableBCMath)
                Toggle("EXIF", isOn: $viewModel.configuration.phpSettings.enableExif)
                Toggle("SOAP", isOn: $viewModel.configuration.phpSettings.enableSOAP)
                Toggle("XSL", isOn: $viewModel.configuration.phpSettings.enableXSL)
                Toggle("PDO PgSQL", isOn: $viewModel.configuration.phpSettings.enablePDOPgSQL)
                Toggle("PgSQL", isOn: $viewModel.configuration.phpSettings.enablePgSQL)
                Toggle("MBString", isOn: $viewModel.configuration.phpSettings.enableMBString)
                Toggle("Sockets", isOn: $viewModel.configuration.phpSettings.enableSockets)
                Toggle("PCNTL", isOn: $viewModel.configuration.phpSettings.enablePCNTL)
                Toggle("PDO SQLite", isOn: $viewModel.configuration.phpSettings.enablePDOSQLite)
                Toggle("SQLite3", isOn: $viewModel.configuration.phpSettings.enableSQLite3)
                Toggle("cURL", isOn: $viewModel.configuration.phpSettings.enableCurlExtension)
                Toggle("DOM", isOn: $viewModel.configuration.phpSettings.enableDOMExtension)
                Toggle("XML", isOn: $viewModel.configuration.phpSettings.enableXMLExtension)
                Toggle("SimpleXML", isOn: $viewModel.configuration.phpSettings.enableSimpleXMLExtension)
                Toggle("FTP / FTPS", isOn: $viewModel.configuration.phpSettings.enableFTPExtension)

                Text("Enabled by default for WordPress and MySQL/MariaDB projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Extensions (PECL)") {
                Toggle("Redis (PECL)", isOn: $viewModel.configuration.phpSettings.enableRedisExtension)
                Toggle("Imagick (PECL)", isOn: $viewModel.configuration.phpSettings.enableImagickExtension)
                Toggle("Xdebug (PECL)", isOn: $viewModel.configuration.phpSettings.enableXdebugExtension)
                Toggle("SSH2 (PECL)", isOn: $viewModel.configuration.phpSettings.enableSSH2Extension)
            }

            Section("System Tools (apt)") {
                Toggle("Install zip/unzip", isOn: $viewModel.configuration.phpSettings.installZipBinaryTools)
                Toggle("libarchive-tools (bsdtar)", isOn: $viewModel.configuration.phpSettings.installLibarchiveTools)
                Toggle("ICU full data", isOn: $viewModel.configuration.phpSettings.installICUFullData)
                Toggle("git", isOn: $viewModel.configuration.phpSettings.installGitTool)
                Toggle("curl + wget", isOn: $viewModel.configuration.phpSettings.installCurlWgetTools)
                Toggle("nano + vim editors", isOn: $viewModel.configuration.phpSettings.installEditorsNanoVim)
                Toggle("tree", isOn: $viewModel.configuration.phpSettings.installTreeTool)
                Toggle("rsync", isOn: $viewModel.configuration.phpSettings.installRsyncTool)
                Toggle("ffmpeg", isOn: $viewModel.configuration.phpSettings.installFFmpegTool)
                Toggle("ghostscript", isOn: $viewModel.configuration.phpSettings.installGhostscriptTool)
                Toggle("ImageMagick CLI", isOn: $viewModel.configuration.phpSettings.installImageMagickTools)
                Toggle("Node.js + npm", isOn: $viewModel.configuration.phpSettings.installNodeJSTools)
                Toggle("Composer", isOn: $viewModel.configuration.phpSettings.installComposerTool)

                Text("Enabled by default for WordPress and MySQL/MariaDB projects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("PHP-FPM Process Manager") {
                Picker("pm", selection: $viewModel.configuration.phpSettings.fpmProcessManager) {
                    Text("dynamic").tag("dynamic")
                    Text("ondemand").tag("ondemand")
                    Text("static").tag("static")
                }
                .pickerStyle(.segmented)

                LabeledContent("pm.max_children") {
                    TextField("", value: $viewModel.configuration.phpSettings.fpmMaxChildren, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("pm.start_servers") {
                    TextField("", value: $viewModel.configuration.phpSettings.fpmStartServers, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("pm.min_spare_servers") {
                    TextField("", value: $viewModel.configuration.phpSettings.fpmMinSpareServers, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("pm.max_spare_servers") {
                    TextField("", value: $viewModel.configuration.phpSettings.fpmMaxSpareServers, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }

                LabeledContent("pm.max_requests") {
                    TextField("", value: $viewModel.configuration.phpSettings.fpmMaxRequests, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                }
            }

            Section("Additional php.ini Directives") {
                TextEditor(text: $viewModel.configuration.phpSettings.additionalIniDirectives)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 110)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
            }
            
            Section {
                Button("Save Changes") {
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
        .task {
            await phpVersionStore.refreshIfNeeded()
        }
    }

    private var availablePHPVersions: [String] {
        let versions = phpVersionStore.availableVersions
        if versions.contains(viewModel.configuration.phpVersion) {
            return versions
        }
        return [viewModel.configuration.phpVersion] + versions
    }
}

#Preview {
    PHPConfigView(viewModel: ServerViewModel(configuration: ServerConfiguration()))
}
