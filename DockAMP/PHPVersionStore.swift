import Foundation
import Combine

@MainActor
final class PHPVersionStore: ObservableObject {
    static let shared = PHPVersionStore()

    @Published private(set) var availableVersions: [String] = PHPVersionCatalog.fallbackVersions
    @Published private(set) var isLoading = false
    @Published private(set) var lastErrorMessage: String?

    private var lastRefreshDate: Date?

    private init() {}

    func refreshIfNeeded(force: Bool = false) async {
        if !force, let lastRefreshDate, Date().timeIntervalSince(lastRefreshDate) < 3600 {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let versions = try await fetchAvailableVersions()
            if !versions.isEmpty {
                availableVersions = versions
            } else {
                availableVersions = PHPVersionCatalog.fallbackVersions
            }
            lastErrorMessage = nil
            lastRefreshDate = Date()
        } catch {
            availableVersions = PHPVersionCatalog.fallbackVersions
            lastErrorMessage = error.localizedDescription
        }
    }

    private func fetchAvailableVersions() async throws -> [String] {
        var allTags: [String] = []
        var nextURL: URL? = URL(string: "https://registry.hub.docker.com/v2/repositories/library/php/tags?page_size=100")
        var visitedURLs = Set<String>()

        while let url = nextURL {
            let urlString = url.absoluteString
            guard !visitedURLs.contains(urlString) else { break }
            visitedURLs.insert(urlString)

            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let payload = try JSONDecoder().decode(DockerHubTagsResponse.self, from: data)
            allTags.append(contentsOf: payload.results.map(\.name))

            if let next = payload.next, let parsed = URL(string: next) {
                nextURL = parsed
            } else {
                nextURL = nil
            }
        }

        return PHPVersionCatalog.extractVersions(from: allTags)
    }
}

enum PHPVersionCatalog {
    static let fallbackVersions: [String] = ["8.5", "8.4", "8.3", "8.2", "8.1", "8.0", "7.4"]
    static let defaultVersion = fallbackVersions[0]

    static func extractVersions(from tags: [String]) -> [String] {
        let pattern = #"^(\d+)\.(\d+)(?:\.\d+)?-fpm$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let nsRangeFactory = { (value: String) in NSRange(value.startIndex..<value.endIndex, in: value) }

        let versions = tags.compactMap { tag -> String? in
            guard let regex else { return nil }
            let range = nsRangeFactory(tag)
            guard let match = regex.firstMatch(in: tag, range: range), match.numberOfRanges >= 3 else {
                return nil
            }

            guard
                let majorRange = Range(match.range(at: 1), in: tag),
                let minorRange = Range(match.range(at: 2), in: tag)
            else {
                return nil
            }

            return "\(tag[majorRange]).\(tag[minorRange])"
        }

        let unique = Array(Set(versions))
        let sorted = unique.sorted { lhs, rhs in
            let left = lhs.split(separator: ".").compactMap { Int($0) }
            let right = rhs.split(separator: ".").compactMap { Int($0) }
            let leftMajor = left.indices.contains(0) ? left[0] : 0
            let leftMinor = left.indices.contains(1) ? left[1] : 0
            let rightMajor = right.indices.contains(0) ? right[0] : 0
            let rightMinor = right.indices.contains(1) ? right[1] : 0

            if leftMajor == rightMajor {
                return leftMinor > rightMinor
            }
            return leftMajor > rightMajor
        }

        return sorted
    }
}

private struct DockerHubTagsResponse: Decodable {
    let next: String?
    let results: [DockerHubTag]
}

private struct DockerHubTag: Decodable {
    let name: String
}
