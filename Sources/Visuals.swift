import SwiftUI

struct DialPalette {
    let name: String
    let base, panel, inset, accent, text: Color
    let light: Bool
    var line: Color { accent.opacity(light ? 0.34 : 0.30) }
    var secondary: Color { text.opacity(light ? 0.72 : 0.68) }
    var signal: Color {
        switch name {
        case "Porcelain": return Color(rgb: 0x215F58)
        case "vice city": return Color(rgb: 0xFF91C3)
        case "eternal sunshine": return Color(rgb: 0xE4B078)
        case "Graphite": return Color(rgb: 0xCFD8E0)
        default: return Color(rgb: 0x00C2A1)
        }
    }
    var displayBackground: Color {
        switch name {
        case "Porcelain": return Color(rgb: 0xE2E8E0)
        case "vice city": return Color(rgb: 0x1B102D)
        case "eternal sunshine": return Color(rgb: 0x1A1411)
        case "Graphite": return Color(rgb: 0x151719)
        default: return light ? inset : Color(rgb: 0x11171B)
        }
    }
    var scopeBackground: Color {
        switch name {
        case "Porcelain": return Color(rgb: 0x183D3B)
        case "vice city": return Color(rgb: 0x100C2A)
        case "eternal sunshine": return Color(rgb: 0x211612)
        case "Graphite": return Color(rgb: 0x111417)
        default: return Color(rgb: 0x101926)
        }
    }
    var scopeSignal: Color { name == "vice city" ? Color(rgb: 0x78E4E7) : (light ? Color(rgb: 0xA5D1BF) : signal) }

    init(_ name: String) {
        self.name = name
        let values: [String: [UInt32]] = [
            "Cover Flow": [0x121212, 0x242424, 0x161616, 0xD5D5D5, 0xF5F5F5],
            "FR-01 Receiver": [0xB5B9B6, 0xD6D9D5, 0xC6CBC6, 0x7C5A2D, 0x202724],
            "Porcelain": [0xECEAE5, 0xFAF9F5, 0xE4E5DF, 0x38645F, 0x202D2C],
            "vice city": [0x120B22, 0x241538, 0x1B102D, 0xF797C8, 0xF8EAF6],
            "eternal sunshine": [0x191411, 0x29211D, 0x201713, 0xD8A77E, 0xF7E9DA],
            "Graphite": [0x111214, 0x232528, 0x16181A, 0xB9C3CD, 0xF1F3F4]
        ]
        let colors = values[name] ?? values["vice city"]!
        base = Color(rgb: colors[0])
        panel = Color(rgb: colors[1])
        inset = Color(rgb: colors[2])
        accent = Color(rgb: colors[3])
        text = Color(rgb: colors[4])
        light = name == "Porcelain" || name == RadioReceiverStyle.name
    }

    static let themes = ["Porcelain", "Graphite", "eternal sunshine", "vice city"]

    static func currentTheme(_ name: String) -> String {
        if themes.contains(name) || name == "Cover Flow" || name == RadioReceiverStyle.name { return name }
        switch name {
        case "Midnight", "Vice Nights": return "vice city"
        case "Light Glass": return "Porcelain"
        case "eternal sunshine!", "Ember", "Vintage Wood", "Retro Terminal", "Sunset 3D": return "eternal sunshine"
        case "Monochrome": return "Graphite"
        default: return "vice city"
        }
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double(rgb >> 16 & 255) / 255, green: Double(rgb >> 8 & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

struct DialKnob: View {
    var label: String
    var value: Double
    var range: ClosedRange<Double>
    var neutral: Double
    var tint: Color
    var change: (Double) -> Void
    @State private var anchor: Double?

    private var fraction: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }
    private var angle: Angle { .degrees(-135 + 270 * fraction) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().trim(from: 0, to: 0.75).stroke(tint.opacity(0.23), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle().trim(from: 0, to: max(0.001, fraction * 0.75))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.2, lineCap: .round)).rotationEffect(.degrees(135))
                Circle().fill(LinearGradient(colors: [Color(rgb: 0x333743), Color(rgb: 0x15191E)], startPoint: .top, endPoint: .bottom)).padding(4)
                Circle().strokeBorder(.white.opacity(0.09)).padding(4)
                Capsule().fill(tint).frame(width: 2, height: 9).offset(y: -8).rotationEffect(angle)
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 1).onChanged { drag in
                if anchor == nil { anchor = value }
                let newValue = (anchor ?? value) + (drag.translation.width - drag.translation.height) * (range.upperBound - range.lowerBound) / 100
                change(min(range.upperBound, max(range.lowerBound, newValue.rounded())))
            }.onEnded { _ in anchor = nil })
            .onTapGesture(count: 2) { change(neutral) }
            .accessibilityLabel(label)
            .accessibilityValue(String(Int(value)))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: change(min(range.upperBound, value + 1))
                case .decrement: change(max(range.lowerBound, value - 1))
                @unknown default: break
                }
            }
            Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).opacity(0.55)
            Text(String(Int(value))).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(tint)
        }
        .frame(minWidth: 42)
    }
}

