import SwiftUI

@main
struct TeleprompterApp: App {
    @State private var scriptStore: ScriptStore
    @State private var settingsStore: SettingsStore

    init() {
        SignalFont.register()
        _scriptStore = State(initialValue: ScriptStore())
        _settingsStore = State(initialValue: SettingsStore())
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(scriptStore)
                .environment(settingsStore)
                .tint(Signal.accent)
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
        }
    }
}
