import AppKit
import Carbon
@main struct Test {
    static func main() {
        let defaults = AppShortcutAction.allCases.map { $0.binding(in: nil) }
        for (index, key) in defaults.enumerated() {
            precondition(!defaults.prefix(index).contains(where: { $0.sameKey(as: key) }))
        }
        precondition(AppShortcutAction.playPause.binding(in: nil).keyCode == 49)
        let custom = VIShortcut(keyCode: 35, modifiers: UInt32(cmdKey), label: "⌘P")
        let overrides = [AppShortcutAction.playPause.rawValue: custom]
        precondition(AppShortcutAction.playPause.binding(in: overrides).sameKey(as: custom))
        precondition(AppShortcutRules.error(for: custom, action: .mute, overrides: overrides, global: VIShortcut()) != nil)
        precondition(AppShortcutRules.error(for: VIShortcut(), action: .playPause, overrides: nil, global: VIShortcut()) != nil)
        precondition(AppShortcutRules.error(for: VIShortcut(keyCode: 12, modifiers: UInt32(cmdKey), label: "⌘Q"), action: .stop, overrides: nil, global: VIShortcut()) != nil)
        precondition(AppShortcutRules.error(for: custom, action: .playPause, overrides: nil, global: VIShortcut()) == nil)
        precondition(AppShortcutAction.playPause.defaultKey.menuKey.isEmpty)
        precondition(custom.menuKey == "p" && custom.eventModifiers == .command)
        let stored = try! JSONEncoder().encode(overrides)
        precondition(try! JSONDecoder().decode([String: VIShortcut].self, from: stored) == overrides)
        print("Shortcut defaults, overrides, conflicts, menu equivalents and persistence passed")
    }
}
