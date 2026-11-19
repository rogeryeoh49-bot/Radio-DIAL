import AppKit
import Carbon
import Combine
import SwiftUI


private final class VIRadioPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class VIRadioController: ObservableObject {
    static let shared = VIRadioController()
    @Published var stations: [Source] = []
    @Published var index = 0
    @Published var position = 0
    @Published var hintsVisible = false
    private var hintTimer: Timer?
    private var capsState = false
    let artwork = CoverFlowArtwork()
    private var libraryObserver: AnyCancellable?
    @Published var shortcutStatus = ""
    @Published var shortcutUnavailable = false
    weak var dial: DialState?
    private var panel: NSPanel?
    private var monitor: Any?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var configured: String?
    private var holdSession = false
    private var hotKeyDown = false
    private var scrollAmount = 0.0
    private var lastScroll = Date.distantPast
    var visible: Bool { panel?.isVisible == true }

    func configure(_ dial: DialState) {
        if self.dial !== dial {
            self.dial = dial
            libraryObserver = dial.$stations.combineLatest(dial.$source, dial.$art).sink { [weak self] _, _, _ in
                DispatchQueue.main.async { self?.warmArtwork() }
            }
        }
        warmArtwork()
        let shortcut = dial.prefs.viShortcut ?? VIShortcut()
        let enabled = dial.prefs.viEnabled ?? true
        let signature = "\(enabled):\(shortcut.keyCode):\(shortcut.modifiers)"
        guard signature != configured else { return }
        configured = signature
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            for item in menu.items where item.action == NSSelectorFromString("showVIRadio") {
                item.title = "Show GTA Radio Selector — " + shortcut.label
            }
        }
        dismiss(commit: false)
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if handler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let controller = Unmanaged<VIRadioController>.fromOpaque(context).takeUnretainedValue()
                    if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                        if !controller.hotKeyDown { controller.hotKeyDown = true; controller.invoke() }
                    } else {
                        controller.hotKeyDown = false
                        if controller.holdSession { controller.dismiss(commit: false) }
                    }
                    return noErr
                }
            }, 2, &events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        shortcutUnavailable = false
        guard enabled else { shortcutStatus = "Global shortcut is off. Open VI radio from View or Themes."; return }
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x56495244, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        shortcutUnavailable = result != noErr
        shortcutStatus = result == noErr ? "No Accessibility or Input Monitoring permission needed." : "This shortcut is unavailable. Choose another, or open VI radio from View or Themes."
    }

    func suspendShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        hotKeyDown = false
        configured = nil
    }
    func restoreShortcut() { if let dial { configure(dial) } }

    private func invoke() {
        if visible { dismiss(commit: false); return }
        show(holding: !(dial?.prefs.viToggleMode ?? false))
    }

    func show(holding: Bool = false) {
        guard let dial else { return }
        if visible { dismiss(commit: false); return }
        var seen = Set<String>()
        stations = (dial.prefs.favorites + (dial.source.map { [$0] } ?? []) + dial.stations)
            .filter { $0.isRadio && seen.insert($0.id).inserted }
        index = stations.firstIndex { $0.id == dial.source?.id } ?? 0
        position = index
        holdSession = holding
        warmArtwork()
        scrollAmount = 0
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let window = VIRadioPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "VI radio"
        window.identifier = NSUserInterfaceItemIdentifier("vi-radio-overlay")
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: VIRadioView(controller: self, dial: dial, artwork: artwork))
        hosting.focusRingType = .none
        window.contentView = hosting
        panel = window
        capsState = NSEvent.modifierFlags.contains(.capsLock)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.visible,
                  event.window === self.panel || (event.type == .flagsChanged && self.panel?.isKeyWindow == true) else { return event }
            self.activity()
            if event.type == .flagsChanged {
                if event.keyCode == 57 {
                    let state = event.modifierFlags.contains(.capsLock)
                    if state != self.capsState {
                        self.capsState = state
                        if self.matches(self.dial?.prefs.viPreviousKey ?? .previous, event: event) { self.move(-1) }
                        else if self.matches(self.dial?.prefs.viNextKey ?? .next, event: event) { self.move(1) }
                    }
                }
                return event
            }
            if event.type == .scrollWheel {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                if Date().timeIntervalSince(self.lastScroll) > 0.18 { self.scrollAmount = 0 }
                self.lastScroll = Date()
                self.scrollAmount += delta
                let threshold = event.hasPreciseScrollingDeltas ? 35.0 : 1.0
                if abs(self.scrollAmount) >= threshold {
                    self.move(self.scrollAmount > 0 ? -1 : 1)
                    self.scrollAmount = 0
                }
                return nil
            }
            guard event.type == .keyDown else { return event }
            if self.matches(self.dial?.prefs.viPreviousKey ?? .previous, event: event) { self.move(-1); return nil }
            if self.matches(self.dial?.prefs.viNextKey ?? .next, event: event) { self.move(1); return nil }
            switch event.keyCode {
            case 53: self.dismiss(commit: false)
            case 123, 126: self.move(-1)
            case 124, 125: self.move(1)
            case 48 where event.modifierFlags.contains(.shift): self.move(-1)
            case 36, 76, 49: self.dismiss(commit: true)
            default: break
            }
            return nil
        }
        window.makeKeyAndOrderFront(nil)
        activity()
    }

    private func matches(_ binding: VIShortcut, event: NSEvent) -> Bool {
        guard UInt32(event.keyCode) == binding.keyCode else { return false }
        let modifiers = VIShortcut.modifiers(from: event)
        if modifiers == binding.modifiers { return true }
        // Allow local navigation while the global invocation modifiers remain held.
        let invocation = (dial?.prefs.viShortcut ?? VIShortcut()).modifiers
        return holdSession && (modifiers & ~invocation) == (binding.modifiers & ~invocation)
    }
    func activity() {
        hintsVisible = false
        if let hintTimer { hintTimer.fireDate = Date().addingTimeInterval(8) }
        else {
            hintTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hintTimer = nil
                    if self.visible { self.hintsVisible = true }
                }
            }
        }
    }
    var keyHints: String {
        let previous = dial?.prefs.viPreviousKey ?? .previous
        let next = dial?.prefs.viNextKey ?? .next
        return "← / \(previous.label.uppercased())  PREVIOUS     •     → / \(next.label.uppercased())  NEXT     •     SPACE / RETURN  PLAY     •     ESC  CLOSE"
    }
    func move(_ amount: Int) {
        guard !stations.isEmpty else { return }
        activity()
        let previousIndex = index
        position += amount
        index = ((position % stations.count) + stations.count) % stations.count
        warmArtwork()
        if index != previousIndex {
            if dial?.prefs.viImmediatePlayback ?? true { playSelected() }
            dial?.audio.playSelectionTone()
            StationHaptics.selection(favorite: dial?.prefs.favorites.contains(where: { $0.id == stations[index].id }) == true)
        }
    }
    func choose(_ value: Int) {
        guard stations.indices.contains(value) else { return }
        var distance = value - index
        if distance > stations.count / 2 { distance -= stations.count }
        if distance < -stations.count / 2 { distance += stations.count }
        move(distance)
    }
    private func warmArtwork() {
        guard let dial else { return }
        var seen = Set<String>()
        let items = visible ? stations : (dial.prefs.favorites + (dial.source.map { [$0] } ?? []) + dial.stations)
            .filter { $0.isRadio && seen.insert($0.id).inserted }
        let center = visible ? index : (items.firstIndex { $0.id == dial.source?.id } ?? 0)
        guard !items.isEmpty else { return }
        // Warm the visible row and both off-screen edges first, including circular neighbors.
        var urls: [URL] = []
        if let art = dial.art { urls.append(art) }
        for distance in 0...items.count / 2 {
            for offset in distance == 0 ? [0] : [-distance, distance] {
                let neighbor = (center + offset + items.count) % items.count
                if let url = items[neighbor].artwork { urls.append(url) }
            }
        }
        var unique = Set<URL>()
        artwork.prefetch(urls.filter { unique.insert($0).inserted })
    }
    func click(_ value: Int) {
        choose(value)
        dismiss(commit: true)
    }
    func turnOff() {
        if let dial, dial.playback == .playing || dial.playback == .connecting {
            dial.togglePlayback()
        }
        dismiss(commit: false)
    }

    func dismiss(commit: Bool) {
        let selected = stations.indices.contains(index) ? stations[index] : nil
        holdSession = false
        hintTimer?.invalidate()
        hintTimer = nil
        hintsVisible = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        if commit, let selected { play(selected) }
    }
    private func playSelected() {
        guard stations.indices.contains(index) else { return }
        play(stations[index])
    }
    private func play(_ selected: Source) {
        guard let dial else { return }
        if selected.id != dial.source?.id { dial.tune(selected, tuningEffect: false) }
        else if dial.playback == .paused || dial.playback == .stopped { dial.togglePlayback() }
    }
    func shutdown() {
        dismiss(commit: false)
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        configured = nil
        libraryObserver?.cancel()
        libraryObserver = nil
        dial = nil
    }
}

