import Foundation

@main
enum UsageStatisticsTests {
    @MainActor
    static func main() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let endpoint = URL(string: "https://stats.example.test/v1/playback")!
        let stateURL = storage.appendingPathComponent("usage-statistics.json")

        let bundleURL = storage.appendingPathComponent("Configured.bundle")
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: String] = ["CFBundleIdentifier": "test.radiodial.usage",
                                      "RadioDialUsageStatisticsURL": endpoint.absoluteString]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: infoURL)
        let bundle = Bundle(url: bundleURL)!
        #if DEBUG
        precondition(UsageStatistics.configuredEndpoint(in: bundle) == nil)
        #else
        precondition(UsageStatistics.configuredEndpoint(in: bundle) == endpoint)
        #endif

        let transport = TestTransport()
        let stats = UsageStatistics(storage: storage, endpoint: endpoint, version: "2.2.1", send: transport.send)
        stats.playbackSucceeded(sharingEnabled: false)
        await Task.yield()
        precondition(transport.requests.isEmpty && !FileManager.default.fileExists(atPath: stateURL.path))

        let insecure = UsageStatistics(storage: storage, endpoint: URL(string: "http://localhost/playback"),
                                       version: "2.2.1", send: transport.send)
        insecure.playbackSucceeded(sharingEnabled: true)
        await Task.yield()
        precondition(transport.requests.isEmpty)

        stats.playbackSucceeded(sharingEnabled: true)
        stats.playbackSucceeded(sharingEnabled: true)
        await waitUntil { transport.requests.count == 1 }
        precondition(transport.requests[0].url == endpoint && transport.requests[0].httpMethod == "POST")
        let body = try payload(transport.requests[0].httpBody!)
        precondition(body.keys.sorted() == ["appVersion", "installationID"] && body["appVersion"] == "2.2.1")
        precondition(UUID(uuidString: body["installationID"]!) != nil)

        transport.finish(.failure(URLError(.notConnectedToInternet)))
        try await Task.sleep(for: .milliseconds(30))
        precondition(transport.requests.count == 1)
        stats.playbackSucceeded(sharingEnabled: true)
        await waitUntil { transport.requests.count == 2 }
        let retry1 = try payload(transport.requests[1].httpBody!)
        precondition(body == retry1)

        stats.cancel()
        transport.finish(.success(204))
        try await Task.sleep(for: .milliseconds(30))
        stats.playbackSucceeded(sharingEnabled: false)
        precondition(transport.requests.count == 2)

        let relaunched = UsageStatistics(storage: storage, endpoint: endpoint, version: "2.2.1", send: transport.send)
        relaunched.playbackSucceeded(sharingEnabled: true)
        await waitUntil { transport.requests.count == 3 }
        let retry2 = try payload(transport.requests[2].httpBody!)
        precondition(body == retry2)
        transport.finish(.success(204))
        try await Task.sleep(for: .milliseconds(30))
        relaunched.playbackSucceeded(sharingEnabled: true)
        let afterSuccess = UsageStatistics(storage: storage, endpoint: endpoint, version: "2.2.2", send: transport.send)
        afterSuccess.playbackSucceeded(sharingEnabled: true)
        await Task.yield()
        precondition(transport.requests.count == 3)

        let activityTransport = TestTransport()
        let activity = UsageStatistics(storage: storage, endpoint: endpoint, version: "2.2.1", send: activityTransport.send)
        activity.setActivitySharing(false)
        await Task.yield()
        precondition(activityTransport.requests.isEmpty)
        activity.setActivitySharing(true)
        await waitUntil { activityTransport.requests.count == 1 }
        let launch = activityTransport.requests[0]
        precondition(launch.url?.path == "/v1/open" && launch.httpMethod == "POST")
        let activityBody = try payload(launch.httpBody!)
        precondition(activityBody == body)
        activity.setActivitySharing(false)
        activityTransport.finish(.success(204))
        await Task.yield()
        print("Usage statistics tests passed.")
    }

    static func payload(_ data: Data) throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: data)
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Expected report was not submitted")
    }
}

@MainActor
private final class TestTransport {
    var requests: [URLRequest] = []
    private var continuation: CheckedContinuation<Int, Error>?

    func send(_ request: URLRequest) async throws -> Int {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func finish(_ result: Result<Int, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
