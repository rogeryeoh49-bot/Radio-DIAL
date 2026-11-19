import AppKit
import SwiftUI

enum RadioReceiverStyle {
    static let name = "FR-01 Receiver"
    static let ink = Color(rgb: 0x282F2D)
    static let amber = Color(rgb: 0xFFC884)
    static let dialText = Color(rgb: 0xF2F0E3)
}

struct RadioReceiver<Country: View, Tools: View>: View {
    @ObservedObject var dial: DialState
    let country: Country
    let tools: Tools
    @State private var previewFrequency: Double?
    @State private var pendingTune: Task<Void, Never>?
    @State private var streamTask: Task<Void, Never>?
    @State private var activeStation: BroadcastStation?
    @State private var activeMarketID: String?
    @State private var activeSourceID: String?
    @State private var streamCandidates: [Source] = []
    @State private var attemptedStreamURLs: Set<URL> = []
    @State private var streamLookupFinished = false
    @State private var streamLookupFailed = false
    @State private var tuningKnobStart: Double?
    @State private var volumeStart: Double?
    @StateObject private var directory = MarketDirectory()
    @State private var tuningStatus = "Select a frequency"
    private var market: RadioMarket { RadioMarket.all.first { $0.id == dial.prefs.radioMarket } ?? RadioMarket.all[0] }
    private var band: BroadcastBand { BroadcastBand(rawValue: dial.prefs.radioBand ?? "FM") ?? .fm }
    private var lower: Double { band == .fm ? 88 : 530 }
    private var upper: Double { band == .fm ? 108 : 1700 }
    private var step: Double { band == .fm ? 0.1 : 10 }
    private var displayedFrequency: Double? { previewFrequency }
    private var position: Double { displayedFrequency.map { min(1, max(0, ($0 - lower) / (upper - lower))) } ?? 0 }
    private var previewStation: BroadcastStation? {
        guard let frequency = previewFrequency else { return nil }
        let key = Int((band == .fm ? frequency * 10 : frequency).rounded())
        return directory.stations.first { $0.band == band && $0.frequency == key }
    }
    private var displayedStation: BroadcastStation? { previewStation }
    private static var presetCount: Int { 4 }
    private var presets: [Source] { Array(dial.prefs.favorites.lazy.filter(\.isRadio).prefix(Self.presetCount)) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 14) {
                header
                HStack(spacing: 24) {
                    VStack(spacing: 14) {
                        display.frame(maxHeight: .infinity)
                        controls
                    }
                    ReceiverGrille()
                        .frame(width: min(275, max(160, geometry.size.width * 0.22)))
                }
                footer
            }
            .padding(.horizontal, 33)
            .padding(.vertical, 22)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background { ReceiverMetal() }
            .overlay { Rectangle().strokeBorder(.white.opacity(0.55), lineWidth: 1) }
            .overlay { screws.allowsHitTesting(false) }
        }
        .foregroundStyle(RadioReceiverStyle.ink)
        .background(Color(rgb: 0x262C2A))
        .onAppear {
            dial.stop(message: "Choose a city and frequency")
            previewFrequency = band == .fm ? 100.3 : 1000
            directory.load(market)
        }
        .onChange(of: dial.prefs.radioMarket) { _, _ in changeMarket() }
        .onChange(of: directory.loading) { _, loading in if !loading { commitTune() } }
        .onChange(of: dial.playback) { _, playback in playbackChanged(playback) }
        .onDisappear { cancelTune(); resetStreamLookup(); if dial.playback == .stopped { dial.audio.halt() } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 19, weight: .medium))
            Text("RADIO DIAL").font(.system(size: 23, weight: .black)).tracking(4)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(.black.opacity(0.20)).frame(width: 1, height: 17)
            Text("FR–01").font(.system(size: 11, weight: .medium, design: .monospaced)).tracking(2)
            Spacer()
            tools
        }
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { ReceiverRule() }
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    label("\(band.rawValue) FREQUENCY", illuminated: true)
                    Text(displayedFrequency.map { band == .fm ? $0.formatted(.number.precision(.fractionLength(1))) : String(Int($0)) } ?? "—")
                        .font(.system(size: 59, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RadioReceiverStyle.amber)
                        .lineLimit(1).minimumScaleFactor(0.65)
                        .accessibilityLabel("FM frequency")
                        .accessibilityValue(displayedFrequency.map { "\(band == .fm ? $0.formatted(.number.precision(.fractionLength(1))) : String(Int($0))) \(band == .fm ? "megahertz" : "kilohertz")" } ?? "Unavailable")
                }
                .frame(width: 174, alignment: .leading)
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 78)
                VStack(alignment: .leading, spacing: 7) {
                    label("NOW TUNED", illuminated: true)
                    Text(displayedStation?.callsign ?? "—")
                        .font(.system(size: 23, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(RadioReceiverStyle.dialText)
                    Text(displaySubtitle)
                        .font(.system(size: 13)).lineLimit(2)
                        .foregroundStyle(RadioReceiverStyle.dialText.opacity(0.74))
                        .help(displaySubtitle)
                    if displayedStation != nil, !dial.track.isEmpty, dial.playback != .stopped,
                       let url = dial.appleMusicURL {
                        AppleMusicButton(url: url, color: RadioReceiverStyle.amber)
                    }
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            tuningScale
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(
                LinearGradient(colors: [Color(rgb: 0x28302C), Color(rgb: 0x141B18), Color(rgb: 0x0B120F)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.76), lineWidth: 5) }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 11).strokeBorder(.black.opacity(0.18), lineWidth: 2).padding(5).allowsHitTesting(false)
        }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.32), lineWidth: 1) }
        .padding(3)
        .background(Color(rgb: 0x545D57), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.78)) }
    }

    private var displaySubtitle: String {
        if directory.loading && directory.stations.isEmpty { return "Loading FCC stations…" }
        if let error = directory.error, directory.stations.isEmpty { return error }
        if !dial.track.isEmpty && dial.playback != .stopped { return dial.track }
        return tuningStatus
    }

    private var tuningScale: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let bottom = size.height - 3
                for tick in 0...100 {
                    let major = tick.isMultiple(of: 10)
                    let length: Double = major ? 22 : tick.isMultiple(of: 5) ? 13 : 7
                    let x = size.width * Double(tick) / 100
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: bottom))
                    line.addLine(to: CGPoint(x: x, y: bottom - length))
                    context.stroke(line, with: .color(RadioReceiverStyle.dialText.opacity(major ? 0.78 : tick.isMultiple(of: 5) ? 0.53 : 0.34)), lineWidth: major ? 0.9 : 0.6)
                }
                var base = Path()
                base.move(to: CGPoint(x: 0, y: bottom))
                base.addLine(to: CGPoint(x: size.width, y: bottom))
                context.stroke(base, with: .color(.white.opacity(0.25)), lineWidth: 0.8)
                if let frequency = displayedFrequency {
                    let x = min(size.width - 4, max(4, size.width * (frequency - lower) / (upper - lower)))
                    var needle = Path()
                    needle.move(to: CGPoint(x: x, y: bottom + 2))
                    needle.addLine(to: CGPoint(x: x, y: 5))
                    context.drawLayer { glow in
                        glow.addFilter(.shadow(color: RadioReceiverStyle.amber.opacity(0.24), radius: 2))
                        glow.stroke(needle, with: .color(RadioReceiverStyle.amber.opacity(0.85)), lineWidth: 1.1)
                    }
                    var tip = Path()
                    tip.move(to: CGPoint(x: x - 4, y: 1))
                    tip.addLine(to: CGPoint(x: x + 4, y: 1))
                    tip.addLine(to: CGPoint(x: x, y: 7))
                    tip.closeSubpath()
                    context.fill(tip, with: .color(RadioReceiverStyle.amber))
                }
            }.frame(height: 38)

            GeometryReader { geometry in
                ForEach(0...10, id: \.self) { i in
                    Text(band == .fm ? String(88 + 2 * i) : String(530 + 117 * i))
                        .font(.custom("BarlowCondensed-Regular", size: 14))
                        .foregroundStyle(RadioReceiverStyle.dialText.opacity(0.82))
                        .fixedSize()
                        .position(x: geometry.size.width * CGFloat(i) / 10, y: 9)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 5)
        .overlay {
            ReceiverTuningInput(drag: selectFrequency, scroll: { scrollStations($0, haptic: true) })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Station tuning scale")
        .accessibilityValue(displayedStation?.callsign ?? "No station")
        .accessibilityHint("Drag across the scale or scroll to tune")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: scrollStations(1)
            case .decrement: scrollStations(-1)
            @unknown default: break
            }
        }
    }

    private var controls: some View {
        HStack(alignment: .top, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(spacing: 11) {
                    label("PLAYBACK")
                    Button {
                        if dial.playback == .playing || (dial.playback == .paused && activeSourceID == dial.source?.id) { dial.togglePlayback() }
                        else { commitTune() }
                    } label: {
                        ReceiverKeyLabel(symbol: dial.playback == .playing ? "pause.fill" : "play.fill", active: dial.playback == .playing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dial.playback == .playing ? "Pause" : "Play")
                }
                cityMenu
                Button(band.rawValue) {
                    resetStreamLookup()
                    dial.stop(message: "Changing band")
                    dial.prefs.radioBand = band == .fm ? "AM" : "FM"
                    previewFrequency = band == .fm ? 100.3 : 1000
                    commitTune()
                }
                .buttonStyle(.plain)
                .frame(width: 42, height: 42)
                .modifier(ReceiverKeyFace(active: true))
                .help("Switch AM / FM")
            }
            Divider().frame(height: 60).padding(.top, 13)
            VStack(spacing: 11) {
                label("PRESETS")
                HStack(spacing: 6) {
                    ForEach(0..<Self.presetCount, id: \.self) { slot in
                        let number = "0\(slot + 1)"
                        let source = presets.indices.contains(slot) ? presets[slot] : nil
                        let station = source.flatMap { favorite in
                            directory.stations.first { $0.band == .fm && MarketDirectory.matches(favorite, station: $0) }
                        }
                        Button {
                            guard let station else { return }
                            dial.prefs.radioBand = "FM"
                            previewFrequency = Double(station.frequency) / 10
                            commitTune()
                        } label: {
                            ReceiverKeyLabel(text: number, active: source?.id == dial.source?.id && source != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(station == nil)
                        .opacity(source == nil ? 0.52 : 1)
                        .help(source?.title ?? "Add a station to Favorites to fill this preset")
                        .accessibilityLabel("Preset \(number), \(source?.title ?? "Empty")")
                    }
                }
            }
            Divider().frame(height: 60).padding(.top, 13)
            knob("TUNING", fraction: position)
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    if tuningKnobStart == nil { tuningKnobStart = position }
                    let movement = Double(drag.translation.width - drag.translation.height)
                    let value = (tuningKnobStart ?? position) + movement / 240
                    selectPosition(value, false)
                }.onEnded { _ in
                    tuningKnobStart = nil
                    commitTune()
                })
                .accessibilityHidden(true)
            Spacer(minLength: 0)
            knob("VOLUME", fraction: dial.prefs.volume / 100)
                .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                    if volumeStart == nil { volumeStart = dial.prefs.volume }
                    let movement = Double(drag.translation.width - drag.translation.height)
                    dial.setVolume((volumeStart ?? dial.prefs.volume) + movement)
                }.onEnded { _ in volumeStart = nil })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(dial.prefs.volume)) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: dial.setVolume(dial.prefs.volume + 5)
                    case .decrement: dial.setVolume(dial.prefs.volume - 5)
                    @unknown default: break
                    }
                }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { ReceiverRule() }
    }

    private func knob(_ title: String, fraction: Double) -> some View {
        VStack(spacing: 8) {
            label(title)
            ZStack {
                Circle().fill(Color(rgb: 0x4E5852))
                Circle().fill(LinearGradient(colors: [Color(rgb: 0xE3E5DF), Color(rgb: 0x929B94), Color(rgb: 0xC7CBC5)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)).padding(4)
                Circle().strokeBorder(.white.opacity(0.58), lineWidth: 0.8).padding(5)
                Capsule().fill(Color(rgb: 0x4A3824)).frame(width: 2.5, height: 8)
                    .offset(y: -18).rotationEffect(.degrees(-135 + 270 * fraction))
            }
            .frame(width: 57, height: 57)
            .shadow(color: .black.opacity(0.37), radius: 2, x: 0, y: 3)
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack {
            Text("FR–01  /  INTERNET RADIO")
            Spacer()
            Text(dial.status).lineLimit(1).help(dial.status)
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .tracking(1)
        .foregroundStyle(RadioReceiverStyle.ink.opacity(0.76))
        .padding(.top, 9)
        .overlay(alignment: .top) { ReceiverRule() }
    }

    private var screws: some View {
        VStack {
            HStack { screw; Spacer(); screw }
            Spacer()
            HStack { screw; Spacer(); screw }
        }
        .padding(11)
    }

    private var screw: some View {
        ZStack {
            Circle().fill(.white.opacity(0.52))
            Circle().strokeBorder(.black.opacity(0.39))
            Capsule().fill(.black.opacity(0.45)).frame(width: 6, height: 1).rotationEffect(.degrees(-30))
        }.frame(width: 10, height: 10)
    }

    private func label(_ value: String, illuminated: Bool = false) -> some View {
        Text(value).font(.custom("Barlow-Regular", size: 9)).tracking(1.6)
            .foregroundStyle(illuminated ? RadioReceiverStyle.dialText.opacity(0.68) : RadioReceiverStyle.ink)
    }

    private var cityMenu: some View {
        VStack(spacing: 11) {
        label("CITY")
        Menu {
            ForEach(RadioMarket.all) { city in
                Button { dial.prefs.radioMarket = city.id } label: {
                    if city.id == market.id { Label(city.label, systemImage: "checkmark") }
                    else { Text(city.label) }
                }
            }
        } label: {
            Text(market.label)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 110, height: 42)
        .modifier(ReceiverKeyFace(active: true))
        .help("Choose radio market: " + market.label)
        }
    }

    private func changeMarket() {
        resetStreamLookup()
        pendingTune?.cancel()
        dial.stop(message: "Changing city")
        tuningStatus = "Loading FCC stations…"
        directory.load(market)
    }

    private func selectFrequency(_ fraction: Double, _ commit: Bool) {
        pendingTune?.cancel()
        previewFrequency = ((lower + (upper - lower) * min(1, max(0, fraction))) / step).rounded() * step
        if commit { commitTune() }
    }

    private func selectPosition(_ fraction: Double, _ commit: Bool) { selectFrequency(fraction, commit) }

    private func scrollStations(_ steps: Int, haptic: Bool = false) {
        guard steps != 0 else { return }
        let previous = previewStation?.id
        previewFrequency = min(upper, max(lower, (((previewFrequency ?? lower) + Double(steps) * step) / step).rounded() * step))
        if haptic, let station = previewStation, station.id != previous {
            let favorite = dial.prefs.favorites.contains { $0.title.localizedCaseInsensitiveContains(station.callsign) }
            NSHapticFeedbackManager.defaultPerformer.perform(favorite ? .levelChange : .alignment, performanceTime: .now)
            if favorite {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
            }
        }
        pendingTune?.cancel()
        pendingTune = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { commitTune() }
        }
    }

    private func commitTune() {
        pendingTune?.cancel()
        // A background FCC refresh must not interrupt a stream already tuned to this station.
        if let station = previewStation, activeStation?.id == station.id, activeMarketID == market.id,
           activeSourceID == dial.source?.id, dial.playback != .stopped { return }
        resetStreamLookup()
        dial.stop(message: "Tuning")
        if directory.loading && directory.stations.isEmpty { tuningStatus = "Loading FCC stations…"; return }
        guard directory.error == nil || !directory.stations.isEmpty else { tuningStatus = "FCC data unavailable"; return }
        guard let station = previewStation else { tuningStatus = "No station in nearby FCC records"; try? dial.audio.playStatic(); return }
        let selectedMarket = market
        activeStation = station
        activeMarketID = selectedMarket.id
        tuningStatus = "\(station.community), \(station.state) · Looking for stream…"
        let saved = directory.rememberedStream(for: station, market: selectedMarket).map { [$0] } ?? []
        let known = saved + dial.prefs.favorites + dial.prefs.history.map(\.source) + dial.stations
        streamCandidates = MarketDirectory.matchingSources(known, station: station)
        if streamCandidates.isEmpty { try? dial.audio.playStatic() }
        else { playNextStream() }

        streamTask = Task { @MainActor in
            do {
                let online = try await MarketDirectory.streams(for: station)
                guard !Task.isCancelled, activeMarketID == selectedMarket.id, activeStation?.id == station.id,
                      previewStation?.id == station.id else { return }
                streamCandidates = MarketDirectory.matchingSources(streamCandidates + online, station: station)
                streamLookupFinished = true
                if activeSourceID == nil { playNextStream() }
            } catch {
                guard !Task.isCancelled, activeMarketID == selectedMarket.id, activeStation?.id == station.id,
                      previewStation?.id == station.id else { return }
                streamLookupFinished = true
                streamLookupFailed = true
                if activeSourceID == nil { playNextStream() }
            }
        }
    }

    private func playNextStream() {
        guard let station = activeStation, activeMarketID == market.id, previewStation?.id == station.id else { return }
        guard let candidate = streamCandidates.first(where: { !attemptedStreamURLs.contains($0.url) }) else {
            activeSourceID = nil
            if streamLookupFinished {
                tuningStatus = streamLookupFailed ? "Stream lookup unavailable" : "\(station.callsign) · No working matched stream"
            } else {
                tuningStatus = "\(station.callsign) · Looking for stream…"
            }
            try? dial.audio.playStatic()
            return
        }
        attemptedStreamURLs.insert(candidate.url)
        activeSourceID = candidate.id
        tuningStatus = "\(station.community), \(station.state)"
        dial.play(candidate, tuningEffect: true)
        // An immediate decoder/setup failure does not emit a later playback transition.
        if dial.playback == .stopped { activeSourceID = nil; playNextStream() }
    }

    private func playbackChanged(_ playback: DialState.Playback) {
        guard let station = activeStation, let source = dial.source,
              activeMarketID == market.id, previewStation?.id == station.id,
              activeSourceID == source.id else { return }
        if playback == .playing {
            directory.remember(source, for: station, market: market)
        } else if playback == .stopped, dial.status != "Stopped" {
            activeSourceID = nil
            playNextStream()
        }
    }

    private func resetStreamLookup() {
        streamTask?.cancel()
        streamTask = nil
        activeStation = nil
        activeMarketID = nil
        activeSourceID = nil
        streamCandidates = []
        attemptedStreamURLs = []
        streamLookupFinished = false
        streamLookupFailed = false
    }

    private func cancelTune() { pendingTune?.cancel(); pendingTune = nil }

}

private struct ReceiverTuningInput: NSViewRepresentable {
    let drag: (Double, Bool) -> Void
    let scroll: (Int) -> Void

    func makeNSView(context: Context) -> Input { Input() }
    func updateNSView(_ view: Input, context: Context) {
        view.drag = drag
        view.scroll = scroll
    }

    final class Input: NSView {
        var drag: (Double, Bool) -> Void = { _, _ in }
        var scroll: (Int) -> Void = { _ in }
        private var scrollRemainder: Double = 0
        private var lastScroll: TimeInterval = 0

        override func mouseDown(with event: NSEvent) { tune(event, commit: false) }
        override func mouseDragged(with event: NSEvent) { tune(event, commit: false) }
        override func mouseUp(with event: NSEvent) { tune(event, commit: true) }

        private func tune(_ event: NSEvent, commit: Bool) {
            let location = convert(event.locationInWindow, from: nil)
            drag(Double((location.x - 5) / max(1, bounds.width - 10)), commit)
        }

        override func scrollWheel(with event: NSEvent) {
            let horizontal = Double(event.scrollingDeltaX)
            let vertical = Double(event.scrollingDeltaY)
            let delta = abs(horizontal) > abs(vertical) ? horizontal : vertical
            if !event.hasPreciseScrollingDeltas {
                scroll(delta == 0 ? 0 : (delta > 0 ? 1 : -1))
                return
            }
            if event.timestamp - lastScroll > 0.30 { scrollRemainder = 0 }
            lastScroll = event.timestamp
            scrollRemainder += delta
            let steps = Int(scrollRemainder / 24)
            if steps != 0 {
                scrollRemainder -= Double(steps) * 24
                scroll(steps)
            }
        }
    }
}

struct ReceiverKeyLabel: View {
    var text = ""
    var symbol: String?
    var active = false

    var body: some View {
        ZStack {
            if let symbol { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)) }
            else { Text(text).font(.system(size: 14, weight: .semibold, design: .monospaced)) }
        }
        .foregroundStyle(RadioReceiverStyle.ink)
        .frame(width: symbol == nil ? 48 : 52, height: 42)
        .modifier(ReceiverKeyFace(active: active))
    }
}