private struct VIRadioView: View {
    @ObservedObject var controller: VIRadioController
    @ObservedObject var dial: DialState
    @ObservedObject var artwork: CoverFlowArtwork
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct Slot: Identifiable {
        let id: Int
        let offset: Int
        let index: Int
        let station: Source
    }
    private var slots: [Slot] {
        let count = controller.stations.count
        guard count > 0 else { return [] }
        return (-4...4).map { offset in
            let position = controller.position + offset
            let index = ((position % count) + count) % count
            return Slot(id: position, offset: offset, index: index, station: controller.stations[index])
        }
    }
    private var selected: Source? { controller.stations.indices.contains(controller.index) ? controller.stations[controller.index] : nil }
    var body: some View {
        GeometryReader { geometry in
            let size = min(140, max(42, (geometry.size.width - 360) / 5))
            ZStack(alignment: .top) {
                Color.black.opacity(0.76).ignoresSafeArea()
                    .onTapGesture { controller.dismiss(commit: false) }
                VStack(spacing: 18) {
                    HStack(spacing: 13) {
                        HStack(spacing: 12) {
                        Text("VI RADIO").font(.custom("BarlowCondensed-SemiBold", size: 25))
                            .fixedSize()
                        Button { controller.move(-1) } label: { Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)) }
                            .focusable(false).focusEffectDisabled()
                            .accessibilityLabel("Previous station")
                        }.frame(width: 130, alignment: .trailing)
                        ZStack {
                            ForEach(slots) { slot in
                                    let offset = slot.offset
                                    let index = slot.index
                                    let station = slot.station
                                    VILogo(station: station, image: artwork.image(for: station.artwork))
                                        .frame(width: size, height: size)
                                        .overlay { Rectangle().stroke(.white.opacity(offset == 0 ? 1 : 0.12), lineWidth: offset == 0 ? 3 : 1) }
                                        .scaleEffect(offset == 0 ? 1.055 : 0.97)
                                        .brightness(offset == 0 ? 0 : -0.16)
                                        .offset(x: CGFloat(offset) * (size + 15))
                                        .transition(.identity)
                                        .onTapGesture { controller.click(index) }
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel(station.title)
                                        .accessibilityAddTraits(offset == 0 ? [.isButton, .isSelected] : .isButton)
                                        .accessibilityAction { controller.click(index) }
                            }
                        }.frame(width: 5 * size + 60, height: size + 10)
                            .clipped()
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: controller.position)
                        HStack(spacing: 12) {
                        Button { controller.move(1) } label: { Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold)) }
                            .focusable(false).focusEffectDisabled()
                            .accessibilityLabel("Next station")
                        Button { controller.turnOff() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle.fill")
                                Text("TURN OFF")
                            }.fixedSize()
                        }
                        .font(.custom("BarlowCondensed-SemiBold", size: 19))
                        .focusable(false).focusEffectDisabled()
                        }.frame(width: 130, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .center)
                    if let selected {
                        GeometryReader { bar in
                            Rectangle().fill(.white.opacity(0.24))
                            Rectangle().fill(.white).frame(width: 12)
                                .offset(x: (bar.size.width - 12) * CGFloat(controller.index) / CGFloat(max(1, controller.stations.count - 1)))
                        }.frame(width: 220, height: 4)
                        VStack(spacing: 5) {
                            Text(selected.title.uppercased()).font(.custom("BarlowCondensed-SemiBold", size: 30).weight(.bold))
                                .overlay(alignment: .leading) {
                                    if dial.prefs.favorites.contains(where: { $0.id == selected.id }) {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundStyle(Color(rgb: 0xF7C76A))
                                            .frame(width: 18)
                                            .offset(x: -28)
                                            .accessibilityLabel("Favorite station")
                                    }
                                }
                                .overlay(alignment: .trailing) {
                                    if selected.id == dial.source?.id, dial.playback == .connecting {
                                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                                            .tint(.white)
                                            .frame(width: 18, height: 18)
                                            .offset(x: 28)
                                            .accessibilityLabel("Loading station")
                                    }
                                }
                            if selected.id == dial.source?.id, !dial.track.isEmpty {
                                let song = TrackDisplayInfo.parse(dial.track, matchedTitle: dial.matchedSong?.title, matchedArtist: dial.matchedSong?.artist)
                                Text(song.title.uppercased())
                                    .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                    .foregroundStyle(.white)
                                if !song.artist.isEmpty {
                                    Text(song.artist.uppercased())
                                        .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                        .foregroundStyle(.white)
                                }
                            } else {
                                Text("LIVE RADIO")
                                    .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }.lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 650)
                    } else {
                        Text("ADD A STATION TO GET STARTED").font(.custom("BarlowCondensed-SemiBold", size: 26))
                    }
                    Text(controller.keyHints)
                        .font(.custom("BarlowCondensed-SemiBold", size: 14)).foregroundStyle(.white.opacity(0.55))
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                        .opacity(controller.hintsVisible ? 1 : 0)
                        .accessibilityHidden(!controller.hintsVisible)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.hintsVisible)
                }
                .padding(.top, max(38, geometry.size.height * 0.055))
                .frame(maxWidth: .infinity)
            }
            .foregroundStyle(.white).buttonStyle(VIPlainButtonStyle())
            .focusEffectDisabled()
        }
    }
}

