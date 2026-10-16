import SwiftUI

@main
struct TeleprompterApp: App {
    @State private var scriptStore: ScriptStore
    @State private var settingsStore: SettingsStore
    @State private var remoteHub: RemoteHub

    init() {
        SignalFont.register()
        let scripts = ScriptStore()
        let settings = SettingsStore()
        _scriptStore = State(initialValue: scripts)
        _settingsStore = State(initialValue: settings)
        _remoteHub = State(initialValue: RemoteHub(scriptStore: scripts, settingsStore: settings))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(scriptStore)
                .environment(settingsStore)
                .environment(remoteHub)
                .tint(Signal.accent)
                .preferredColorScheme(settingsStore.settings.appearance.colorScheme)
                // prompter://send, from the portal's Send to Teleprompter: open
                // CuePrompter with the phone remote and display ports on.
                .onOpenURL { url in
                    if url.host == "send" { remoteHub.isEnabled = true }
                }
        }
    }
}
