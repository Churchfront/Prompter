import UIKit
import SwiftUI
import TeleprompterCore

// Voice commands in the real controller: simulated recognizer transcripts go in
// the way SpeechRecognizer delivers them (partial results that grow), with the
// microphone held off so no permission prompt appears.

extension Harness {
    /// Speaks a phrase into the controller one word per partial result.
    func say(_ text: String, to controller: PrompterController, generation: Int, step: Double = 0.12) async {
        let words = text.split(separator: " ")
        for n in 1...words.count {
            controller.handleTranscript(TranscriptUpdate(text: words.prefix(n).joined(separator: " "),
                                                         generation: generation, isFinal: false))
            await wait(step)
        }
    }

    func voiceCommands() async {
        let paragraphs = (1...6).map { "Paragraph \($0) begins here. It has a second sentence with more words. And a third one to finish it." }
        let (controller, hosting, _, settingsStore, _) = makePrompter(body: paragraphs.joined(separator: "\n\n"), settings: {
            $0.mode = .timed
            $0.countdownSeconds = 0
            $0.wordsPerMinute = 140
            $0.autoHideControls = false
            $0.voiceCommands = true
        }, size: CGSize(width: 1024, height: 768), compact: false)
        await wait(0.6)
        let starts = controller.tokens.paragraphStarts
        let token = { Int(controller.readingPosition.rounded()) }
        var generation = 1

        await say("teleprompter next paragraph", to: controller, generation: generation)
        await wait(1.2)
        check("\"Teleprompter, next paragraph\" moves to paragraph 2", token() == starts[1], "word \(token()), paragraph 2 starts at \(starts[1])")
        check("The command is confirmed on screen", controller.heardCommand?.text == "Ahead 1 paragraph", controller.heardCommand?.text ?? "nothing")

        generation += 1
        await say("teleprompter skip ahead two paragraphs", to: controller, generation: generation)
        await wait(1.2)
        check("\"skip ahead two paragraphs\" waits for the whole phrase", token() == starts[3], "word \(token()), expected \(starts[3])")

        generation += 1
        await say("teleprompter go back one paragraph", to: controller, generation: generation)
        await wait(1.2)
        check("\"go back one paragraph\" from a paragraph start goes to the one before", token() == starts[2], "word \(token()), expected \(starts[2])")
        check("\"go\" did not start playback on the way", controller.state != .playing)

        let wpm = settingsStore.settings.wordsPerMinute
        generation += 1
        await say("teleprompter speed up 5 words per minute", to: controller, generation: generation)
        await wait(1.0)
        check("\"speed up 5 words per minute\"", settingsStore.settings.wordsPerMinute == wpm + 5, "\(settingsStore.settings.wordsPerMinute) WPM")

        generation += 1
        await say("teleprompter go", to: controller, generation: generation)
        check("A lone \"go\" waits a moment", controller.state != .playing)
        await wait(1.0)
        check("then plays", controller.state == .playing)

        generation += 1
        await say("teleprompter pause", to: controller, generation: generation)
        await wait(0.1)
        check("\"pause\" acts right away", controller.state == .paused)

        let before = token()
        generation += 1
        await say("and our teleprompter is ready for the service", to: controller, generation: generation)
        await wait(1.0)
        check("Script speech that mentions the teleprompter does nothing", token() == before && controller.state == .paused)

        settingsStore.settings.voiceCommands = false
        controller.settingsDidChange()
        generation += 1
        await say("teleprompter next paragraph", to: controller, generation: generation)
        await wait(1.0)
        check("With commands off, nothing is heard", token() == before)

        // The phone remote's toggle.
        let hub = RemoteHub(scriptStore: ScriptStore(directory: freshDirectory(), defaults: freshDefaults()),
                            settingsStore: settingsStore, defaults: freshDefaults())
        hub.attach(controller)
        hub.perform(RemoteCommand(action: "voiceCommands", value: 1))
        check("Phone remote turns voice commands on", settingsStore.settings.voiceCommands && hub.statePayload().voiceCommands)
        await say("teleprompter mirror on", to: controller, generation: generation + 1)
        await wait(0.2)
        check("Remote state reports the heard command", hub.statePayload().heard?.text == "Mirror on" && settingsStore.settings.mirrorHorizontally)
        hub.perform(RemoteCommand(action: "voiceCommands", value: 0))
        check("Phone remote turns voice commands off", !settingsStore.settings.voiceCommands && !hub.statePayload().voiceCommands)
        snapshot(hosting.view, "prompter-voice-command")
        hub.detach(controller)
        controller.close()
    }
}