struct ReceiverKeyFace: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 6).fill(
                LinearGradient(colors: active ? [Color(rgb: 0xF8E3BB), Color(rgb: 0xBC9564)] : [Color(rgb: 0xF3F3EC), Color(rgb: 0xA8B0AB)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.57), lineWidth: 1.5) }
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.52)).padding(2) }
        .shadow(color: .black.opacity(0.24), radius: 1, y: 2)
        .contentShape(Rectangle())
    }
}

struct ReceiverMetal: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color(rgb: 0xF4F5F0), location: 0), .init(color: Color(rgb: 0xAFB7B2), location: 0.41),
                               .init(color: Color(rgb: 0xE4E7E1), location: 0.73), .init(color: Color(rgb: 0xA3ACA7), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                Canvas { context, size in
                    for row in 0..<Int(size.height) {
                        let texture = Double((row * 61 + 17) % 101) / 100
                        let rect = CGRect(x: 0, y: Double(row), width: size.width, height: 0.5)
                        context.fill(Path(rect), with: .color(texture > 0.5 ? .white.opacity(texture * 0.10) : .black.opacity(texture * 0.06)))
                    }
                }.allowsHitTesting(false)
            }
    }
}

private struct ReceiverRule: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.black.opacity(0.25)).frame(height: 1)
            Rectangle().fill(.white.opacity(0.56)).frame(height: 1)
        }
    }
}