struct Scope: View {
    @ObservedObject var meter: MeterState
    let mode: String
    let palette: DialPalette
    static let modes = ["Spectrum", "Waveform", "Aurora", "Waterfall"]

    static func currentMode(_ saved: String) -> String {
        switch saved {
        case "Particles", "Fire", "Galaxy", "DNA Helix": return "Aurora"
        case "Terrain": return "Waterfall"
        default: return modes.contains(saved) ? saved : "Spectrum"
        }
    }

    var body: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                draw(context, size: size)
            }
            .background {
                LinearGradient(colors: [palette.scopeBackground, palette.scopeBackground.opacity(0.84)], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(.rect(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.line) }
            Canvas { context, size in
                for row in 0..<2 {
                    let level = row == 0 ? meter.frame.left : meter.frame.right
                    let normalized = max(0, min(1, (20 * log10(max(0.0001, level)) + 52) / 52))
                    for cell in 0..<28 {
                        let tint: Color = cell > 24 ? .red : cell > 20 ? .orange : palette.scopeSignal
                        let cellWidth = size.width / CGFloat(28)
                        let rect = CGRect(x: CGFloat(cell) * cellWidth, y: CGFloat(row) * 6, width: max(1, cellWidth - 2), height: 4)
                        let lit = min(1, max(0, Double(normalized) * 28 - Double(cell)))
                        context.fill(Path(rect), with: .color(tint.opacity(0.13 + lit * 0.79)))
                    }
                }
            }
            .frame(height: 11)
        }
        .accessibilityLabel("\(mode) audio visualization")
    }

    private func draw(_ context: GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 10, dy: 5)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let bars = meter.frame.bars.map(Double.init)

        if mode != "Waterfall" {
            for column in 0...8 {
                let x = bounds.minX + bounds.width * Double(column) / 8
                let points = [CGPoint(x: x, y: bounds.minY), CGPoint(x: x, y: bounds.maxY)]
                stroke(context, path(points), palette.scopeSignal.opacity(0.07), width: 0.7)
            }
            for row in 0...4 {
                let y = bounds.minY + bounds.height * Double(row) / 4
                let points = [CGPoint(x: bounds.minX, y: y), CGPoint(x: bounds.maxX, y: y)]
                stroke(context, path(points), palette.scopeSignal.opacity(row == 2 ? 0.15 : 0.08), width: 0.7)
            }
        }
        switch mode {
        case "Waveform":
            drawWaveform(context, in: bounds)
        case "Aurora":
            drawAurora(context, in: bounds, bars: bars)
        case "Waterfall":
            drawWaterfall(context, in: bounds)
        default:
            drawSpectrum(context, in: bounds, bars: bars)
        }
    }

    private func drawSpectrum(_ context: GraphicsContext, in bounds: CGRect, bars: [Double]) {
        let step = bounds.width / Double(bars.count)
        let width = step * 0.72
        let gradient = Gradient(colors: [palette.scopeSignal.opacity(0.96), palette.scopeSignal.opacity(0.18)])
        for (index, bar) in bars.enumerated() {
            let height = max(1.3, pow(bar, 1.25) * bounds.height)
            let rect = CGRect(x: bounds.minX + Double(index) * step + (step - width) / 2,
                              y: bounds.maxY - height, width: width, height: height)
            let shape = Path(roundedRect: rect, cornerRadius: min(2.5, width / 2))
            let top = CGPoint(x: rect.midX, y: rect.minY)
            let bottom = CGPoint(x: rect.midX, y: rect.maxY)
            context.fill(shape, with: .linearGradient(gradient, startPoint: top, endPoint: bottom))
            if height > 3 {
                let cap = CGRect(x: rect.minX + 1, y: rect.minY, width: max(0, rect.width - 2), height: 1.2)
                context.fill(Path(roundedRect: cap, cornerRadius: 0.6), with: .color(palette.accent.opacity(0.30 + bar * 0.55)))
            }
        }
    }

    private func drawWaveform(_ context: GraphicsContext, in bounds: CGRect) {
        let waveform = meter.frame.waveform
        let points = waveform.enumerated().map { index, sample in
            let position = Double(index) / Double(waveform.count - 1)
            let amplitude = tanh(Double(sample) * 1.8)
            return CGPoint(x: bounds.minX + bounds.width * position, y: bounds.midY - amplitude * bounds.height * 0.48)
        }
        let trace = path(points)
        stroke(context, trace, palette.scopeSignal.opacity(0.14), width: 5)
        stroke(context, trace, palette.scopeSignal.opacity(0.92), width: 1.4)
    }

    private func drawAurora(_ context: GraphicsContext, in bounds: CGRect, bars: [Double]) {
        let tint = palette.accent
        // Adjacent frequency bands blend into a ribbon without a separate animation clock.
        let envelope = bars.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(bars.count - 1, index + 1)
            return (bars[lower] + 2 * bars[index] + bars[upper]) / 4
        }
        let points = envelope.enumerated().map { index, level in
            let position = Double(index) / Double(envelope.count - 1)
            let taper = 0.35 + 0.65 * sin(.pi * position)
            let height = pow(level, 1.4) * taper * bounds.height
            return CGPoint(x: bounds.minX + bounds.width * position, y: bounds.maxY - height * 0.92)
        }
        let ridge = path(points, curved: true)
        var fill = ridge
        fill.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        fill.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        fill.closeSubpath()
        context.fill(fill, with: .linearGradient(Gradient(colors: [tint.opacity(0.62), palette.scopeSignal.opacity(0.42), palette.scopeSignal.opacity(0.03)]),
                                                startPoint: CGPoint(x: bounds.midX, y: bounds.minY),
                                                endPoint: CGPoint(x: bounds.midX, y: bounds.maxY)))
        stroke(context, ridge, tint.opacity(0.13), width: 6)
        stroke(context, ridge, tint.opacity(0.86), width: 1.45)
    }

    private func drawWaterfall(_ context: GraphicsContext, in bounds: CGRect) {
        let history = meter.history
        let recent = meter.frame.bars
        let traces = history.dropLast().map { $0 } + [recent]
        for (index, bands) in traces.enumerated() {
            let age = Double(traces.count - 1 - index)
            let depth = 1 - age / 20
            let width = bounds.width * (0.70 + 0.30 * depth)
            let baseline = bounds.minY + bounds.height * (0.33 + 0.63 * depth)
            let points = bands.enumerated().map { column, level in
                let x = bounds.midX - width / 2 + width * Double(column) / Double(bands.count - 1)
                let height = pow(Double(level), 1.35) * bounds.height * (0.15 + 0.25 * depth)
                return CGPoint(x: x, y: baseline - height)
            }
            let ridge = path(points, curved: true)
            let newest = index == traces.count - 1
            stroke(context, ridge, newest ? palette.accent.opacity(0.88) : palette.scopeSignal.opacity(0.16 + 0.45 * depth),
                   width: newest ? 1.45 : 0.85)
        }
    }

    private func path(_ points: [CGPoint], curved: Bool = false) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: first)
        if curved {
            for (previous, next) in zip(points, points.dropFirst()) {
                let midpoint = (previous.x + next.x) / 2
                path.addCurve(to: next, control1: CGPoint(x: midpoint, y: previous.y),
                              control2: CGPoint(x: midpoint, y: next.y))
            }
        } else {
            path.addLines(Array(points.dropFirst()))
        }
        return path
    }

    private func stroke(_ context: GraphicsContext, _ path: Path, _ color: Color, width: Double) {
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }
}