private struct VILogo: View {
    let station: Source
    let image: CGImage?
    private var color: Color {
        let hash = station.id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.28, brightness: 0.23)
    }
    var body: some View {
        ZStack {
            color
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                Text(station.title.uppercased()).font(.custom("BarlowCondensed-SemiBold", size: 23)).multilineTextAlignment(.center).padding(10)
            }
        }.clipped()
    }
}

struct VIShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: VIShortcut
    var navigation = false
    var applicationShortcut = false
    @MainActor static var isRecording = false
    func makeNSView(context: Context) -> Recorder {
        let view = Recorder(); view.navigation = navigation; view.applicationShortcut = applicationShortcut; view.value = shortcut
        view.change = { shortcut = $0 }; return view
    }
    func updateNSView(_ view: Recorder, context: Context) {
        view.value = shortcut
        if !view.recording { view.title = shortcut.label }
        view.navigation = navigation
        view.applicationShortcut = applicationShortcut
        view.change = { shortcut = $0 }
    }
    final class Recorder: NSButton {
        var change: ((VIShortcut) -> Void)?
        var navigation = false
        var applicationShortcut = false
        var value = VIShortcut()
        var recording = false
        private var capsState = false
        override var acceptsFirstResponder: Bool { true }
        override init(frame: NSRect) { super.init(frame: frame); bezelStyle = .rounded; target = self; action = #selector(begin) }
        required init?(coder: NSCoder) { fatalError() }
        @objc private func begin() {
            VIRadioController.shared.suspendShortcut()
            recording = true; VIShortcutRecorder.isRecording = true
            capsState = NSEvent.modifierFlags.contains(.capsLock)
            title = navigation ? "Press a key…" : "Press a shortcut…"; window?.makeFirstResponder(self)
        }
        private func finish(_ key: VIShortcut? = nil) {
            recording = false; VIShortcutRecorder.isRecording = false
            if let key { change?(key) }
            title = (key ?? value).label
            VIRadioController.shared.restoreShortcut()
        }
        override func resignFirstResponder() -> Bool {
            if recording { finish() }
            return super.resignFirstResponder()
        }
        override func flagsChanged(with event: NSEvent) {
            guard recording, navigation, event.keyCode == 57 else { super.flagsChanged(with: event); return }
            let state = event.modifierFlags.contains(.capsLock)
            if state != capsState { finish(.capsLock) }
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { finish(); return }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let modifiers = VIShortcut.modifiers(from: event)
            let chars = event.charactersIgnoringModifiers ?? ""
            let isCharacter = chars.count == 1 && chars.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
            if applicationShortcut {
                guard isCharacter || [36, 48, 49, 50, 47, 123, 124, 125, 126].contains(event.keyCode) else { NSSound.beep(); return }
            } else if navigation {
                // Fixed confirmation, cancellation and arrow keys remain available.
                guard isCharacter || [48, 50].contains(event.keyCode),
                      ![36, 49, 76].contains(event.keyCode) else { NSSound.beep(); return }
            } else {
                guard !flags.intersection([.command, .option, .control]).isEmpty, isCharacter,
                      !(flags.contains(.command) && flags.intersection([.option, .control]).isEmpty) else { NSSound.beep(); return }
            }
            let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 50: "`", 47: ".", 123: "←", 124: "→", 125: "↓", 126: "↑"]
            let key = names[event.keyCode] ?? chars.uppercased()
            let label = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
            finish(VIShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label))
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if recording { keyDown(with: event); return true }
            return super.performKeyEquivalent(with: event)
        }
    }
}

