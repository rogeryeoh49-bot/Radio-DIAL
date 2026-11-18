import AppKit
import CryptoKit
import Foundation

struct ReleaseVersion: Comparable {
    let components: [Int]
    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        components = parts.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let a = index < lhs.components.count ? lhs.components[index] : 0
            let b = index < rhs.components.count ? rhs.components[index] : 0
            if a != b { return a < b }
        }
        return false
    }
    static func == (lhs: Self, rhs: Self) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

@MainActor final class UpdateController {
    private struct Release: Decodable {
        struct Asset: Decodable { var name: String }
        var tag_name: String
        var html_url: URL
        var body: String?
        var draft, prerelease: Bool
        var assets: [Asset]
    }
    private let repo = "https://github.com/rogeryeoh49-bot/Radio-DIAL"
    private let api = URL(string: "https://api.github.com/repos/rogeryeoh49-bot/Radio-DIAL/releases/latest")!
    private let ignoredKey = "RadioDial.ignoredUpdateVersion"
    private var checking = false
    private var timer: Timer?

    func start() {
        Task { try? await Task.sleep(for: .seconds(5)); await check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(manual: false) }
        }
    }

    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue("Radio-Dial-Updater", forHTTPHeaderField: "User-Agent")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw UpdateError.failed("GitHub did not return a release.") }
            let release = try JSONDecoder().decode(Release.self, from: data)
            guard !release.draft, !release.prerelease, let latest = ReleaseVersion(release.tag_name),
                  let current = ReleaseVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") else { throw UpdateError.failed("The release version could not be read.") }
            guard latest > current else {
                if manual { show("You’re up to date", "Radio Dial \(currentText) is the latest available version.") }
                return
            }
            if !manual && UserDefaults.standard.string(forKey: ignoredKey) == release.tag_name { return }
            let names = Set(release.assets.map(\.name))
            guard names.contains("Radio-Dial-macOS.zip"), names.contains("Radio-Dial-macOS.zip.sha256") else {
                if manual { show("Update unavailable", "The latest release does not have an installable Mac package yet.") }
                return
            }
            let alert = NSAlert()
            alert.messageText = "Radio Dial \(release.tag_name) is available"
            alert.informativeText = "You have version \(currentText). Download and install the new version? Radio Dial will restart after installation."
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Later")
            alert.addButton(withTitle: "Skip This Version")
            let result = alert.runModal()
            if result == .alertThirdButtonReturn { UserDefaults.standard.set(release.tag_name, forKey: ignoredKey) }
            else if result == .alertFirstButtonReturn { await install(release) }
        } catch {
            if manual { show("Couldn’t check for updates", error.localizedDescription) }
        }
    }

    private var currentText: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown" }

    private func install(_ release: Release) async {
        let target = Bundle.main.bundleURL.standardizedFileURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path),
              !target.path.contains("/build/") else {
            show("Can’t update this copy", "Install Radio Dial in your Applications folder, then try again. You can also download the update from GitHub.")
            return
        }
        let stage = parent.appendingPathComponent(".RadioDialUpdate-" + UUID().uuidString, isDirectory: true)
        let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 105),
                               styleMask: [.titled], backing: .buffered, defer: false)
        progress.title = "Updating Radio Dial"
        let label = NSTextField(labelWithString: "Downloading and verifying the update…")
        label.frame = NSRect(x: 52, y: 42, width: 295, height: 22)
        let spinner = NSProgressIndicator(frame: NSRect(x: 19, y: 39, width: 20, height: 20))
        spinner.style = .spinning
        progress.contentView?.addSubview(label)
        progress.contentView?.addSubview(spinner)
        spinner.startAnimation(nil)
        progress.center()
        progress.makeKeyAndOrderFront(nil)
        defer { progress.orderOut(nil) }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let base = repo + "/releases/download/" + release.tag_name + "/"
            guard let zipURL = URL(string: base + "Radio-Dial-macOS.zip"),
                  let hashURL = URL(string: base + "Radio-Dial-macOS.zip.sha256") else { throw UpdateError.failed("Invalid release URL.") }
            async let zipResponse = URLSession.shared.data(from: zipURL)
            async let hashResponse = URLSession.shared.data(from: hashURL)
            let ((zip, zResponse), (hashData, hResponse)) = try await (zipResponse, hashResponse)
            guard let zHTTP = zResponse as? HTTPURLResponse, (200..<300).contains(zHTTP.statusCode),
                  let hHTTP = hResponse as? HTTPURLResponse, (200..<300).contains(hHTTP.statusCode),
                  zip.count <= 150_000_000,
                  let checksum = String(data: hashData, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).first,
                  checksum.count == 64 else { throw UpdateError.failed("The update download was incomplete.") }
            let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
            guard actual == checksum.lowercased() else { throw UpdateError.failed("The update checksum did not match.") }
            let archive = stage.appendingPathComponent("update.zip")
            try zip.write(to: archive, options: .atomic)
            let paths = try run("/usr/bin/unzip", ["-Z1", archive.path])
            guard paths.split(separator: "\n").allSatisfy({ line in
                let path = String(line)
                return !path.hasPrefix("/") && !path.split(separator: "/").contains("..") && (path == "Radio Dial.app" || path.hasPrefix("Radio Dial.app/") || path == "__MACOSX" || path.hasPrefix("__MACOSX/"))
            }) else { throw UpdateError.failed("The update archive has unexpected paths.") }
            _ = try run("/usr/bin/ditto", ["-x", "-k", archive.path, stage.path])
            let candidate = stage.appendingPathComponent("Radio Dial.app")
            guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "org.radiodial.macos",
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  ReleaseVersion(version) == ReleaseVersion(release.tag_name),
                  FileManager.default.isExecutableFile(atPath: candidate.appendingPathComponent("Contents/MacOS/Radio Dial").path) else { throw UpdateError.failed("The update is not the expected Radio Dial version.") }
            _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path])
            let helper = stage.appendingPathComponent("install.sh")
            let script = """
            #!/bin/bash
            set -eu
            pid="$1"; target="$2"; candidate="$3"; stage="$4"
            for attempt in {1..120}; do
                kill -0 "$pid" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$pid" 2>/dev/null; then exit 1; fi
            backup="${target}.update-backup-$$"
            mv "$target" "$backup" || exit 1
            if mv "$candidate" "$target"; then
                rm -rf "$backup"
                open "$target"
                rm -rf "$stage"
            else
                mv "$backup" "$target"
                open "$target"
                exit 1
            fi
            """
            try script.write(to: helper, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), target.path, candidate.path, stage.path]
            try process.run()
            // Leave the Swift concurrency job before AppKit waits for asynchronous recording cleanup.
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
                NSApp.terminate(nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: stage)
            show("Couldn’t install the update", error.localizedDescription)
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.failed("Update verification failed.") }
        return String(decoding: data, as: UTF8.self)
    }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "OK"); alert.runModal()
    }
    private enum UpdateError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
    }
}
