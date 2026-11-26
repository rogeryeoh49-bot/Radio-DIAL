import Foundation
import Security

struct LocalUsageDashboard: Codable {
    let port: Int
    let certificate: Data

    static func connectionFile(in storage: URL) -> URL {
        storage.appendingPathComponent("User Dashboard/connection.json")
    }

    var baseURL: URL? {
        guard (1...65535).contains(port) else { return nil }
        return URL(string: "https://127.0.0.1:\(port)")
    }

    func session() -> URLSession? {
        guard let baseURL,
              let certificate = SecCertificateCreateWithData(nil, certificate as CFData) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0,
        ]
        return URLSession(configuration: configuration,
                          delegate: LocalDashboardTLS(host: baseURL.host!, port: port, certificate: certificate),
                          delegateQueue: nil)
    }
}

private final class LocalDashboardTLS: NSObject, URLSessionTaskDelegate {
    let host: String
    let port: Int
    let certificate: SecCertificate

    init(host: String, port: Int, certificate: SecCertificate) {
        self.host = host
        self.port = port
        self.certificate = certificate
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard space.host == host, space.port == port, let trust = space.serverTrust,
              let peer = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyData(peer) == SecCertificateCopyData(certificate),
              SecTrustSetAnchorCertificates(trust, [certificate] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
