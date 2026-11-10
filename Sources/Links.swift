import AppKit
import CryptoKit
import Darwin
import Foundation
import Security

@MainActor
final class ListeningLinks {
    private var current: (artist: String, title: String, started: Date)?
    private var scrobbled = false
    private var pendingToken = ""
    private let presence = DiscordPresence()

    func beginAuth(key: String, secret: String) async throws {
        try Self.saveSecret(secret, account: "lastfm-secret")
        let response = try await Self.call("auth.getToken", fields: [:], key: key, secret: secret)
        guard let token = response["token"] as? String else { throw DialError.invalidResponse }
        pendingToken = token
        NSWorkspace.shared.open(Catalog.url("https://www.last.fm/api/auth/", ["api_key": key, "token": token]))
    }

    func finishAuth(key: String) async throws -> String {
        guard !pendingToken.isEmpty, let secret = Self.secret("lastfm-secret") else { throw DialError.invalidResponse }
        let response = try await Self.call("auth.getSession", fields: ["token": pendingToken], key: key, secret: secret)
        guard let session = response["session"] as? [String: Any], let username = session["name"] as? String,
              let sessionKey = session["key"] as? String else { throw DialError.invalidResponse }
        try Self.saveSecret(sessionKey, account: "lastfm-session")
        pendingToken = ""
        return username
    }

    func disconnect() {
        SecItemDelete(Self.keychainQuery("lastfm-secret") as CFDictionary)
        SecItemDelete(Self.keychainQuery("lastfm-session") as CFDictionary)
        pendingToken = ""
    }

    func clearTrack() { current = nil }

    func trackChanged(_ value: String, prefs: Preferences) {
        let separator = value.contains(" – ") ? " – " : " - "
        guard let cut = value.range(of: separator) else { current = nil; return }
        current = (String(value[..<cut.lowerBound]), String(value[cut.upperBound...]), Date())
        scrobbled = false
        if let current { report("track.updateNowPlaying", current, prefs: prefs) }
    }

    func tick(prefs: Preferences) {
        guard prefs.lastFMEnabled, let current, !scrobbled, Date().timeIntervalSince(current.started) >= 60 else { return }
        scrobbled = true
        report("track.scrobble", current, prefs: prefs)
    }

    private func report(_ method: String, _ track: (artist: String, title: String, started: Date), prefs: Preferences) {
        guard prefs.lastFMEnabled, let secret = Self.secret("lastfm-secret"), let session = Self.secret("lastfm-session") else { return }
        Task {
            var fields = ["artist": track.artist, "track": track.title, "sk": session]
            if method == "track.scrobble" { fields["timestamp"] = String(Int(track.started.timeIntervalSince1970)) }
            _ = try? await Self.call(method, fields: fields, key: prefs.lastFMKey, secret: secret)
        }
    }

    private static func call(_ method: String, fields: [String: String], key: String, secret: String) async throws -> [String: Any] {
        var values = fields
        values["method"] = method
        values["api_key"] = key
        let base = values.sorted { $0.key < $1.key }.map { $0.key + $0.value }.joined() + secret
        values["api_sig"] = Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        values["format"] = "json"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = values.map { key, value in key + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, _) = try await Catalog.session.data(for: request)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DialError.invalidResponse }
        if response["error"] != nil {
            throw NSError(domain: "Last.fm", code: response["error"] as? Int ?? 1,
                          userInfo: [NSLocalizedDescriptionKey: response["message"] as? String ?? "Last.fm rejected the request."])
        }
        return response
    }

    private static func keychainQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Radio Dial", kSecAttrAccount as String: account]
    }

    private static func saveSecret(_ value: String, account: String) throws {
        let query = keychainQuery(account)
        let data = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, data as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(data) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func secret(_ account: String) -> String? {
        var query = keychainQuery(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func discord(client: String, title: String, detail: String) { presence.update(client, title: title, detail: detail) }
    func clearDiscord(client: String) { clearTrack(); presence.update(client, title: nil, detail: "") }
}

private final class DiscordPresence {
    private let queue = DispatchQueue(label: "RadioDial.discord")
    private var socket = Int32(-1)
    private var connectedClient = ""

    deinit { if socket >= 0 { Darwin.close(socket) } }

    func update(_ client: String, title: String?, detail: String) {
        queue.async {
            if client != self.connectedClient { self.disconnect() }
            guard client.count >= 16, client.allSatisfy(\.isASCII), UInt64(client) != nil else { return }
            if self.socket < 0 {
                guard title != nil, self.connect(client) else { return }
            }
            let activity: Any = title.map { ["details": String($0.prefix(128)),
                                            "state": String((detail.isEmpty ? "Internet radio" : detail).prefix(128))] } as Any? ?? NSNull()
            if !self.send(opcode: 1, ["cmd": "SET_ACTIVITY", "args": ["pid": getpid(), "activity": activity], "nonce": UUID().uuidString]) {
                self.disconnect()
            }
        }
    }

    private func disconnect() {
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
        connectedClient = ""
    }

    private func connect(_ client: String) -> Bool {
        let roots = [NSTemporaryDirectory(), "/tmp"]
        for root in roots {
            for index in 0..<10 {
                let path = URL(fileURLWithPath: root).appendingPathComponent("discord-ipc-\(index)").path
                var address = sockaddr_un()
                let encoded = Array(path.utf8CString)
                guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else { continue }
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { raw in
                    for (offset, byte) in encoded.enumerated() { raw[offset] = UInt8(bitPattern: byte) }
                }
                let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard descriptor >= 0 else { continue }
                var option: Int32 = 1
                setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &option, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                if result == 0 {
                    socket = descriptor
                    connectedClient = client
                    if send(opcode: 0, ["v": 1, "client_id": client]) { return true }
                    disconnect()
                } else { Darwin.close(descriptor) }
            }
        }
        return false
    }

    private func send(opcode: UInt32, _ payload: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var header = [opcode.littleEndian, UInt32(data.count).littleEndian]
        var frame = header.withUnsafeMutableBytes { Data($0) }
        frame.append(data)
        return frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var offset = 0
            while offset < raw.count {
                let length = Darwin.send(socket, base.advanced(by: offset), raw.count - offset, 0)
                guard length > 0 else { return false }
                offset += length
            }
            return true
        }
    }
}
