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
    @State private var preview: Int?
    @State private var pendingTune: Task<Void, Never>?
    @State private var tuningKnobStart: Double?
    @State private var volumeStart: Double?

    private var currentIndex: Int? { dial.stations.firstIndex { $0.id == dial.source?.id } }
    private var index: Int? { preview ?? currentIndex }
    private var position: Double {
        guard let index, dial.stations.count > 1 else { return 0 }
        return Double(index) / Double(dial.stations.count - 1)
    }
    private var previewStation: Source? { preview.flatMap { dial.stations.indices.contains($0) ? dial.stations[$0] : nil } }
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
            .frame(height: min(geometry.size.height - 32, (geometry.size.width - 32) / 1.76))
            .background { ReceiverMetal() }
            .clipShape(.rect(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.82), lineWidth: 2) }
            .overlay { screws.allowsHitTesting(false) }
            .shadow(color: .black.opacity(0.48), radius: 8, x: 0, y: 8)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(RadioReceiverStyle.ink)
        .background(Color(rgb: 0x262C2A))
        .onChange(of: dial.source?.id) { _, _ in cancelTune() }
        .onChange(of: dial.busy) { _, busy in if busy { cancelTune() } }
        .onDisappear { cancelTune() }
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
                    label("DIAL POSITION", illuminated: true)
                    Text(index == nil ? "—" : (88 + 20 * position).formatted(.number.precision(.fractionLength(1))))
                        .font(.system(size: 59, weight: .medium, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(RadioReceiverStyle.amber)
                        .lineLimit(1).minimumScaleFactor(0.65)
                        .accessibilityLabel("Dial position")
                        .accessibilityValue(index == nil ? "Not tuned" : (88 + 20 * position).formatted(.number.precision(.fractionLength(1))))
                }
                .frame(width: 174, alignment: .leading)
                Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 78)
                VStack(alignment: .leading, spacing: 7) {
                    label(preview != nil ? "TUNING" : "NOW TUNED", illuminated: true)
                    Text(previewStation?.title ?? dial.source?.title ?? "Choose a station")
                        .font(.system(size: 23, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(RadioReceiverStyle.dialText)
                    Text(displaySubtitle)
                        .font(.system(size: 13)).lineLimit(2)
                        .foregroundStyle(RadioReceiverStyle.dialText.opacity(0.74))
                        .help(displaySubtitle)
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
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(0.70), lineWidth: 5) }
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.32), lineWidth: 1) }
        .padding(3)
        .background(Color(rgb: 0x545D57), in: RoundedRectangle(cornerRadius: 17))
        .overlay { RoundedRectangle(cornerRadius: 17).strokeBorder(.white.opacity(0.78)) }
    }

    private var displaySubtitle: String {
        if preview != nil { return "Tuning…" }
        if !dial.track.isEmpty { return dial.track }
        if dial.busy { return "Loading stations…" }
        return dial.source?.subtitle.nonempty ?? dial.status
    }

    private var tuningScale: some View {
        VStack(spacing: 4) {
            Canvas { context, size in
                let bottom = size.height - 3
                for tick in 0...100 {
                    let major = tick.isMultiple(of: 10)
                    let length: Double = major ? 21 : tick.isMultiple(of: 5) ? 13 : 8
                    let x = size.width * Double(tick) / 100
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: bottom))
                    line.addLine(to: CGPoint(x: x, y: bottom - length))
                    context.stroke(line, with: .color(RadioReceiverStyle.dialText.opacity(major ? 0.63 : 0.33)), lineWidth: 0.8)
                }
                var base = Path()
                base.move(to: CGPoint(x: 0, y: bottom))
                base.addLine(to: CGPoint(x: size.width, y: bottom))
                context.stroke(base, with: .color(.white.opacity(0.25)), lineWidth: 0.8)
                if index != nil {
                    let x = min(size.width - 4, max(4, size.width * position))
                    var needle = Path()
                    needle.move(to: CGPoint(x: x, y: bottom + 2))
                    needle.addLine(to: CGPoint(x: x, y: 5))
                    context.stroke(needle, with: .color(RadioReceiverStyle.amber), lineWidth: 1.4)
                    var tip = Path()
                    tip.move(to: CGPoint(x: x - 4, y: 1))
                    tip.addLine(to: CGPoint(x: x + 4, y: 1))
                    tip.addLine(to: CGPoint(x: x, y: 7))
                    tip.closeSubpath()
                    context.fill(tip, with: .color(RadioReceiverStyle.amber))
                }
            }.frame(height: 38)

            HStack {
                ForEach(0...10, id: \.self) { i in
                    if i != 0 { Spacer(minLength: 0) }
                    Text(String(88 + 2 * i))
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(RadioReceiverStyle.dialText.opacity(0.76))
        }
        .padding(.horizontal, 5)
        .overlay {
            ReceiverTuningInput(drag: selectPosition, scroll: scrollStations)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Station tuning scale")
        .accessibilityValue(previewStation?.title ?? dial.source?.title ?? "Not tuned")
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
                        cancelTune()
                        dial.togglePlayback()
                    } label: {
                        ReceiverKeyLabel(symbol: dial.playback == .playing ? "pause.fill" : "play.fill", active: dial.playback == .playing)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(dial.playback == .playing ? "Pause" : "Play")
                }
                country
            }
            Divider().frame(height: 60).padding(.top, 13)
            VStack(spacing: 11) {
                label("PRESETS")
                HStack(spacing: 6) {
                    ForEach(0..<Self.presetCount, id: \.self) { slot in
                        let number = "0\(slot + 1)"
                        let source = presets.indices.contains(slot) ? presets[slot] : nil
                        Button {
                            guard let source else { return }
                            cancelTune()
                            dial.play(source)
                        } label: {
                            ReceiverKeyLabel(text: number, active: source?.id == dial.source?.id && source != nil)
                        }
                        .buttonStyle(.plain)
                        .disabled(source == nil)
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
        Text(value).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1.7)
            .foregroundStyle(illuminated ? RadioReceiverStyle.dialText.opacity(0.68) : RadioReceiverStyle.ink)
    }

    private func selectPosition(_ fraction: Double, _ commit: Bool) {
        guard !dial.busy, !dial.stations.isEmpty else { return }
        pendingTune?.cancel()
        preview = Int((min(1, max(0, fraction)) * Double(dial.stations.count - 1)).rounded())
        if commit { commitTune() }
    }

    private func scrollStations(_ steps: Int) {
        guard !dial.busy, !dial.stations.isEmpty, steps != 0 else { return }
        let initial = steps > 0 ? -1 : dial.stations.count
        preview = min(dial.stations.count - 1, max(0, (index ?? initial) + steps))
        pendingTune?.cancel()
        pendingTune = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { commitTune() }
        }
    }

    private func commitTune() {
        guard !dial.busy, let station = previewStation else { cancelTune(); return }
        cancelTune()
        if dial.source?.id != station.id || dial.playback == .stopped { dial.play(station) }
    }

    private func cancelTune() {
        pendingTune?.cancel()
        pendingTune = nil
        preview = nil
    }
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
            let delta = abs(horizontal) > abs(vertical) ? -horizontal : -vertical
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

private struct ReceiverMetal: View {
    var body: some View {
        LinearGradient(stops: [.init(color: Color(rgb: 0xF4F5F0), location: 0), .init(color: Color(rgb: 0xAFB7B2), location: 0.41),
                               .init(color: Color(rgb: 0xE4E7E1), location: 0.73), .init(color: Color(rgb: 0xA3ACA7), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .overlay {
                Canvas { context, size in
                    for row in 0..<Int(size.height) {
                        let texture = Double((row * 61 + 17) % 101) / 100
                        let rect = CGRect(x: 0, y: Double(row), width: size.width, height: 0.5)
                        context.fill(Path(rect), with: .color(texture > 0.5 ? .white.opacity(texture * 0.15) : .black.opacity(texture * 0.09)))
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
            Text("DYNAMIC SPEAKER").font(.system(size: 8, weight: .bold, design: .monospaced)).tracking(2.6)
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
