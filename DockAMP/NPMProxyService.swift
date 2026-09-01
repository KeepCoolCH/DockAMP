import Foundation

struct NPMProxyHost: Identifiable, Hashable {
    let id: Int
    let domainNames: [String]
    let forwardHost: String
    let forwardPort: Int
    let certificateID: Int

    var displayName: String { domainNames.joined(separator: ", ") }
    var usesSSL: Bool { certificateID > 0 }
}

struct NPMProxySyncResult {
    let hostID: Int
    let status: String
    let certificateError: String
}

enum NPMProxyError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

final class NPMProxyService {
    static let shared = NPMProxyService()
    private init() {}

    func testConnection(settings: ProxyManagerSettings) async throws -> Int {
        let token = try await token(settings: settings)
        return try await proxyHostDictionaries(settings: settings, token: token).count
    }

    func proxyHosts(settings: ProxyManagerSettings) async throws -> [NPMProxyHost] {
        let token = try await token(settings: settings)
        return try await proxyHostDictionaries(settings: settings, token: token).compactMap(Self.proxyHost(from:))
    }

    func deleteManagedHost(id: Int, settings: ProxyManagerSettings) async throws {
        let token = try await token(settings: settings)
        _ = try await request(settings: settings, path: "/nginx/proxy-hosts/\(id)", method: "DELETE", token: token)
    }

    func adoptExistingHost(for config: ServerConfiguration, settings: ProxyManagerSettings) async throws -> NPMProxySyncResult {
        let domain = normalizedDomain(config.name)
        guard !domain.isEmpty else { throw NPMProxyError.message("The server name is empty.") }
        let hosts = try await proxyHosts(settings: settings)
        let matches = hosts.filter { host in
            host.domainNames.map(normalizedDomain).contains(domain)
        }
        guard !matches.isEmpty else { throw NPMProxyError.message("No NPM Proxy Host was found for \(domain).") }
        guard matches.count == 1, let host = matches.first else {
            throw NPMProxyError.message("Multiple NPM Proxy Hosts were found for \(domain). Adoption is not unambiguous.")
        }
        if let currentID = config.npmProxyHostID, currentID != host.id {
            throw NPMProxyError.message("This server already manages another NPM Proxy Host.")
        }
        return NPMProxySyncResult(hostID: host.id, status: host.usesSSL ? "ssl" : "http", certificateError: "")
    }

    func syncProxyHost(for config: ServerConfiguration, settings: ProxyManagerSettings) async throws -> NPMProxySyncResult {
        guard !settings.adminEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !settings.adminPassword.isEmpty else {
            throw NPMProxyError.message("NPM credentials are incomplete.")
        }
        let domain = normalizedDomain(config.name)
        guard !domain.isEmpty else { throw NPMProxyError.message("The server name is empty.") }
        let token = try await token(settings: settings)
        let hosts = try await proxyHostDictionaries(settings: settings, token: token)
        var managedHost = hosts.first { Self.int($0["id"]) == config.npmProxyHostID }
        if let conflict = hosts.first(where: {
            let names = ($0["domain_names"] as? [String] ?? []).map(normalizedDomain)
            return names.contains(domain) && Self.int($0["id"]) != config.npmProxyHostID
        }) {
            throw NPMProxyError.message("A foreign NPM Proxy Host already exists for \(domain) (ID \(Self.int(conflict["id"]))). It was not changed.")
        }
        if config.npmProxyHostID != nil && managedHost == nil {
            managedHost = nil
        }
        if let id = managedHost.map({ Self.int($0["id"]) }), id > 0 {
            managedHost = try await request(settings: settings, path: "/nginx/proxy-hosts/\(id)", token: token) as? [String: Any]
        }

        var certificateID = Self.int(managedHost?["certificate_id"]) 
        var certificateError = ""
        if Self.isPublicDomain(domain), certificateID == 0 {
            do {
                let certificates = try await request(settings: settings, path: "/nginx/certificates", token: token) as? [[String: Any]] ?? []
                if let existing = certificates.first(where: {
                    ($0["provider"] as? String) == "letsencrypt" && ($0["domain_names"] as? [String] ?? []).contains(domain)
                }) {
                    certificateID = Self.int(existing["id"])
                } else if let created = try await request(
                    settings: settings,
                    path: "/nginx/certificates",
                    method: "POST",
                    payload: ["provider": "letsencrypt", "domain_names": [domain], "meta": ["dns_challenge": false]],
                    token: token,
                    timeout: 180
                ) as? [String: Any] {
                    certificateID = Self.int(created["id"])
                }
            } catch {
                certificateError = error.localizedDescription
            }
        }

        let sslEnabled = certificateID > 0
        let payload: [String: Any] = [
            "domain_names": [domain],
            "forward_scheme": "http",
            "forward_host": "host.docker.internal",
            "forward_port": config.webServerPort,
            "access_list_id": 0,
            "certificate_id": certificateID,
            "ssl_forced": sslEnabled,
            "caching_enabled": false,
            "block_exploits": true,
            "advanced_config": Self.mergedAdvancedConfig(managedHost?["advanced_config"] as? String),
            "allow_websocket_upgrade": true,
            "http2_support": managedHost?["http2_support"] as? Bool ?? false,
            "hsts_enabled": sslEnabled,
            "hsts_subdomains": sslEnabled,
            "trust_forwarded_proto": false,
            "enabled": true,
            "locations": managedHost?["locations"] as? [[String: Any]] ?? [],
            "meta": [:]
        ]
        let resolvedID = managedHost.map { Self.int($0["id"]) } ?? 0
        let id: Int? = resolvedID > 0 ? resolvedID : nil
        let result = try await request(
            settings: settings,
            path: id.map { "/nginx/proxy-hosts/\($0)" } ?? "/nginx/proxy-hosts",
            method: id == nil ? "POST" : "PUT",
            payload: payload,
            token: token
        ) as? [String: Any]
        let resultID = Self.int(result?["id"])
        let hostID = resultID > 0 ? resultID : (id ?? 0)
        guard hostID > 0 else {
            throw NPMProxyError.message("NPM returned no valid Proxy Host ID.")
        }
        return NPMProxySyncResult(hostID: hostID, status: sslEnabled ? "ssl" : "http", certificateError: certificateError)
    }

