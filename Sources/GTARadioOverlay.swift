import AppKit
import Carbon
import Combine
import SwiftUI


private final class VIRadioPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private enum VIRadioGuideStep: Int {
    case browse = 1, confirm, close

    var title: String {
        switch self {
        case .browse: "Browse stations"
        case .confirm: "Confirm a station"
        case .close: "Close VI Radio"
        }
    }

    var instruction: String {
        switch self {
        case .browse: "Press ← or →, scroll, or click a highlighted arrow."
        case .confirm: "Press Space or Return, or click the station you want to play."
        case .close: "Click Turn Off. In normal use, this also pauses playback."
        }
    }
}

@MainActor final class VIRadioController: ObservableObject {
    static let shared = VIRadioController()
    @Published var stations: [Source] = []
    @Published var index = 0
    @Published var position = 0
    @Published var hintsVisible = false
    @Published var foregroundVisible = false
    @Published fileprivate private(set) var guideStep: VIRadioGuideStep?
    @Published fileprivate private(set) var awaitingGuideShortcut = false
    private var guideCompletion: (() -> Void)?
    var onTutorialShortcut: (() -> Void)?
    private var isClosing = false
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
        (panel?.contentView as? VIRadioBackdrop)?.update(
            strength: dial.prefs.viBackgroundStrength ?? VIRadioBackdrop.defaultStrength,
            darkness: dial.prefs.viBackgroundDarkness ?? VIRadioBackdrop.defaultDarkness)
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
        dismiss(commit: false, animated: false)
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
        if dial?.gettingStartedStep == .viRadio, let onTutorialShortcut {
            onTutorialShortcut()
            return
        }
        if visible && !isClosing { dismiss(commit: false); return }
        show(holding: !(dial?.prefs.viToggleMode ?? false))
    }

    func show(holding: Bool = false, waitForShortcut: Bool = false, guideCompletion: (() -> Void)? = nil) {
        guard let dial else { return }
        if isClosing, let old = panel { finishClosing(old) }
        if visible { dismiss(commit: false); return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        self.guideCompletion = guideCompletion
        guideStep = guideCompletion == nil ? nil : .browse
        awaitingGuideShortcut = guideCompletion != nil && waitForShortcut
        foregroundVisible = false
        stations = dial.carouselStations
        index = stations.firstIndex { $0.id == dial.source?.id } ?? 0
        position = index
        holdSession = holding
        warmArtwork()
        scrollAmount = 0
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
        window.contentView = VIRadioBackdrop(foreground: hosting, frame: NSRect(origin: .zero, size: screen.frame.size),
            strength: dial.prefs.viBackgroundStrength ?? VIRadioBackdrop.defaultStrength,
            darkness: dial.prefs.viBackgroundDarkness ?? VIRadioBackdrop.defaultDarkness)
        window.alphaValue = 0
        panel = window
        capsState = NSEvent.modifierFlags.contains(.capsLock)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.visible,
                  event.window === self.panel || (event.type == .flagsChanged && self.panel?.isKeyWindow == true) else { return event }
            if self.isClosing { return nil }
            if self.awaitingGuideShortcut {
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.dismiss(commit: false) }
                    let binding = self.dial?.prefs.viShortcut ?? VIShortcut()
                    if self.dial?.prefs.viEnabled != false, self.matches(binding, event: event) {
                        self.beginTutorialPractice()
                    }
                    return nil
                }
                return event
            }
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
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.panel === window, !self.isClosing else { return }
            self.foregroundVisible = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 1
            }
        }
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
        guard guideStep == nil else { return }
        let idleDelay: TimeInterval = 5
        hintsVisible = false
        if let hintTimer { hintTimer.fireDate = Date().addingTimeInterval(idleDelay) }
        else {
            hintTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hintTimer = nil
                    if self.visible { self.hintsVisible = true }
                }
            }
        }
    }
    func beginTutorialPractice() {
        awaitingGuideShortcut = false
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
        if let guideStep {
            if guideStep == .browse, amount != 0 { self.guideStep = .confirm }
            return
        }
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
        let items = visible ? stations : dial.carouselStations
        let center = visible ? index : (items.firstIndex { $0.id == dial.source?.id } ?? 0)
        guard !items.isEmpty else { return }
        // Warm the visible row and both off-screen edges first, including circular neighbors.
        var urls: [URL] = []
        for distance in 0...items.count / 2 {
            for offset in distance == 0 ? [0] : [-distance, distance] {
                let neighbor = (center + offset + items.count) % items.count
                if let url = items[neighbor].stationArtwork { urls.append(url) }
            }
        }
        var unique = Set<URL>()
        artwork.prefetch(urls.filter { unique.insert($0).inserted })
    }
    func click(_ value: Int) {
        let step = guideStep
        choose(value)
        if step == .browse { return }
        dismiss(commit: true)
    }
    func turnOff() {
        if guideStep == nil, let dial, dial.playback == .playing || dial.playback == .connecting {
            dial.togglePlayback()
        }
        dismiss(commit: false)
    }

    func dismiss(commit: Bool, animated: Bool = true) {
        guard !isClosing else {
            if !animated, let window = panel { finishClosing(window) }
            return
        }
        if commit, let guideStep {
            if guideStep == .confirm { self.guideStep = .close }
            return
        }
        let selected = stations.indices.contains(index) ? stations[index] : nil
        holdSession = false
        hintTimer?.invalidate()
        hintTimer = nil
        hintsVisible = false
        foregroundVisible = false
        if let window = panel {
            isClosing = true
            // Release mouse input immediately; keyboard events are swallowed only during the fade.
            window.ignoresMouseEvents = true
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    window.animator().alphaValue = 0
                } completionHandler: { [weak self, weak window] in
                    Task { @MainActor in
                        guard let self, let window, self.panel === window else { return }
                        self.finishClosing(window)
                    }
                }
            } else { finishClosing(window) }
        }
        if commit, let selected { play(selected) }
    }

    private func finishClosing(_ window: NSPanel) {
        guard panel === window else { return }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        panel = nil
        isClosing = false
        guideStep = nil
        awaitingGuideShortcut = false
        let onGuideClose = guideCompletion
        guideCompletion = nil
        onGuideClose?()
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
        guideCompletion = nil
        dismiss(commit: false, animated: false)
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
    private let guideAccent = Color(rgb: 0xF5BD76)
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
                Color.clear.ignoresSafeArea().contentShape(Rectangle())
                    .onTapGesture { controller.dismiss(commit: false) }
                if controller.awaitingGuideShortcut {
                    shortcutPrompt
                        .opacity(controller.foregroundVisible ? 1 : 0)
                } else {
                VStack(spacing: 18) {
                    HStack(spacing: 13) {
                        HStack(spacing: 12) {
                        Text("VI RADIO").font(.custom("BarlowCondensed-SemiBold", size: 25))
                            .viOutlined(width: viTitleOutlineWidth)
                            .fixedSize()
                        Button { controller.move(-1) } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .viOutlined(width: 0.85)
                        }
                            .focusable(false).focusEffectDisabled()
                            .accessibilityLabel("Previous station")
                            .overlay { guideHighlight(.browse) }
                        }.frame(width: 130, alignment: .trailing)
                        ZStack {
                            ForEach(slots) { slot in
                                    let offset = slot.offset
                                    let index = slot.index
                                    let station = slot.station
                                    let logo = station.isSelfRadio ? Source.selfRadio.stationArtwork : station.stationArtwork
                                    VILogo(station: station, image: artwork.image(for: logo))
                                        .frame(width: size, height: size)
                                        .overlay { Rectangle().stroke(.white.opacity(offset == 0 ? 1 : 0.12), lineWidth: offset == 0 ? 3 : 1) }
                                        .overlay {
                                            if offset == 0, controller.guideStep == .confirm {
                                                Rectangle().strokeBorder(guideAccent, lineWidth: 4).allowsHitTesting(false)
                                            }
                                        }
                                        .scaleEffect(offset == 0 ? 1.055 : 0.97)
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
                        Button { controller.move(1) } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .viOutlined(width: 0.85)
                        }
                            .focusable(false).focusEffectDisabled()
                            .accessibilityLabel("Next station")
                            .overlay { guideHighlight(.browse) }
                        Button { controller.turnOff() } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(.white)
                                    .overlay { Circle().strokeBorder(.black, lineWidth: 1.75) }
                                    .overlay {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 11, weight: .black))
                                            .foregroundStyle(.black)
                                    }
                                    .frame(width: 25, height: 25)
                                    .accessibilityHidden(true)
                                Text("TURN OFF").viOutlined()
                            }.fixedSize()
                        }
                        .font(.custom("BarlowCondensed-SemiBold", size: 19))
                        .focusable(false).focusEffectDisabled()
                        .overlay { guideHighlight(.close) }
                        }.frame(width: 130, alignment: .leading)
                    }.frame(maxWidth: .infinity, alignment: .center)
                    if let selected {
                        HStack(spacing: 8) {
                            keycap(dial.prefs.viPreviousKey ?? .previous)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                            GeometryReader { bar in
                                Rectangle().fill(.white.opacity(0.24))
                                Rectangle().fill(.white).frame(width: 12)
                                    .overlay { Rectangle().stroke(.black, lineWidth: 0.9) }
                                    .offset(x: (bar.size.width - 12) * CGFloat(controller.index) / CGFloat(max(1, controller.stations.count - 1)))
                            }.frame(width: 220, height: 4)
                            keycap(dial.prefs.viNextKey ?? .next)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        VStack(spacing: 3) {
                            Text(selected.title.uppercased()).font(.custom("BarlowCondensed-SemiBold", size: 30).weight(.bold))
                                .viOutlined(width: 1.8)
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
                            let detail = selected.isSelfRadio ? dial.selfRadio.displayDetail
                                : selected.id == dial.source?.id ? dial.track : ""
                            if !detail.isEmpty {
                                let song = TrackDisplayInfo.parse(detail,
                                    matchedTitle: selected.isSelfRadio ? dial.selfRadio.track?.title : dial.matchedSong?.title,
                                    matchedArtist: selected.isSelfRadio ? dial.selfRadio.track?.artist : dial.matchedSong?.artist)
                                VStack(spacing: 0) {
                                    Text(song.title.uppercased())
                                        .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                        .viOutlined()
                                    if !song.artist.isEmpty {
                                        Text(song.artist.uppercased())
                                            .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                            .viOutlined()
                                    }
                                }
                            } else if !selected.isSelfRadio {
                                Text("LIVE RADIO")
                                    .font(.custom("BarlowCondensed-SemiBold", size: 21))
                                    .viOutlined(foreground: .white.opacity(0.85))
                            }
                            if selected.isSelfRadio, !dial.selfRadio.active || dial.selfRadio.muted || detail.isEmpty {
                                let status = dial.selfRadio.active ? dial.selfRadio.displayStatus : "Not Playing"
                                Text(status.uppercased())
                                    .font(.custom("BarlowCondensed-SemiBold", size: detail.isEmpty ? 21 : 14))
                                    .viOutlined(foreground: .white.opacity(0.85))
                            }
                        }.lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 650)
                    } else {
                        Text("ADD A STATION TO GET STARTED").font(.custom("BarlowCondensed-SemiBold", size: 26))
                            .viOutlined()
                    }
                    if let guideStep = controller.guideStep {
                        guide(guideStep)
                    } else {
                        Text(controller.keyHints)
                            .font(.custom("BarlowCondensed-SemiBold", size: 14))
                            .foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center).padding(.horizontal, 30)
                            .opacity(controller.hintsVisible ? 1 : 0)
                            .accessibilityHidden(!controller.hintsVisible)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.hintsVisible)
                    }
                }
                .padding(.top, max(38, geometry.size.height * 0.055))
                .frame(maxWidth: .infinity)
                .opacity(controller.foregroundVisible ? 1 : 0)
                .scaleEffect(reduceMotion || controller.foregroundVisible ? 1 : 0.985, anchor: .top)
                .animation(.easeOut(duration: 0.22), value: controller.foregroundVisible)
                }
            }
            .foregroundStyle(.white).buttonStyle(VIPlainButtonStyle())
            .focusEffectDisabled()
        }
    }

    private var shortcutPrompt: some View {
        let binding = dial.prefs.viShortcut ?? VIShortcut()
        let hasShortcut = dial.prefs.viEnabled != false
        let key = binding.sameKey(as: VIShortcut()) ? "⌥ Q" : binding.label
        return VStack(spacing: 14) {
            Text(hasShortcut ? key : "VI Radio")
                .font(.system(size: 78, weight: .semibold, design: .rounded))
                .accessibilityLabel(hasShortcut && binding.sameKey(as: VIShortcut()) ? "Option Q" : key)
            Text(hasShortcut ? "Press to open VI Radio" : "Open VI Radio to continue")
                .font(.system(size: 23, weight: .medium))
            HStack(spacing: 18) {
                Button("Skip practice") { controller.dismiss(commit: false) }
                    .foregroundStyle(.white.opacity(0.72))
                Button("Open VI Radio") { controller.beginTutorialPractice() }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.white.opacity(0.14), in: Capsule())
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.64))
    }

    @ViewBuilder private func guideHighlight(_ step: VIRadioGuideStep) -> some View {
        if controller.guideStep == step {
            Capsule().strokeBorder(guideAccent, lineWidth: 1.5)
                .padding(-6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func guide(_ step: VIRadioGuideStep) -> some View {
        VStack(spacing: 6) {
            Text("3/4 · VI Radio · Practice \(step.rawValue)/3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(guideAccent)
            Text(step.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(step.instruction)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
                .multilineTextAlignment(.center)
            if step == .browse {
                let shortcut = (dial.prefs.viShortcut ?? VIShortcut()).label
                Text(dial.prefs.viEnabled == false
                     ? "Open it again from the View menu."
                     : "\(dial.prefs.viToggleMode == true ? "Press" : "Hold") \(shortcut) to open VI Radio anytime.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.76))
            }
            Button("Exit Practice") { controller.dismiss(commit: false) }
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(guideAccent.opacity(0.55)) }
    }

    private func keycap(_ shortcut: VIShortcut) -> some View {
        Group {
            if shortcut.sameKey(as: .next) {
                Path { path in
                    path.move(to: CGPoint(x: 1, y: 5))
                    path.addLine(to: CGPoint(x: 11, y: 5))
                    path.move(to: CGPoint(x: 7, y: 1))
                    path.addLine(to: CGPoint(x: 11, y: 5))
                    path.addLine(to: CGPoint(x: 7, y: 9))
                    path.move(to: CGPoint(x: 12, y: 1))
                    path.addLine(to: CGPoint(x: 12, y: 9))
                }
                .stroke(.black, style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
                .frame(width: 13, height: 10)
            } else {
                Text(shortcut.label)
                    .font(.system(size: 10, weight: .bold))
            }
        }
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 16)
            .background(.white, in: Capsule())
            .overlay { Capsule().strokeBorder(.black, lineWidth: 1.5) }
            .accessibilityHidden(true)
    }
}

private let viTitleOutlineWidth: CGFloat = 1.25

private extension View {
    func viOutlined(width: CGFloat = 1.55, foreground: Color = .white) -> some View {
        self.foregroundStyle(foreground)
            .background {
                ZStack {
                    ForEach(0..<8) { direction in
                        let angle = CGFloat(direction) * .pi / 4
                        self.foregroundStyle(.black)
                            .offset(x: width * cos(angle), y: width * sin(angle))
                    }
                }
                .accessibilityHidden(true)
                .allowsHitTesting(false)
            }
    }
}

private struct VILogo: View {
    let station: Source
    let image: CGImage?
    private var placeholderColor: Color {
        let hash = station.id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.28, brightness: 0.23)
    }
    var body: some View {
        ZStack {
            if let image {
                StationArtworkBacking(edges: StationArtworkEdgeColors.forLandscapeImage(image))
                Image(decorative: image, scale: 1)
                    .allowedDynamicRange(.standard)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderColor
                Text(station.title.uppercased())
                    .font(.custom("BarlowCondensed-SemiBold", size: 23))
                    .multilineTextAlignment(.center)
                    .padding(10)
            }
        }
        .clipped()
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
            Text("Background").font(.headline)
            HStack {
                Text("Blur strength").frame(width: 115, alignment: .leading)
                Slider(value: Binding(get: { dial.prefs.viBackgroundStrength ?? VIRadioBackdrop.defaultStrength },
                                      set: { dial.prefs.viBackgroundStrength = $0 }), in: 0...1)
                    .accessibilityLabel("Background blur strength")
                Text((dial.prefs.viBackgroundStrength ?? VIRadioBackdrop.defaultStrength).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 42, alignment: .trailing)
            }
            HStack {
                Text("Darkness").frame(width: 115, alignment: .leading)
                Slider(value: Binding(get: { dial.prefs.viBackgroundDarkness ?? VIRadioBackdrop.defaultDarkness },
                                      set: { dial.prefs.viBackgroundDarkness = $0 }), in: 0...0.8)
                    .accessibilityLabel("Background darkness")
                Text((dial.prefs.viBackgroundDarkness ?? VIRadioBackdrop.defaultDarkness).formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 42, alignment: .trailing)
            }
            VIRadioBackdropPreview(strength: dial.prefs.viBackgroundStrength ?? VIRadioBackdrop.defaultStrength,
                                   darkness: dial.prefs.viBackgroundDarkness ?? VIRadioBackdrop.defaultDarkness)
                .frame(height: 80).clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Live background preview")
            Button("Reset background") {
                dial.prefs.viBackgroundStrength = nil
                dial.prefs.viBackgroundDarkness = nil
            }
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
                controller.show()
            }
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
