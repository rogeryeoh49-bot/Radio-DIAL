import AppKit
import Carbon

struct VIShortcut: Codable, Equatable {
    var keyCode: UInt32 = 12
    var modifiers: UInt32 = UInt32(optionKey)
    var label = "⌥Q"
    static let previous = VIShortcut(keyCode: 50, modifiers: 0, label: "`")
    static let capsLock = VIShortcut(keyCode: 57, modifiers: 0, label: "Caps Lock")
    static let next = VIShortcut(keyCode: 48, modifiers: 0, label: "Tab")
    func sameKey(as other: VIShortcut) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
    static func modifiers(from event: NSEvent) -> UInt32 {
        var value: UInt32 = 0
        if event.modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}


// These bindings apply only in Radio Dial; VI radio has its own global shortcut.
enum AppShortcutAction: String, CaseIterable, Identifiable {
    case playPause, stop, record, volumeUp, volumeDown, mute, mini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .stop: return "Stop"
        case .record: return "Start / Stop Recording"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute / Unmute"
        case .mini: return "Mini Player"
        }
    }
    var defaultKey: VIShortcut {
        switch self {
        case .playPause: return VIShortcut(keyCode: 49, modifiers: 0, label: "Space")
        case .stop: return VIShortcut(keyCode: 47, modifiers: UInt32(cmdKey), label: "⌘.")
        case .record: return VIShortcut(keyCode: 15, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘R")
        case .volumeUp: return VIShortcut(keyCode: 126, modifiers: UInt32(cmdKey), label: "⌘↑")
        case .volumeDown: return VIShortcut(keyCode: 125, modifiers: UInt32(cmdKey), label: "⌘↓")
        case .mute: return VIShortcut(keyCode: 46, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘M")
        case .mini: return VIShortcut(keyCode: 34, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘I")
        }
    }
    func binding(in overrides: [String: VIShortcut]?) -> VIShortcut { overrides?[rawValue] ?? defaultKey }
}

enum AppShortcutRules {
    static func error(for key: VIShortcut, action: AppShortcutAction, overrides: [String: VIShortcut]?, global: VIShortcut) -> String? {
        if key.sameKey(as: global) { return "That combination opens VI radio. Choose another shortcut." }
        if let other = AppShortcutAction.allCases.first(where: { $0 != action && key.sameKey(as: $0.binding(in: overrides)) }) {
            return "Already assigned to \(other.title)."
        }
        if key.modifiers == 0 && [36, 48, 53, 57, 123, 124, 125, 126].contains(key.keyCode) {
            return "Keep this key for navigation. Add a modifier key."
        }
        // Preserve standard editing, app management and existing fixed menu shortcuts.
        if key.modifiers == UInt32(cmdKey), [0, 6, 7, 8, 9, 12, 13, 31, 32, 43, 46, 4].contains(key.keyCode) {
            return "That shortcut is used by a standard menu command."
        }
        if key.keyCode == 3 && key.modifiers == UInt32(cmdKey | controlKey) { return "That shortcut controls full screen." }
        return nil
    }
}

extension VIShortcut {
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }
    var menuKey: String {
        // Unmodified shortcuts are handled by the event monitor so typing stays intact.
        guard modifiers != 0 else { return "" }
        switch keyCode {
        case 36: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default: return label.filter { !"⌃⌥⇧⌘".contains($0) }.lowercased()
        }
    }
}
