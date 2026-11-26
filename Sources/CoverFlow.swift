import AppKit
import SwiftUI

struct CoverFlow<Country: View, Library: View, Options: View>: View {
    @ObservedObject var dial: DialState
    @ObservedObject var artwork: CoverFlowArtwork
    @StateObject private var frequencyLookup = CoverFrequency()
    let country: Country
    let library: Library
    let options: Options
    let keyboardEnabled: Bool
    let supportsHDR: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewID: String?
    @State private var scrollPosition: Double?
    @State private var settleTask: Task<Void, Never>?
    @State private var keyHoldTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var centeringStationID: String?
    @State private var entryStrength: Double?
    @State private var pauseAppearance = 0.0
    @State private var playbackPresence = 0.0
    @State private var settledFocus = false
    @State private var stationNameHovered = false
    @State private var songCoverHovered = false
    @State private var songLinkHovered = false
    @State private var songHoverTask: Task<Void, Never>?
    @State private var highlightedCover: (source: CGImage, image: CGImage)?

    private var stations: [Source] { dial.carouselStations }

    var body: some View {
        let items = stations
        let restingIndex = items.firstIndex { $0.id == (previewID ?? dial.source?.id) } ?? 0
        let position = min(Double(max(0, items.count - 1)), scrollPosition ?? Double(restingIndex))
        let index = Int(position.rounded())
        let station = items.indices.contains(index) ? items[index] : nil
        let playingIndex = items.firstIndex { $0.id == dial.source?.id }
        let active = playingIndex != nil && dial.playback != .stopped
        let focused = active && scrollPosition == nil && previewID == nil
        let paused = active && dial.playback == .paused
        let artworkFocus = playbackFocus(at: position, playingIndex: playingIndex) * playbackPresence
        let focus = artworkFocus * (1 - 0.65 * pauseAppearance)
        let playIconOpacity = focused && (dial.playback == .playing || paused) ? pauseAppearance : 1
        let dwellStation = focused && dial.playback == .playing && centeringStationID == nil && keyboardEnabled ? dial.source?.id : nil
        let dwellAmount = settledFocus ? 1.0 : 0.0
        let playingArtwork = active ? dial.art : nil
        let selfRadioArtwork = dial.selfRadio.artwork
        let trackDetail = station?.isSelfRadio == true ? dial.selfRadio.displayDetail : dial.track
        let playingLogoURL = dial.source?.stationArtwork
        let playingAlbum = playingArtwork != playingLogoURL ? artwork.image(for: playingArtwork) : nil
        let highlightSource = supportsHDR && active
            ? playingAlbum ?? artwork.image(for: playingLogoURL).map { CoverFlowArtwork.stationFace(for: $0).image } : nil
        let highlight = highlightedCover.flatMap { $0.source === highlightSource ? $0.image : nil }

        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Text("Cover Flow").font(.custom("Punctum-Regular", size: 25))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                country
                library
                options
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 29)
            .padding(.vertical, 20)

