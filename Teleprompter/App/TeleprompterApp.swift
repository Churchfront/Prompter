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
                .onOpenURL { remoteHub.handleOpenURL($0) }
                // A prompter:// link goes to the open window instead of opening another one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
    }
}
