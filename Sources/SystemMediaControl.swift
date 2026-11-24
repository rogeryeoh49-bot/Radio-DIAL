import Foundation
import Darwin

/// Optional private MediaRemote compatibility adapter. Missing/restricted symbols fail closed.
enum SystemMediaControl {
    private typealias PIDCallback = @convention(block) (Int32) -> Void
    private typealias PIDQuery = @convention(c) (DispatchQueue, @escaping PIDCallback) -> Void
    private typealias Command = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)

    static func externalPlayerPID() async -> Int32? {
        guard let library, let symbol = dlsym(library, "MRMediaRemoteGetNowPlayingApplicationPID") else { return nil }
        let query = unsafeBitCast(symbol, to: PIDQuery.self)
        return await withCheckedContinuation { continuation in
            let result = MediaResultOnce<Int32?>(continuation)
            query(.main) { pid in result.finish(pid > 0 && pid != getpid() ? pid : nil) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { result.finish(nil) }
        }
    }
    static func pauseExternalPlayer() async -> Bool {
        guard let pid = await externalPlayerPID() else { return false }
        return await send(1, expectedPID: pid)
    }
    static func resumeExternalPlayer(pid: Int32) async -> Bool {
        // Clearing Radio Dial's Now Playing session may take a moment to reveal the prior owner.
        for _ in 0..<8 {
            guard !Task.isCancelled else { return false }
            if await externalPlayerPID() == pid { return await send(0, expectedPID: pid) }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }
    private static func send(_ code: Int32, expectedPID: Int32) async -> Bool {
        guard !Task.isCancelled, let library,
              let querySymbol = dlsym(library, "MRMediaRemoteGetNowPlayingApplicationPID"),
              let commandSymbol = dlsym(library, "MRMediaRemoteSendCommand") else { return false }
        let query = unsafeBitCast(querySymbol, to: PIDQuery.self)
        let command = unsafeBitCast(commandSymbol, to: Command.self)
        return await withCheckedContinuation { continuation in
            let result = MediaResultOnce<Bool>(continuation)
            query(.main) { pid in
                result.resolve { pid == expectedPID && pid != getpid() ? command(code, nil) : false }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { result.finish(false) }
        }
    }
}
private final class MediaResultOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) { resolve { value } }
    func resolve(_ action: () -> Value) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        if let pending { pending.resume(returning: action()) }
    }
}