            GeometryReader { geometry in
                if station != nil {
                    let size = min(260, max(1, (geometry.size.height - 64) / 1.45), geometry.size.width * 0.29)
                    // Keep extra cards laid out past both clipping edges.
                    let radius = Int(ceil(geometry.size.width / (2 * max(1, size) * 0.245))) + 1
                    let first = max(0, index - radius)
                    let last = min(items.count - 1, index + radius)
                    ZStack {
                        ForEach(Array(items[first...last].enumerated()), id: \.element.id) { entry in
                            let item = entry.element
                            let distance = Double(first + entry.offset) - position
                            let isCenter = first + entry.offset == index
                            let turn = min(abs(distance), 1)
                            let isPlaying = first + entry.offset == playingIndex
                            ZStack(alignment: .bottom) {
                            Button {
                                activate(item, from: position)
                            } label: {
                                FlowCover(fallbackTitle: item.isUSRadio ? item.title : nil, image: artwork.image(for: item.stationArtwork),
                                          album: item.isSelfRadio ? artwork.image(for: selfRadioArtwork)
                                            : isPlaying && playingArtwork != item.stationArtwork ? artwork.image(for: playingArtwork) : nil,
                                          albumOpacity: item.isSelfRadio ? 1 : isPlaying ? artworkFocus : 0,
                                          highlight: isPlaying ? highlight : nil,
                                          highlightOpacity: isPlaying && (dial.playback == .playing || paused) ? artworkFocus * (1 - pauseAppearance) : 0,
                                          dimming: (0.075 + 0.125 * focus) * turn,
                                          size: size)
                                    .anchorPreference(key: CoverTopKey.self, value: .bounds) { isCenter ? $0 : nil }
                                    .contentShape(Rectangle())
                                    .overlay(alignment: .top) {
                                        if dial.prefs.favorites.contains(where: { $0.id == item.id }) {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Color(rgb: 0xF7C76A))
                                                .offset(y: -29)
                                                .allowsHitTesting(false)
                                                .accessibilityHidden(true)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.title)
                            .accessibilityAddTraits(isCenter ? .isSelected : [])
                            .rotation3DEffect(.degrees(reduceMotion ? 0 : (distance < 0 ? 54 : -54) * turn),
                                              axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                            .scaleEffect(1 - 0.23 * turn + (isPlaying ? (0.13 + 0.10 * dwellAmount) * focus : 0))
                            .offset(x: horizontalOffset(distance, size: size, focus: focus, dwell: dwellAmount))
                            .onHover { hovering in
                                if isPlaying && isCenter { setSongCoverHover(hovering) }
                            }
                            if isPlaying, isCenter, focused, !dial.track.isEmpty,
                               let url = dial.appleMusicURL,
                               playingArtwork != item.stationArtwork, artwork.image(for: playingArtwork) != nil,
                               songCoverHovered || songLinkHovered {
                                Button {
                                    NSWorkspace.shared.open(url)
                                } label: {
                                    (Text("open in  ").fontWeight(.semibold) + Text("music").fontWeight(.black))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(.black.opacity(0.48), in: Capsule())
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .offset(y: 47 + size * (0.13 + 0.10 * dwellAmount) * focus / 2)
                                .onHover { hovering in
                                    songLinkHovered = hovering
                                    setSongCoverHover(hovering)
                                }
                            }
                            }
                            .zIndex(Double(5 - abs(distance)))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 38)
                    .padding(.bottom, size * 0.16)
                    .background {
                        CoverFlowInput(
                            playShortcut: AppShortcutAction.playPause.binding(in: dial.prefs.shortcuts),
                            keyboardEnabled: keyboardEnabled,
                            scroll: { delta, delay in
                                scroll(delta, pointSpacing: size * 0.69, settleAfter: delay)
                            },
                            play: { if let station { playSelection(station, from: position, focused: focused) } },
                            hold: { direction in
                                if let direction { beginKeyHold(direction, from: index, items: items) }
                                else { endKeyHold() }
                            }
                        )
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
                        if abs(drag.translation.width) > abs(drag.translation.height) {
                            browse(index + (drag.translation.width < 0 ? 1 : -1), items: items)
                        }
                    })
                } else {
                    ContentUnavailableView("No radio stations", systemImage: "radio")
                }
            }

            VStack(spacing: 7) {
                Text(station?.title ?? " ")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .overlay(alignment: .top) {
                        if let station {
                            let saved = dial.prefs.favorites.contains { $0.id == station.id }
                            Button { dial.favorite(station) } label: {
                                Image(systemName: saved ? "star.fill" : "star")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(saved ? Color(rgb: 0xF7C76A) : .white)
                                    .padding(7)
                                    .background(.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(saved ? "Remove favorite" : "Add favorite")
                            .opacity(stationNameHovered ? 1 : 0)
                            .allowsHitTesting(stationNameHovered)
                            .offset(y: -34)
                        }
                    }
                    .padding(.top, 34)
                    .contentShape(Rectangle())
                    .onHover { stationNameHovered = $0 }
                Text(trackDetail.isEmpty ? " " : trackDetail)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    .opacity(station?.isSelfRadio == true ? 1 : artworkFocus)
                    .accessibilityHidden(trackDetail.isEmpty || (station?.isSelfRadio != true && !focused))
                HStack(spacing: 25) {
                    Button { browse(index - 1, items: items) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous cover").disabled(index <= 0)
                    Button {
                        if let station { playSelection(station, from: position, focused: focused) }
                    } label: {
                        ZStack {
                            Image(systemName: "pause.fill").opacity(1 - playIconOpacity)
                            Image(systemName: "play.fill").opacity(playIconOpacity)
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.13), in: Circle())
                    }
                    .accessibilityLabel(focused && dial.playback == .playing ? "Pause" : "Play")
                    .disabled(station == nil)
                    Button { browse(index + 1, items: items) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next cover").disabled(index >= items.count - 1)
                }
                .buttonStyle(.borderless)
                .gettingStartedHighlight(dial.gettingStartedStep == .coverFlow)
                if let source = dial.source, source.isStation, dial.playback != .stopped {
                    Button { revealPlayingStation(from: position, items: items) } label: {
                        PlayingStatusLabel(
                            text: dial.status,
                            playingText: paused && dial.status == "Paused" ? "Playing \(source.title)" : dial.status,
                            pauseAppearance: dial.status == "Paused" || dial.status.hasPrefix("Playing ") ? pauseAppearance : 0
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Show the current station")
                    .accessibilityHint("Shows the current station in Cover Flow")
                } else {
                    Text(dial.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .padding(.vertical, 3)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 23)
        }
        .overlayPreferenceValue(CoverTopKey.self) { anchor in
            GeometryReader { geometry in
                if let anchor, let station {
                    let label = frequencyLookup.frequencies[station.id].map { String(format: "%.1f FM", $0) }
                        ?? fmFrequency(station.title).map { $0 + " FM" } ?? (station.isSelfRadio ? "SYSTEM AUDIO" : "ONLINE")
                    Text(label)
                        .font(.custom("Punctum-Regular", size: 24))
                        .foregroundStyle(.white.opacity(0.8))
                        .position(x: geometry.size.width / 2, y: max(48, geometry[anchor].minY / 2))
                        .allowsHitTesting(false)
                        .accessibilityLabel(label)
                }
            }
        }
        .focusEffectDisabled()
        .foregroundStyle(.white)
        .background {
            ZStack {
                backdrop(center: 0.25, edge: 0.075)
                backdrop(center: 0.12, edge: 0.025).opacity(focus)
                Color.black.opacity(0.16 * dwellAmount * focus)
            }
        }
        .task(id: station?.id) {
            if let station { await frequencyLookup.resolve(station) }
        }
        .task(id: dwellStation) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { settledFocus = false }
            guard dwellStation != nil else { return }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.85)) { settledFocus = true }
        }
        .onChange(of: paused, initial: true) { _, isPaused in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                pauseAppearance = isPaused ? 1 : 0
            }
        }
        .onChange(of: active, initial: true) { _, isActive in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.36)) {
                playbackPresence = isActive ? 1 : 0
                if isActive, previewID == dial.source?.id { previewID = nil }
            }
        }
        .task(id: highlightSource.map(ObjectIdentifier.init)) {
            guard let highlightSource else { return }
            let rendering = Task.detached(priority: .userInitiated) { await CoverHighlight.render(highlightSource) }
            let image = await withTaskCancellationHandler { await rendering.value } onCancel: { rendering.cancel() }
            guard let image,
                  !Task.isCancelled else { return }
            highlightedCover = (highlightSource, image)
        }
        .onChange(of: index, initial: true) { _, _ in prefetch(items, at: index, playingArtwork: playingArtwork) }
        .onChange(of: items) { _, _ in prefetch(items, at: index, playingArtwork: playingArtwork) }
        .onChange(of: playingArtwork) { _, _ in prefetch(items, at: index, playingArtwork: playingArtwork) }
        .onChange(of: selfRadioArtwork) { _, _ in prefetch(items, at: index, playingArtwork: playingArtwork) }
        .onChange(of: keyboardEnabled) { _, enabled in
            if !enabled { endKeyHold() }
        }
        .onChange(of: dial.source?.id) { oldID, id in
            if let id, id == centeringStationID { return }
            if let id, dial.source?.isSelfRadio == true,
               let target = items.firstIndex(where: { $0.id == id }) {
                let previous = scrollPosition ?? items.firstIndex(where: { $0.id == (previewID ?? oldID) }).map(Double.init) ?? Double(target)
                centerStation(id, from: previous, to: Double(target), entering: true)
                return
            }
            settleTask?.cancel()
            cancelKeyHold()
            cancelReveal()
            scrollPosition = nil
            previewID = nil
        }
        .onDisappear {
            settleTask?.cancel()
            songHoverTask?.cancel()
            cancelKeyHold()
            cancelReveal()
        }
    }

    private func setSongCoverHover(_ hovering: Bool) {
        songHoverTask?.cancel()
        if hovering {
            withAnimation(.easeInOut(duration: 0.16)) { songCoverHovered = true }
        } else {
            songHoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, !songLinkHovered else { return }
                withAnimation(.easeInOut(duration: 0.16)) { songCoverHovered = false }
            }
        }
    }

    private func fmFrequency(_ title: String) -> String? {
        let pattern = #"(?<![0-9])(?:8[7-9]|9[0-9]|10[0-8])[\.,][0-9](?![0-9])"#
        guard let range = title.range(of: pattern, options: .regularExpression) else { return nil }
        let value = String(title[range]).replacingOccurrences(of: ",", with: ".")
        guard let frequency = Double(value), (87.5...108.0).contains(frequency) else { return nil }
        return value
    }

    private func backdrop(center: Double, edge: Double) -> some View {
        RadialGradient(colors: [Color(white: center), Color(white: edge)],
                       center: UnitPoint(x: 0.5, y: 0.44), startRadius: 5, endRadius: 620)
    }

    private func prefetch(_ items: [Source], at index: Int, playingArtwork: URL?) {
        let selfRadio = [dial.selfRadio.artwork].compactMap { $0 }
        artwork.prefetch(selfRadio + CoverFlowArtwork.priorityURLs(in: items, around: index, playingArtwork: playingArtwork))
    }

    private func playbackFocus(at position: Double, playingIndex: Int?) -> Double {
        guard let playingIndex else { return 0 }
        let progress = max(0, 1 - abs(position - Double(playingIndex)) / 0.95)
        return progress * progress * (3 - 2 * progress) * (entryStrength ?? 1)
    }

    private func playSelection(_ station: Source, from position: Double, focused: Bool) {
        if focused || (station.id == dial.source?.id && dial.playback == .connecting) {
            dial.togglePlayback()
        } else { activate(station, from: position) }
    }

    private func activate(_ station: Source, from position: Double) {
        let changesStream = dial.source?.id != station.id || dial.playback == .stopped
        let items = stations
        guard let index = items.firstIndex(where: { $0.id == station.id }) else { return }
        centerStation(station.id, from: position, to: Double(index), entering: changesStream)
        if changesStream { dial.tune(station) }
        else if dial.playback == .paused { dial.togglePlayback() }
    }

    private var transition: Animation? { reduceMotion ? nil : .easeOut(duration: 0.24) }

    private func browse(_ index: Int, items: [Source]) {
        guard items.indices.contains(index) else { return }
        settleTask?.cancel()
        cancelKeyHold()
        cancelReveal()
        withAnimation(transition) {
            previewID = items[index].id == dial.source?.id && dial.playback != .stopped ? nil : items[index].id
            scrollPosition = nil
        }
    }

    private func scroll(_ delta: CGFloat, pointSpacing: CGFloat, settleAfter: Duration?) {
        let items = stations
        guard items.count > 1, pointSpacing > 0 else { return }
        if delta == 0, revealTask != nil { return }
        settleTask?.cancel()
        if delta != 0 {
            cancelKeyHold()
            cancelReveal()
            let origin = items.firstIndex { $0.id == (previewID ?? dial.source?.id) } ?? 0
            let previous = scrollPosition ?? Double(origin)
            let next = min(Double(items.count - 1), max(0, previous - delta / pointSpacing))
            StationHaptics.crossed(from: Int(previous.rounded()), to: Int(next.rounded()),
                                   stations: items, favorites: dial.prefs.favorites)
            scrollPosition = next
        }
        guard scrollPosition != nil, let settleAfter else { return }
        settleTask = Task { @MainActor in
            do { try await Task.sleep(for: settleAfter) }
            catch { return }
            snapToNearest()
        }
    }

    private func snapToNearest() {
        guard let position = scrollPosition else { return }
        let items = stations
        let nearest = min(Int(position.rounded()), items.count - 1)
        withAnimation(transition) {
            if items.indices.contains(nearest) {
                let station = items[nearest]
                previewID = station.id == dial.source?.id && dial.playback != .stopped ? nil : station.id
            }
            scrollPosition = nil
        }
    }

    private func beginKeyHold(_ direction: Int, from index: Int, items: [Source]) {
        guard items.count > 1 else { return }
        let next = min(items.count - 1, max(0, index + direction))
        browse(next, items: items)
        guard next != index else { return }
        keyHoldTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(240))
                let start = ProcessInfo.processInfo.systemUptime
                var previous = start
                var position = Double(next)
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(16))
                    let now = ProcessInfo.processInfo.systemUptime
                    let held = now - start
                    let speed = min(18, 1.5 + 10 * held * held)
                    let last = Double(max(0, stations.count - 1))
                    position = min(last, max(0, position + Double(direction) * speed * min(now - previous, 0.05)))
                    scrollPosition = position
                    previous = now
                    if position == 0 || position == last { break }
                }
            } catch {}
        }
    }

    private func endKeyHold() {
        guard keyHoldTask != nil else { return }
        cancelKeyHold()
        snapToNearest()
    }

    private func cancelKeyHold() {
        keyHoldTask?.cancel()
        keyHoldTask = nil
    }

    private func revealPlayingStation(from position: Double, items: [Source]) {
        guard let station = dial.source, let index = items.firstIndex(where: { $0.id == station.id }) else { return }
        centerStation(station.id, from: position, to: Double(index))
    }

    private func centerStation(_ id: String, from position: Double, to target: Double, entering: Bool = false) {
        settleTask?.cancel()
        cancelKeyHold()
        cancelReveal()
        let distance = abs(target - position)
        guard !reduceMotion, entering || distance > 0.01 else {
            withAnimation(transition) {
                previewID = nil
                scrollPosition = nil
            }
            return
        }

        let duration = min(1.25, 0.28 + 0.10 * sqrt(distance))
        centeringStationID = id
        entryStrength = entering ? 0 : nil
        scrollPosition = position
        revealTask = Task { @MainActor in
            let start = ProcessInfo.processInfo.systemUptime
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(16))
                    let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / duration)
                    let eased = progress * progress * (3 - 2 * progress)
                    scrollPosition = position + (target - position) * eased
                    if entering { entryStrength = eased }
                    if progress == 1 { break }
                }
            } catch { return }
            guard !Task.isCancelled else { return }
            revealTask = nil
            centeringStationID = nil
            entryStrength = nil
            previewID = nil
            scrollPosition = nil
        }
    }

    private func cancelReveal() {
        revealTask?.cancel()
        revealTask = nil
        centeringStationID = nil
        entryStrength = nil
    }

    private func horizontalOffset(_ distance: Double, size: CGFloat, focus: Double, dwell: Double) -> CGFloat {
        let magnitude = abs(distance)
        let spacing = size * (min(magnitude, 1) * (0.69 + (0.14 + 0.045 * dwell) * focus) + max(0, magnitude - 1) * 0.245)
        return distance < 0 ? -spacing : spacing
    }
}

