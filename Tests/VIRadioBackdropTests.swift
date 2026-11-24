import AppKit
@main struct Test {
    @MainActor static func main() {
        _ = NSApplication.shared
        let foreground = NSView()
        let root = VIRadioBackdrop(foreground: foreground, frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        precondition(root.subviews.count == 3)
        precondition(root.subviews.first === root.effect && root.subviews.last === foreground)
        precondition(root.effect.blendingMode == .behindWindow && root.effect.state == .active)
        precondition(root.effect.material == .hudWindow)
        precondition(root.effect.subviews.isEmpty)
        precondition(foreground.layer?.filters == nil && foreground.layer?.backgroundFilters == nil)
        let dimming = root.subviews[1]
        precondition(dimming.layer?.backgroundColor?.alpha == 0)
        precondition(abs(root.effect.alphaValue - 1.0) < 0.001)
        root.update(strength: 0, darkness: 0.2)
        precondition(root.effect.isHidden)
        precondition(abs((dimming.layer?.backgroundColor?.alpha ?? 0) - 0.2) < 0.001)
        root.update(strength: 0.4, darkness: 0.6)
        precondition(!root.effect.isHidden && abs(root.effect.alphaValue - 0.4) < 0.001)
        precondition(foreground.alphaValue == 1)
        root.update(strength: 5, darkness: -1)
        precondition(root.effect.alphaValue == 1 && dimming.layer?.backgroundColor?.alpha == 0)
        root.update(strength: .nan, darkness: .infinity)
        precondition(abs(root.effect.alphaValue - VIRadioBackdrop.defaultStrength) < 0.001)
        precondition(dimming.layer?.backgroundColor?.alpha == 0)
        root.setFrameSize(NSSize(width: 900, height: 600))
        for view in root.subviews { precondition(view.frame == root.bounds) }
        print("Backdrop separation, live material, dimming and resize checks passed")
    }
}
