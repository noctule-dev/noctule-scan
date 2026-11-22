// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing

@testable import NoctuleAppCore

@Suite(.timeLimit(.minutes(1))) struct ReleaseFeedTests {
    private static let goodPage = "https://github.com/noctule-dev/noctule-scan/releases/tag/v1.0.1"

    private func body(
        tag: String = "v1.0.1", prerelease: Bool = false, draft: Bool = false,
        notes: String? = "Fixes.", page: String = goodPage
    ) -> Data {
        let notesJSON = notes.map { "\"\($0)\"" } ?? "null"
        return Data(
            """
            {"tag_name":"\(tag)","prerelease":\(prerelease),"draft":\(draft),"body":\(notesJSON),"html_url":"\(page)"}
            """.utf8)
    }

    @Test func decodesAStableRelease() throws {
        let result = ReleaseFeed.decode(status: 200, body: body())
        let release = try result.get()
        #expect(release.version == AppVersion("1.0.1"))
        #expect(release.notes == "Fixes.")
        #expect(release.page == URL(string: Self.goodPage))
        #expect(try ReleaseFeed.decode(status: 200, body: body(notes: nil)).get().notes == "")
    }

    @Test func refusesWhatIsNotAStableRelease() {
        #expect(ReleaseFeed.decode(status: 200, body: body(prerelease: true)) == .failure(.unreadable("pre-release")))
        #expect(ReleaseFeed.decode(status: 200, body: body(draft: true)) == .failure(.unreadable("draft")))
        guard case .failure(.unreadable(let detail)) = ReleaseFeed.decode(status: 200, body: body(tag: "nightly"))
        else {
            Issue.record("expected unreadable")
            return
        }
        #expect(detail.contains("tag"))
    }

    @Test(arguments: [
        "http://github.com/noctule-dev/noctule-scan/releases/x",
        "https://github.com.evil.example/noctule-dev/noctule-scan/releases/x",
        "https://github.com/someone-else/noctule-scan/releases/x",
        "https://github.com/noctule-dev/noctule-scan/issues/1",
    ]) func refusesAPageOffTheRepository(page: String) {
        guard case .failure(.unreadable(let detail)) = ReleaseFeed.decode(status: 200, body: body(page: page))
        else {
            Issue.record("expected unreadable for \(page)")
            return
        }
        #expect(detail.contains("page"))
    }

    @Test func mapsStatuses() {
        #expect(ReleaseFeed.decode(status: 404, body: Data()) == .failure(.noRelease))
        #expect(ReleaseFeed.decode(status: 403, body: Data()) == .failure(.rateLimited))
        #expect(ReleaseFeed.decode(status: 429, body: Data()) == .failure(.rateLimited))
        #expect(ReleaseFeed.decode(status: 500, body: Data()) == .failure(.unreadable("status 500")))
        guard case .failure(.unreadable) = ReleaseFeed.decode(status: 200, body: Data("not json".utf8))
        else {
            Issue.record("expected unreadable")
            return
        }
    }

    @Test func mapsNetworkErrors() {
        let error = URLError(.notConnectedToInternet)
        #expect(ReleaseFeed.failure(for: error) == .network(error.localizedDescription))
        guard case .network = ReleaseFeed.failure(for: CancellationError()) else {
            Issue.record("expected network")
            return
        }
    }

    @Test func fileFeedReadsTheFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("latest.json")
        let bytes = body()
        try bytes.write(to: file)
        let fetcher = URLSessionReleaseFetcher(userAgent: "test")
        let found = try await fetcher.fetch(file)
        #expect(found.status == 200)
        #expect(found.body == bytes)
        let missing = try await fetcher.fetch(dir.appendingPathComponent("absent.json"))
        #expect(missing.status == 404)
    }

    @Test func requestCarriesTheHeaders() {
        let request = URLSessionReleaseFetcher.request(
            for: ReleaseFeed.gitHubLatest, userAgent: "Noctule Scan/1.0", timeout: .seconds(15))
        #expect(request.url?.absoluteString == "https://api.github.com/repos/noctule-dev/noctule-scan/releases/latest")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Noctule Scan/1.0")
        #expect(request.timeoutInterval == 15)
    }
}