struct VIRadioSettings: View {
    @ObservedObject var dial: DialState
    @ObservedObject private var controller = VIRadioController.shared
    @State private var keyError = ""
    private func saveNavigation(_ key: VIShortcut, previous: Bool) {
        let other = previous ? (dial.prefs.viNextKey ?? .next) : (dial.prefs.viPreviousKey ?? .previous)
        guard !key.sameKey(as: other), !key.sameKey(as: dial.prefs.viShortcut ?? VIShortcut()),
              !(key.keyCode == 48 && key.modifiers == UInt32(shiftKey)) else {
            keyError = "That key is already in use. Choose another key."
            return
        }
        keyError = ""
        if previous { dial.prefs.viPreviousKey = key } else { dial.prefs.viNextKey = key }
    }
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Enable global shortcut", isOn: Binding(get: { dial.prefs.viEnabled ?? true }, set: { dial.prefs.viEnabled = $0 }))
            HStack {
                Text("Shortcut")
                VIShortcutRecorder(shortcut: Binding(get: { dial.prefs.viShortcut ?? VIShortcut() }, set: { key in
                    if key.sameKey(as: dial.prefs.viPreviousKey ?? .previous) || key.sameKey(as: dial.prefs.viNextKey ?? .next) || AppShortcutAction.allCases.contains(where: { key.sameKey(as: $0.binding(in: dial.prefs.shortcuts)) }) {
                        keyError = "That key is already assigned to navigation."
                    } else { keyError = ""; dial.prefs.viShortcut = key }
                })).frame(width: 145, height: 28)
                Button("Reset") { dial.prefs.viShortcut = nil; keyError = "" }
                    .accessibilityLabel("Reset opening shortcut")
            }
            Picker("Behavior", selection: Binding(get: { dial.prefs.viToggleMode ?? false }, set: { dial.prefs.viToggleMode = $0 })) {
                Text("Hold shortcut to show selector").tag(false)
                Text("Press once to open, again to close").tag(true)
            }
            Picker("Station switching", selection: Binding(get: { dial.prefs.viImmediatePlayback ?? true }, set: { dial.prefs.viImmediatePlayback = $0 })) {
                Text("Play immediately when selected").tag(true)
                Text("Play after Space, Return or click").tag(false)
            }
            HStack {
                Text("Previous station").frame(width: 115, alignment: .leading)
                VIShortcutRecorder(shortcut: Binding(get: { dial.prefs.viPreviousKey ?? .previous }, set: { saveNavigation($0, previous: true) }), navigation: true).frame(width: 145, height: 28)
                Button("Reset") { dial.prefs.viPreviousKey = nil; keyError = "" }
                    .accessibilityLabel("Reset previous station key")
            }
            HStack {
                Text("Next station").frame(width: 115, alignment: .leading)
                VIShortcutRecorder(shortcut: Binding(get: { dial.prefs.viNextKey ?? .next }, set: { saveNavigation($0, previous: false) }), navigation: true).frame(width: 145, height: 28)
                Button("Reset") { dial.prefs.viNextKey = nil; keyError = "" }
                    .accessibilityLabel("Reset next station key")
            }
            if !keyError.isEmpty { Text(keyError).font(.caption).foregroundStyle(.orange) }
            Divider()
            Text("Click a shortcut to change it.\nArrows / Shift-Tab: browse · Space / Return: play\nEscape: close · Turn Off: pause and close")
                .font(.caption).foregroundStyle(.secondary)
            if (dial.prefs.viPreviousKey ?? .previous).keyCode == 57 || (dial.prefs.viNextKey ?? .next).keyCode == 57 {
                Text("Caps Lock retains its macOS keyboard behavior.").font(.caption).foregroundStyle(.secondary)
            }
            if controller.shortcutUnavailable {
                Text("Shortcut unavailable. Choose another combination.").font(.caption).foregroundStyle(.orange)
            }
            Button("Open VI radio") {
                dial.pane = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { controller.show() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }
}

private struct VIPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1)
            .focusable(false)
            .focusEffectDisabled()
    }
}