private struct CoverTopKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

private struct PlayingStatusLabel: View {
    let text: String
    let playingText: String
    let pauseAppearance: Double
    @State private var hovered = false
    private let highlight = Color(rgb: 0xFF5477)

    var body: some View {
        ZStack {
            Text(playingText).opacity(1 - pauseAppearance)
            Text("Paused").opacity(pauseAppearance)
        }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(hovered ? highlight : .white.opacity(0.55))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(hovered ? highlight.opacity(0.14) : .clear, in: Capsule())
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.14), value: hovered)
    }
}

private struct CoverFlowInput: NSViewRepresentable {
    let playShortcut: VIShortcut
    let keyboardEnabled: Bool
    let scroll: (CGFloat, Duration?) -> Void
    let play: () -> Void
    let hold: (Int?) -> Void

    func makeNSView(context: Context) -> Input { Input() }
    func updateNSView(_ view: Input, context: Context) {
        view.scroll = scroll
        view.play = play
        view.hold = hold
        view.keyboardEnabled = keyboardEnabled
        view.playShortcut = playShortcut
    }

    final class Input: NSView {
        var scroll: (CGFloat, Duration?) -> Void = { _, _ in }
        var play: () -> Void = {}
        var hold: (Int?) -> Void = { _ in }
        var keyboardEnabled = true
        var playShortcut = AppShortcutAction.playPause.defaultKey
        private var monitor: Any?
        private var horizontalGesture = false
        private var heldKey: UInt16?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            horizontalGesture = false
            heldKey = nil
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            super.viewWillMove(toWindow: newWindow)
            if let newWindow {
                NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                                                       name: NSWindow.didResignKeyNotification, object: newWindow)
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown, .keyUp]) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowResigned() { releaseKey() }

        private func releaseKey() {
            guard heldKey != nil else { return }
            heldKey = nil
            hold(nil)
        }

        private func handleKey(_ event: NSEvent, window: NSWindow) -> Bool {
            guard !VIShortcutRecorder.isRecording else { return false }
            let isArrow = event.keyCode == 123 || event.keyCode == 124
            let isPlay = UInt32(event.keyCode) == playShortcut.keyCode && VIShortcut.modifiers(from: event) == playShortcut.modifiers
            guard isArrow || isPlay else { return false }
            if event.type == .keyUp && isArrow {
                guard heldKey == event.keyCode else { return false }
                releaseKey()
                return true
            }
            guard keyboardEnabled, window.isKeyWindow, window.attachedSheet == nil,
                  !(window.firstResponder is NSTextView) else { return false }
            if isPlay {
                if event.type == .keyDown && !event.isARepeat { play() }
                return true
            }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            if event.type == .keyDown && !event.isARepeat {
                releaseKey()
                heldKey = event.keyCode
                hold(event.keyCode == 123 ? -1 : 1)
            }
            return true
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }
            if event.type != .scrollWheel { return handleKey(event, window: window) }
            let phase = event.phase
            let momentum = event.momentumPhase
            if phase.contains(.began) || phase.contains(.mayBegin) { horizontalGesture = false }

            let x = event.scrollingDeltaX
            let y = event.scrollingDeltaY
            let phaseLess = phase.isEmpty && momentum.isEmpty
            if !horizontalGesture || phaseLess {
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                guard inside, momentum.isEmpty, abs(x) > abs(y) else { return false }
                horizontalGesture = !phaseLess
            }

            if momentum.contains(.ended) || phase.contains(.cancelled) {
                horizontalGesture = false
                scroll(0, .zero)
            } else {
                // The finger-up event arrives before macOS delivers its first momentum event.
                let delay: Duration? = phase.contains(.ended) ? .milliseconds(140) :
                    phaseLess ? .milliseconds(120) : nil
                scroll(event.hasPreciseScrollingDeltas ? x : x * 14, delay)
            }
            return true
        }
    }
}

