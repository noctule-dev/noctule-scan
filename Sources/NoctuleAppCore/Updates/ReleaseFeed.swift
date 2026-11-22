// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// The newest stable release, as the feed describes it.
public struct LatestRelease: Equatable, Sendable {
    public let version: AppVersion
    public let notes: String
    public let page: URL

    public init(version: AppVersion, notes: String, page: URL) {
        self.version = version
        self.notes = notes
        self.page = page
    }
}

/// Why an update check found nothing.
public enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// The system's localized message.
    case network(String)
    /// The feed answered 404: no release exists.
    case noRelease
    /// The feed answered 403 or 429.
    case rateLimited
    /// Anything else; the text is a short log detail ("status 500", "draft", "tag nightly", "page http://…").
    case unreadable(String)
    /// A private `NOCTULE_SETTINGS_DIR` with no test feed: nothing is fetched.
    case disabledForTesting
}

/// Fetches one URL and returns its status and body. Tests supply fakes.
public protocol ReleaseFetching: Sendable {
    func fetch(_ url: URL) async throws -> (status: Int, body: Data)
}

/// Fetches over HTTPS with an ephemeral session (no cookies, no cache). A `file:` URL is read
/// from disk (a missing file answers 404), which is how tests and a test feed avoid the network.
public struct URLSessionReleaseFetcher: ReleaseFetching {
    private let userAgent: String
    private let timeout: Duration

    public init(userAgent: String, timeout: Duration = .seconds(15)) {
        self.userAgent = userAgent
        self.timeout = timeout
    }

    public static func request(for url: URL, userAgent: String, timeout: Duration) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = seconds(timeout)
        return request
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    public func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
        if url.isFileURL {
            guard let data = try? Data(contentsOf: url) else { return (404, Data()) }
            return (200, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        // The request's own timeout is an idle timeout; these cap the whole request.
        let limit = Self.seconds(timeout)
        configuration.timeoutIntervalForRequest = limit
        configuration.timeoutIntervalForResource = limit
        // Just after a wake or a login the network may not be up yet: wait for it, within the limit.
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let request = Self.request(for: url, userAgent: userAgent, timeout: timeout)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }
}

public enum ReleaseFeed {
    public static let gitHubLatest = URL(
        string: "https://api.github.com/repos/noctule-dev/noctule-scan/releases/latest")!
    public static let pagePrefix = "https://github.com/noctule-dev/noctule-scan/releases/"

    private struct Payload: Decodable {
        let tag_name: String
        let prerelease: Bool
        let draft: Bool
        let body: String?
        let html_url: String
    }

    public static func decode(status: Int, body: Data) -> Result<LatestRelease, UpdateCheckFailure> {
        switch status {
        case 200: break
        case 404: return .failure(.noRelease)
        case 403, 429: return .failure(.rateLimited)
        default: return .failure(.unreadable("status \(status)"))
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return .failure(.unreadable("not a release"))
        }
        if payload.draft { return .failure(.unreadable("draft")) }
        if payload.prerelease { return .failure(.unreadable("pre-release")) }
        guard let version = AppVersion(payload.tag_name) else {
            return .failure(.unreadable("tag \(payload.tag_name)"))
        }
        guard let page = URL(string: payload.html_url), page.scheme == "https", page.host == "github.com",
            page.absoluteString.hasPrefix(pagePrefix),
            !page.pathComponents.contains(where: { $0 == "." || $0 == ".." })
        else { return .failure(.unreadable("page \(payload.html_url)")) }
        return .success(LatestRelease(version: version, notes: payload.body ?? "", page: page))
    }

    /// A thrown error as a failure; a cancellation too, so nothing is thrown on.
    public static func failure(for error: any Error) -> UpdateCheckFailure {
        .network(error.localizedDescription)
    }
}
