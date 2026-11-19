import SwiftUI

struct ShortcutSettings: View {
    @ObservedObject var dial: DialState
    @State private var error = ""

    private func save(_ key: VIShortcut, for action: AppShortcutAction) {
        if let message = AppShortcutRules.error(for: key, action: action, overrides: dial.prefs.shortcuts, global: dial.prefs.viShortcut ?? VIShortcut()) {
            error = message
            return
        }
        var bindings = dial.prefs.shortcuts ?? [:]
        if key.sameKey(as: action.defaultKey) { bindings.removeValue(forKey: action.rawValue) }
        else { bindings[action.rawValue] = key }
        dial.prefs.shortcuts = bindings.isEmpty ? nil : bindings
        error = ""
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(AppShortcutAction.allCases) { action in
                    HStack {
                        Text(action.title).frame(maxWidth: .infinity, alignment: .leading)
                        VIShortcutRecorder(shortcut: Binding(get: { action.binding(in: dial.prefs.shortcuts) }, set: { save($0, for: action) }), applicationShortcut: true)
                            .frame(width: 145, height: 27)
                            .accessibilityLabel("Change \(action.title) shortcut")
                        Button("Reset") { save(action.defaultKey, for: action) }
                            .accessibilityLabel("Reset \(action.title) shortcut")
                    }
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Text("Click a shortcut to change it. Applies while Radio Dial is active.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") { dial.prefs.shortcuts = nil; error = "" }
                }
            }.padding(14)
        }
    }
}