let stationArtworkMatte = Color(white: 0.13)

struct StationArtworkBacking: View {
    let edges: StationArtworkEdgeColors?

    var body: some View {
        VStack(spacing: 0) {
            edges?.top.map { Color(cgColor: $0) } ?? stationArtworkMatte
            edges?.bottom.map { Color(cgColor: $0) } ?? stationArtworkMatte
        }
    }
}

private struct FlowCover: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fallbackTitle: String?
    let image: CGImage?
    let album: CGImage?
    let albumOpacity: Double
    let highlight: CGImage?
    let highlightOpacity: Double
    let dimming: Double
    let size: CGFloat

    var body: some View {
        let station = image.map { CoverFlowArtwork.stationFace(for: $0) }
        return face(station: station, isReflection: false)
            .overlay(alignment: .bottom) {
                face(station: station, isReflection: true)
                    .scaleEffect(x: 1, y: -1)
                    .frame(height: size * 0.24, alignment: .top)
                    .clipped()
                    .mask(LinearGradient(colors: [.white.opacity(0.32), .clear], startPoint: .top, endPoint: .bottom))
                    .offset(y: size * 0.24 + 3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.4), radius: 7, y: 5)
    }

    private func face(station: CoverFlowArtwork.StationFace?, isReflection: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        let usesGlass = station?.usesGlass ?? false
        let edges = usesGlass ? nil : station.flatMap { StationArtworkEdgeColors.forLandscapeImage($0.image) }
        return ZStack {
            if let image = station?.image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else {
                placeholder
            }
            if let album {
                Image(decorative: album, scale: 1).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .background(Color(white: 0.13))
                    .opacity(albumOpacity)
                    .id(ObjectIdentifier(album))
                    .transition(.opacity)
            }
            if !isReflection, let highlight {
                Image(decorative: highlight, scale: 1)
                    .allowedDynamicRange(.constrainedHigh)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .background(album != nil ? stationArtworkMatte : .clear)
                    .opacity(highlightOpacity)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .brightness(-dimming)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: album.map(ObjectIdentifier.init))
        .background {
            if usesGlass {
                if #available(macOS 26.0, *), !isReflection {
                    shape.fill(.clear)
                        .glassEffect(.clear.tint(.black.opacity(0.10)), in: shape)
                        .mask { shape.strokeBorder(.white, lineWidth: 3) }
                }
            } else {
                StationArtworkBacking(edges: edges)
                    .brightness(edges == nil ? 0 : -dimming)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: highlight.map(ObjectIdentifier.init))
        .clipShape(shape)
        .overlay {
            if usesGlass {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.035)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            } else {
                shape.strokeBorder(.white.opacity(0.18))
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if let fallbackTitle, !fallbackTitle.isEmpty {
            Text(fallbackTitle)
                .font(.custom("BarlowCondensed-SemiBold", size: size * 0.15))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .padding(size * 0.12)
                .frame(width: size, height: size)
                .foregroundStyle(.white.opacity(0.9))
                .background(Color(white: 0.15).gradient)
        } else {
            Image(systemName: "radio").font(.system(size: size * 0.23, weight: .light))
                .foregroundStyle(.white.opacity(0.53))
        }
    }
}