private struct ReceiverGrille: View {
    var body: some View {
        VStack(spacing: 9) {
            Canvas { context, size in
                let step: Double = 7
                for row in 0..<Int(size.height / step) {
                    for column in 0..<Int(size.width / step) {
                        let x = Double(column) * step + (row.isMultiple(of: 2) ? 1.5 : 4.5)
                        let y = Double(row) * step + 2
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y + 0.7, width: 3.6, height: 3.6)), with: .color(.white.opacity(0.40)))
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 3.6, height: 3.6)), with: .color(Color(rgb: 0x222927)))
                    }
                }
            }
            .background(LinearGradient(colors: [Color(rgb: 0x77817A), Color(rgb: 0xADB4AD), Color(rgb: 0x606B64)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(true)
            ReceiverRule()
            Text("DYNAMIC SPEAKER").font(.custom("Barlow-Regular", size: 8)).tracking(2.4)
                .lineLimit(1).minimumScaleFactor(0.65)
        }
        .padding(10)
        .background(Color(rgb: 0x939D95), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.black.opacity(0.64), lineWidth: 2) }
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.56)).padding(2) }
    }
}

struct ReceiverThemePreview: View {
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 5) {
                Text("RADIO DIAL").font(.system(size: 6, weight: .black)).tracking(1.4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("98.7").font(.system(size: 15, weight: .semibold, design: .monospaced))
                    HStack(spacing: 2) {
                        ForEach(0..<23) { tick in
                            Rectangle().fill(.white.opacity(0.46)).frame(width: 1, height: tick.isMultiple(of: 5) ? 5 : 2.5)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(RadioReceiverStyle.amber)
                .padding(5)
                .background(Color(rgb: 0x131A17), in: RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 2).fill(i == 1 ? RadioReceiverStyle.amber : .white.opacity(0.68))
                            .frame(width: 13, height: 7)
                    }
                    Spacer(minLength: 1)
                    Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1).frame(width: 9, height: 9)
                    Circle().strokeBorder(.black.opacity(0.55), lineWidth: 1).frame(width: 9, height: 9)
                }
            }
            ReceiverGrille().scaleEffect(0.97).frame(width: 44)
        }
        .padding(7)
        .foregroundStyle(RadioReceiverStyle.ink)
        .background { ReceiverMetal() }
        .clipShape(.rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.black.opacity(0.40)) }
        .accessibilityHidden(true)
    }
}

enum StationHaptics {
    static func selection(favorite: Bool) {
        NSHapticFeedbackManager.defaultPerformer.perform(favorite ? .levelChange : .alignment, performanceTime: .now)
        if favorite {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.065) {
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    static func crossed(from old: Int, to new: Int, stations: [Source], favorites: [Source]) {
        guard old != new else { return }
        let favoriteIDs = Set(favorites.map(\.id))
        let direction = new > old ? 1 : -1
        let first = max(0, min(stations.count - 1, old + direction))
        let last = max(0, min(stations.count - 1, new))
        guard stations.indices.contains(first), stations.indices.contains(last) else { return }
        for index in stride(from: first, through: last, by: direction) {
            let favorite = favoriteIDs.contains(stations[index].id)
            selection(favorite: favorite)
        }
    }
}
