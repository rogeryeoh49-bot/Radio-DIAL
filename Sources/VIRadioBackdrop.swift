import AppKit
import SwiftUI

/// WindowServer renders the live desktop behind this view. No screen capture is used.
/// Public AppKit materials choose their own blur strength; there is no radius override.
@MainActor final class VIRadioBackdrop: NSView {
    nonisolated static let defaultStrength = 1.0
    nonisolated static let defaultDarkness = 0.0
    let effect = NSVisualEffectView()
    private let dimming = NSView()

    init(foreground: NSView, frame: NSRect, strength: Double = defaultStrength, darkness: Double = defaultDarkness) {
        super.init(frame: frame)
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        addSubview(effect)

        dimming.frame = bounds
        dimming.autoresizingMask = [.width, .height]
        dimming.wantsLayer = true
        addSubview(dimming)
        update(strength: strength, darkness: darkness)

        // Keep all interactive artwork and text outside the background effect subtree.
        foreground.frame = bounds
        foreground.autoresizingMask = [.width, .height]
        addSubview(foreground)
    }

    func update(strength: Double, darkness: Double) {
        let strength = strength.isFinite ? min(1, max(0, strength)) : Self.defaultStrength
        let darkness = darkness.isFinite ? min(0.8, max(0, darkness)) : Self.defaultDarkness
        effect.alphaValue = strength
        // At zero strength remove the material completely, revealing the real desktop.
        effect.isHidden = strength == 0
        dimming.layer?.backgroundColor = NSColor.black.withAlphaComponent(darkness).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct VIRadioBackdropPreview: NSViewRepresentable {
    var strength: Double
    var darkness: Double

    func makeNSView(context: Context) -> VIRadioBackdrop {
        let foreground = NSView()
        let title = NSTextField(labelWithString: "VI RADIO · LIVE PREVIEW")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .white
        title.translatesAutoresizingMaskIntoConstraints = false
        foreground.addSubview(title)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: foreground.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: foreground.centerYAnchor)
        ])
        return VIRadioBackdrop(foreground: foreground, frame: NSRect(x: 0, y: 0, width: 400, height: 80),
                               strength: strength, darkness: darkness)
    }

    func updateNSView(_ view: VIRadioBackdrop, context: Context) {
        view.update(strength: strength, darkness: darkness)
    }
}