    private func proxyHostDictionaries(settings: ProxyManagerSettings, token: String) async throws -> [[String: Any]] {
        try await request(settings: settings, path: "/nginx/proxy-hosts", token: token) as? [[String: Any]] ?? []
    }

    private func token(settings: ProxyManagerSettings) async throws -> String {
        let result = try await request(
            settings: settings,
            path: "/tokens",
            method: "POST",
            payload: ["identity": settings.adminEmail.trimmingCharacters(in: .whitespacesAndNewlines), "secret": settings.adminPassword]
        ) as? [String: Any]
        guard let token = result?["token"] as? String, !token.isEmpty else {
            throw NPMProxyError.message("NPM returned no API token.")
        }
        return token
    }

    private func request(settings: ProxyManagerSettings, path: String, method: String = "GET", payload: [String: Any]? = nil, token: String? = nil, timeout: TimeInterval = 30) async throws -> Any {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let base = apiBaseURL(settings: settings), let url = URL(string: relativePath, relativeTo: base) else {
            throw NPMProxyError.message("The NPM admin address is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DockAMP/macOS", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw NPMProxyError.message("NPM returned an invalid response.") }
            guard (200...299).contains(http.statusCode) else {
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let nested = json?["error"] as? [String: Any]
                let message = nested?["message"] as? String ?? json?["message"] as? String ?? String(data: data, encoding: .utf8)
                throw NPMProxyError.message(message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "NPM API HTTP \(http.statusCode)")
            }
            return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data)
        } catch let error as NPMProxyError {
            throw error
        } catch {
            throw NPMProxyError.message("NPM API is not reachable: \(error.localizedDescription)")
        }
    }

    private func apiBaseURL(settings: ProxyManagerSettings) -> URL? {
        var value = settings.mode == .external ? settings.adminIp.trimmingCharacters(in: .whitespacesAndNewlines) : "localhost"
        if value.isEmpty { value = "localhost" }
        if !value.contains("://") { value = "http://" + value }
        guard var components = URLComponents(string: value) else { return nil }
        if components.port == nil { components.port = settings.adminPort }
        components.path = "/api/"
        return components.url
    }

    private func normalizedDomain(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func proxyHost(from value: [String: Any]) -> NPMProxyHost? {
        let id = int(value["id"])
        guard id > 0 else { return nil }
        return NPMProxyHost(id: id, domainNames: value["domain_names"] as? [String] ?? [], forwardHost: value["forward_host"] as? String ?? "", forwardPort: int(value["forward_port"]), certificateID: int(value["certificate_id"]))
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return Int(value as? String ?? "") ?? 0
    }

    private static func isPublicDomain(_ domain: String) -> Bool {
        let reserved = [".lan", ".local", ".localhost", ".internal", ".home", ".home.arpa", ".test", ".invalid", ".example", ".onion"]
        guard domain.count <= 253, domain.contains("."), !domain.contains("_"), !reserved.contains(where: domain.hasSuffix) else { return false }
        let labels = domain.split(separator: ".").map(String.init)
        guard let suffix = labels.last, suffix.count >= 2, Int(suffix) == nil else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.range(of: #"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, options: .regularExpression) != nil
        }
    }

    private static func mergedAdvancedConfig(_ existing: String?) -> String {
        let start = "# DOCKAMP MANAGED CONFIG START"
        let end = "# DOCKAMP MANAGED CONFIG END"
        let body = """
        proxy_ssl_server_name on;
        proxy_ssl_name $host;
        proxy_ssl_verify off;

        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        """
        let managed = "\(start)\n\(body)\n\(end)"
        var preserved = existing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let regex = try? NSRegularExpression(pattern: "(?s)\\Q\(start)\\E.*?\\Q\(end)\\E") {
            preserved = regex.stringByReplacingMatches(in: preserved, range: NSRange(preserved.startIndex..., in: preserved), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return preserved.isEmpty ? managed : "\(preserved)\n\n\(managed)"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
