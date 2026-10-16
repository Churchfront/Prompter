import SwiftUI
import UIKit

/// Mac-only window behavior. Does nothing on iPhone and iPad.
enum MacWindow {
    /// Keeps Prompter in the background when a link opens it (Send to Teleprompter
    /// in the browser): the app hides, so the browser stays in front, and it keeps
    /// running. Clicking Prompter in the Dock shows it again. macOS ignores a plain
    /// deactivate here, so this hides. Repeated briefly, because a cold launch
    /// brings the app forward again as its window appears.
    static func stayBehind() {
        #if targetEnvironment(macCatalyst)
        guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject
        else { return }
        let hide = NSSelectorFromString("hide:")
        guard app.responds(to: hide) else { return }
        for delay in [0.0, 0.4, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { _ = app.perform(hide, with: nil) }
        }
        #endif
    }
}

/// Removes the line macOS draws under the window's title bar. Prompter's own bars
/// run up into the title bar area, so the line otherwise cuts through them.
struct HideTitlebarSeparator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    private final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            #if targetEnvironment(macCatalyst)
            window?.windowScene?.titlebar?.separatorStyle = .none
            #endif
        }
    }
}
