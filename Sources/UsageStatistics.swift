import Foundation

@MainActor
final class UsageStatistics {
    private struct Report: Codable {
        let installationID: UUID
        let appVersion: String
    }

    private struct State: Codable {
        let installationID: UUID
        var reported = false
    }

    private typealias Send = (URLRequest) async throws -> Int

    private let stateURL: URL
    private let version: String?
    private let destination: () -> (URL, Send)?
    private var request: Task<Void, Never>?
    private var activity: Task<Void, Never>?
    private var reported = false

    convenience init(storage: URL, bundle: Bundle = .main) {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let endpoint = Self.configuredEndpoint(in: bundle) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForResource = 15
            let session = URLSession(configuration: configuration, delegate: NoUsageRedirects(), delegateQueue: nil)
            self.init(storage: storage, endpoint: endpoint, version: version) { request in
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            }
        } else {
            self.init(localStorage: storage, version: version)
        }
    }

    convenience init(localStorage storage: URL, version: String?) {
        self.init(stateURL: storage.appendingPathComponent("usage-statistics-local.json"), version: version) {
            let file = LocalUsageDashboard.connectionFile(in: storage)
            guard let data = try? Data(contentsOf: file),
                  let connection = try? JSONDecoder().decode(LocalUsageDashboard.self, from: data),
                  let endpoint = connection.baseURL?.appendingPathComponent("v1/playback"),
                  let session = connection.session() else { return nil }
            return (endpoint, { request in
                defer { session.finishTasksAndInvalidate() }
                let (_, response) = try await session.data(for: request)
                return (response as? HTTPURLResponse)?.statusCode ?? 0
            })
        }
    }

    convenience init(storage: URL, endpoint: URL?, version: String?, send: @escaping (URLRequest) async throws -> Int) {
        self.init(stateURL: storage.appendingPathComponent("usage-statistics.json"), version: version) {
            endpoint.flatMap { Self.secureEndpoint($0.absoluteString) }.map { ($0, send) }
        }
    }

    private init(stateURL: URL, version: String?, destination: @escaping () -> (URL, Send)?) {
        self.stateURL = stateURL
        self.version = version
        self.destination = destination
    }

    static func configuredEndpoint(in bundle: Bundle) -> URL? {
        #if DEBUG
        return nil
        #else
        return secureEndpoint(bundle.object(forInfoDictionaryKey: "RadioDialUsageStatisticsURL") as? String)
        #endif
    }

    private static func secureEndpoint(_ address: String?) -> URL? {
        guard let address, let url = URL(string: address), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    func setActivitySharing(_ enabled: Bool) {
        activity?.cancel()
        activity = nil
        guard enabled else {
            request?.cancel()
            return
        }
        activity = Task { [weak self] in
            var launchAcknowledged = false
            while !Task.isCancelled {
                let acknowledged = await self?.sendActivity(launch: !launchAcknowledged) ?? false
                if acknowledged { launchAcknowledged = true }
                do {
                    try await Task.sleep(for: .seconds(acknowledged ? 60 : 10))
                } catch { return }
            }
        }
    }

    func cancel() { setActivitySharing(false) }

    private func sendActivity(launch: Bool) async -> Bool {
        guard !Task.isCancelled, let version, !version.isEmpty,
              let (playbackURL, send) = destination() else { return false }
        do {
            let state = try installationState()
            let path = launch ? "open" : "presence"
            let url = playbackURL.deletingLastPathComponent().appendingPathComponent(path)
            let submission = try makeRequest(url: url, state: state, version: version)
            try Task.checkCancellation()
            return try await send(submission) == 204
        } catch { return false }
    }

    func playbackSucceeded(sharingEnabled: Bool) {
        guard sharingEnabled, !reported, request == nil, let version, !version.isEmpty else { return }
        do {
            if let current = try storedState(), current.reported {
                reported = true
                return
            }
            guard let (endpoint, send) = destination() else { return }
            var state = try installationState()
            let submission = try makeRequest(url: endpoint, state: state, version: version)
            request = Task { [weak self, send] in
                defer { self?.request = nil }
                do {
                    try Task.checkCancellation()
                    let status = try await send(submission)
                    try Task.checkCancellation()
                    guard status == 204 else { return }
                    state.reported = true
                    try self?.save(state)
                    self?.reported = true
                } catch {
                    // Wait for another successful playback before retrying.
                }
            }
        } catch {
            // Keep playback independent of usage statistics, including local storage errors.
        }
    }

    private func makeRequest(url: URL, state: State, version: String) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RadioDIAL", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Report(installationID: state.installationID, appVersion: version))
        return request
    }

    private func storedState() throws -> State? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
    }

    private func installationState() throws -> State {
        if let state = try storedState() { return state }
        let state = State(installationID: UUID())
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try save(state)
        return state
    }

    private func save(_ state: State) throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}

private final class NoUsageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
