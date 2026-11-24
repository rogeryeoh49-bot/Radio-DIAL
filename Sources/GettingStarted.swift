import AppKit
import CoreServices
import SwiftUI

enum GettingStartedStep {
    case stations, themes, coverFlow, viRadio, selfRadio

    var number: Int {
        switch self {
        case .stations: 1
        case .themes, .coverFlow: 2
        case .viRadio: 3
        case .selfRadio: 4
        }
    }
}

struct GettingStarted: View {
    @ObservedObject var selfRadio: SelfRadioState
    let musicApp: SelfRadioMusicApp
    let prepareAudio: () -> Void
    let start: () -> Void
    let skip: () -> Void
    @State private var audioCheck: Task<Void, Never>?
    @State private var audioCheckPassed = false
    @State private var automationAllowed = false
    @State private var automationCheck: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "radio")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(tutorialAccent)
                .accessibilityHidden(true)
            Text("Welcome to Radio Dial")
                .font(.system(size: 30, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Take a quick tour of the app in four steps.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 9) {
                Text("Optional permissions for Self Radio").font(.subheadline.weight(.semibold))
                permission("System Audio Recording", detail: "Detect audio from other apps.", pane: "Privacy_AudioCapture",
                           verified: selfRadio.audioAccessVerified || audioCheckPassed, checking: audioCheck != nil, check: checkAudio)
                permission("Automation", detail: "Control \(musicApp.name) and read song info.", pane: "Privacy_Automation",
                           verified: automationAllowed, checking: automationCheck != nil, check: checkAutomation)
                Text("Allow access when macOS asks as you use Self Radio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Skip", action: skip).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Tour", action: start)
                    .buttonStyle(.borderedProminent)
                    .tint(tutorialAccent)
                    .foregroundStyle(.black)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .background {
            LinearGradient(colors: [Color(rgb: 0x2A211C), Color(rgb: 0x151518)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        .environment(\.colorScheme, .dark)
        .task { await refreshAutomation() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAutomation() }
        }
        .onDisappear {
            audioCheck?.cancel()
            automationCheck?.cancel()
        }
    }

    private func permission(_ title: String, detail: String, pane: String, verified: Bool,
                            checking: Bool, check: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if verified {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("\(title) verified")
            } else {
                Button(checking ? "Checking…" : "Check", action: check)
                    .disabled(checking)
                    .accessibilityLabel("Check \(title) access")
                Link("Open Settings", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                    .accessibilityLabel("Open \(title) settings")
            }
        }
    }

    private func checkAudio() {
        prepareAudio()
        audioCheck = Task {
            let verified = await SystemAudioDetector.verifyAccess()
            if !Task.isCancelled { audioCheckPassed = verified; audioCheck = nil }
        }
    }

    private func refreshAutomation() async {
        guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: musicApp.rawValue).first else {
            return
        }
        automationAllowed = await automationPermission(for: application.processIdentifier)
    }

    private func checkAutomation() {
        automationCheck = Task {
            defer { automationCheck = nil }
            let bundle = musicApp.rawValue
            var running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            if running == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                running = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            }
            guard let running else { return }
            let deadline = ContinuousClock.now + .seconds(5)
            while !running.isFinishedLaunching, !running.isTerminated, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled, !running.isTerminated else { return }
            automationAllowed = await automationPermission(for: running.processIdentifier)
        }
    }

    private func automationPermission(for pid: pid_t) async -> Bool {
        await Task.detached(priority: .utility) {
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            guard let descriptor = target.aeDesc else { return false }
            return AEDeterminePermissionToAutomateTarget(descriptor, kAECoreSuite, kAEGetData, false) == noErr
        }.value
    }
}

struct GettingStartedHint: View {
    let step: GettingStartedStep
    let text: String
    let advance: () -> Void
    var skip: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text("\(step.number)/4")
                .monospacedDigit()
                .accessibilityLabel("Step \(step.number) of 4")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(step == .selfRadio ? "Done" : "Next", action: advance)
                .buttonStyle(.borderedProminent)
                .tint(tutorialAccent)
                .foregroundStyle(.black)
            if let skip {
                Button(action: skip) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("End tutorial")
                    .accessibilityLabel("End tutorial")
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(9)
        .background(tutorialAccent.opacity(0.14), in: .rect(cornerRadius: 8))
        .gettingStartedHighlight(true)
    }
}

extension View {
    func gettingStartedHighlight(_ active: Bool) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(tutorialAccent, lineWidth: 1.5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

private let tutorialAccent = Color(rgb: 0xF5BD76)
