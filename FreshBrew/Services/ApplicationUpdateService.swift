import Foundation

protocol ApplicationUpdateChecking: Sendable {
    func check() async throws -> ApplicationUpdateCheckResult
}

protocol ApplicationUpdateHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

actor URLSessionApplicationUpdateHTTPClient: ApplicationUpdateHTTPClient {
    private let session: URLSession

    init(requestTimeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ApplicationUpdateError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum ApplicationUpdateError: LocalizedError, Equatable {
    case invalidInstalledVersion
    case invalidResponse
    case invalidRelease
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .invalidInstalledVersion:
            return "The installed FreshBrew version could not be read."
        case .invalidResponse, .invalidRelease:
            return "GitHub returned an invalid release response."
        case .requestFailed:
            return "The update check could not be completed."
        }
    }
}

struct GitHubApplicationUpdateService: ApplicationUpdateChecking {
    static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/siannsin/FreshBrew/releases/latest"
    )!

    private struct ReleaseResponse: Decodable {
        let tagName: String
        let pageURL: URL
        let publishedAt: Date?
        let isDraft: Bool
        let isPrerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
            case publishedAt = "published_at"
            case isDraft = "draft"
            case isPrerelease = "prerelease"
        }
    }

    private let installedVersion: String
    private let httpClient: any ApplicationUpdateHTTPClient

    init(
        installedVersion: String,
        httpClient: any ApplicationUpdateHTTPClient = URLSessionApplicationUpdateHTTPClient()
    ) {
        self.installedVersion = installedVersion
        self.httpClient = httpClient
    }

    func check() async throws -> ApplicationUpdateCheckResult {
        guard let currentVersion = SemanticVersion(installedVersion) else {
            throw ApplicationUpdateError.invalidInstalledVersion
        }

        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("FreshBrew", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await httpClient.data(for: request)
        guard response.statusCode == 200 else {
            throw ApplicationUpdateError.requestFailed(statusCode: response.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release: ReleaseResponse
        do {
            release = try decoder.decode(ReleaseResponse.self, from: data)
        } catch {
            throw ApplicationUpdateError.invalidResponse
        }

        guard !release.isDraft,
              !release.isPrerelease,
              let releaseVersion = SemanticVersion(release.tagName),
              Self.isValidReleasePageURL(release.pageURL) else {
            throw ApplicationUpdateError.invalidRelease
        }

        guard releaseVersion > currentVersion else {
            return .current
        }

        return .updateAvailable(ApplicationRelease(
            version: releaseVersion,
            pageURL: release.pageURL,
            publishedAt: release.publishedAt
        ))
    }

    nonisolated static func isValidReleasePageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com" else {
            return false
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 5 else { return false }
        return components[0].lowercased() == "siannsin"
            && components[1].lowercased() == "freshbrew"
            && components[2].lowercased() == "releases"
            && components[3].lowercased() == "tag"
            && !components[4].isEmpty
    }
}
