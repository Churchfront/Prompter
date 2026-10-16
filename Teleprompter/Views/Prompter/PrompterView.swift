import SwiftUI
import UIKit
import TeleprompterCore

/// Creates the controller once the environment's stores are available.
struct PrompterScreen: View {
    let script: Script
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(ScriptStore.self) private var scriptStore
    @Environment(RemoteHub.self) private var remoteHub
    @State private var controller: PrompterController?

    var body: some View {
        ZStack {
            Color(uiColor: settingsStore.settings.backgroundColor.uiColor).ignoresSafeArea()
            if let controller {
                PrompterView(controller: controller)
            }
        }
        .onAppear {
            if controller == nil {
                let created = PrompterController(script: script, settingsStore: settingsStore, scriptStore: scriptStore)
                controller = created
                remoteHub.attach(created)
            }
        }
        .onDisappear {
            if let controller { remoteHub.detach(controller) }
        }
    }
}

struct PrompterView: View {
    @Bindable var controller: PrompterController
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(RemoteHub.self) private var remoteHub
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// On iPad a sheet is a centered form sheet, and a medium detent squeezes it
    /// to a sliver that hides its controls, so it opens at full form-sheet height.
    /// On iPhone it opens half height so the script stays visible behind it.
    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var sheetDetents: Set<PresentationDetent> { isRegular ? [.large] : [.medium, .large] }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSettings = false
    @State private var showRemote = false

    private var settings: ReaderSettings { settingsStore.settings }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(uiColor: settings.backgroundColor.uiColor).ignoresSafeArea()

                stage

                VStack(spacing: 0) {
                    ProgressStrip(progress: controller.progress, color: settings.highlightColor.color)
                    if controller.controlsVisible {
                        PrompterTopBar(controller: controller,
                                       isCompact: horizontalSizeClass == .compact,
                                       remote: remoteHub,
                                       onClose: close,
                                       onSettings: { showSettings = true },
                                       onRemote: { showRemote = true })
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer(minLength: 0)
                    if let token = controller.resumeCandidate, controller.state == .ready {
                        ResumeBanner(percent: Int(Double(token) / Double(max(controller.tokens.count - 1, 1)) * 100),
                                     onResume: controller.resumeFromLastPosition,
                                     onStartOver: controller.dismissResume)
                            .padding(.horizontal, Signal.Space.s4)
                            .padding(.bottom, Signal.Space.s3)
                    }
                    if controller.controlsVisible {
                        PrompterControls(controller: controller, isCompact: horizontalSizeClass == .compact)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                if case .countingDown(let seconds) = controller.state {
                    CountdownOverlay(seconds: seconds, total: settings.countdownSeconds,
                                     mirror: settings.mirrorHorizontally, flip: settings.flipVertically,
                                     onCancel: controller.pause)
                }

                if controller.isEmpty {
                    EmptyScriptNotice(onClose: close)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.controlsVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            controller.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in controller.handleScenePhase(phase) }
        .onChange(of: settingsStore.settings) { _, _ in controller.settingsDidChange() }
        .onChange(of: remoteHub.closeRequest) { _, _ in close() }
        .sheet(isPresented: $showRemote) {
            NavigationStack { RemoteView() }
                .environment(remoteHub)
                .presentationDetents(sheetDetents)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(context: .prompter) }
                .environment(settingsStore)
                .presentationDetents(sheetDetents)
                .presentationBackgroundInteraction(isRegular ? .enabled : .enabled(upThrough: .medium))
        }
        .sheet(item: $controller.speechIssue) { issue in
            SpeechIssueSheet(issue: issue,
                             onUseTimed: controller.useTimedScrollInstead,
                             onClose: { controller.speechIssue = nil })
                .presentationDetents(isRegular ? [.large] : [.medium])
        }
        .background(KeyCommandBridge(controller: controller))
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("-uitestVoicePlay") {
                try? await Task.sleep(for: .seconds(1))
                controller.setMode(.voiceFollow)
                controller.play()
            }
            if ProcessInfo.processInfo.arguments.contains("-uitestPrompterSettings") {
                try? await Task.sleep(for: .seconds(1))
                showSettings = true
            }
        }
        #endif
    }

    /// Text and reading marker, mirrored or flipped together for beam-splitter glass.
    private var stage: some View {
        ZStack(alignment: .topLeading) {
            PrompterTextView(controller: controller, style: PrompterStyle(settings: settings))
            if settings.showReadingMarker {
                // Measured inside the full-screen stage, the same space the text view uses.
                GeometryReader { geo in
                    let fontLine = settings.prompterFont().lineHeight
                    // Line spacing adds its extra height above the glyphs; aim at the glyphs' center.
                    let glyphCenter = fontLine * (settings.lineSpacing - 1) + fontLine / 2
                    ReadingMarker(color: settings.highlightColor.color)
                        .offset(y: (geo.size.height * settings.readingLine).rounded() + glyphCenter - 12)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .scaleEffect(x: settings.mirrorHorizontally ? -1 : 1, y: settings.flipVertically ? -1 : 1)
        .ignoresSafeArea(edges: .vertical)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Script text")
        .accessibilityHint(settings.tapToPause ? "Tap to play or pause" : "Tap to show or hide controls")
    }

    private func close() {
        controller.close()
        dismiss()
    }
}

// MARK: - Pieces

private struct ProgressStrip: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle().fill(color).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

private struct ReadingMarker: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 14, y: 12))
            path.addLine(to: CGPoint(x: 0, y: 24))
            path.closeSubpath()
        }
        .fill(color)
        .frame(width: 14, height: 24)
        .padding(.leading, 6)
    }
}

private struct PrompterTopBar: View {
    let controller: PrompterController
    let isCompact: Bool
    let remote: RemoteHub
    let onClose: () -> Void
    let onSettings: () -> Void
    let onRemote: () -> Void

    var body: some View {
        HStack(spacing: Signal.Space.s3) {
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.signalQuiet)
            .accessibilityLabel("Close prompter")
            .keyboardShortcut(.cancelAction)

            VStack(alignment: .leading, spacing: 2) {
                if !isCompact {
                    Text(controller.mode.title)
                        .signal(.eyebrow)
                        .foregroundStyle(Signal.accent)
                }
                Text(controller.title)
                    .signal(.subheading)
                    .foregroundStyle(Signal.ink)
                    .lineLimit(1)
            }
            .layoutPriority(-1)

            Spacer(minLength: Signal.Space.s2)

            if controller.mode == .voiceFollow {
                ListeningIndicator(status: controller.tracking, level: controller.micLevel,
                                   onDevice: controller.isOnDeviceRecognition, compact: isCompact)
                    .fixedSize()
            }

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(controller.progress * 100))%")
                    .signal(.mono)
                    .foregroundStyle(Signal.ink)
                Text("\(ReadingTime.format(controller.remaining)) left")
                    .signal(.monoSmall)
                    .foregroundStyle(Signal.inkSubtle)
            }
            .accessibilityElement(children: .combine)

            Button(action: controller.toggleMirror) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(QuietButtonStyle(isSelected: controller.isMirrored))
            .accessibilityLabel("Mirror mode")
            .accessibilityValue(controller.isMirrored ? "On" : "Off")
            .accessibilityHint("Flips the script for beam-splitter glass")

            if remote.isEnabled {
                Button(action: onRemote) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(QuietButtonStyle(isSelected: remote.remoteCount + remote.displayCount > 0))
                .accessibilityLabel("Phone remote and iPad display")
                .accessibilityValue("\(remote.remoteCount) remote, \(remote.displayCount) display connected")
            }

            Button(action: onSettings) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17, weight: .semibold))
            }
            .buttonStyle(.signalQuiet)
            .accessibilityLabel("Reading settings")
        }
        .padding(.horizontal, Signal.Space.s3)
        .padding(.vertical, Signal.Space.s2)
        .background(Signal.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Signal.line).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }
}

/// Subtle microphone indicator. Always a word and an icon, never color alone.
private struct ListeningIndicator: View {
    let status: TrackingStatus
    let level: Double
    let onDevice: Bool
    var compact = false

    var body: some View {
        HStack(spacing: Signal.Space.s2) {
            LevelBars(level: status == .following || status == .waiting ? level : 0, color: tint)
            Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            if !compact {
                Text(label)
                    .signal(.label)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Signal.Space.s2)
        .frame(minHeight: 28)
        .background(RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(Signal.surfaceRaised))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Voice follow: \(label)")
        .accessibilityValue(onDevice ? "Recognition on device" : "")
    }

    private var label: String {
        switch status {
        case .off: "Mic off"
        case .starting: "Starting"
        case .following: "Following"
        case .waiting: "Listening"
        case .findingPlace: "Finding place"
        case .unavailable: "Mic unavailable"
        }
    }

    private var icon: String {
        switch status {
        case .off: "mic.slash"
        case .starting, .waiting: "mic"
        case .following: "waveform"
        case .findingPlace: "magnifyingglass"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status {
        case .following: Signal.success
        case .waiting, .starting: Signal.inkMuted
        case .findingPlace: Signal.warning
        case .unavailable: Signal.danger
        case .off: Signal.inkSubtle
        }
    }
}

private struct LevelBars: View {
    let level: Double
    let color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                let threshold = Double(i) / 4
                RoundedRectangle(cornerRadius: Signal.Radius.xs)
                    .fill(level > threshold ? color : color.opacity(0.25))
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

private struct PrompterControls: View {
    @Bindable var controller: PrompterController
    let isCompact: Bool
    @Environment(SettingsStore.self) private var settingsStore

    var body: some View {
        VStack(spacing: Signal.Space.s3) {
            if controller.mode == .timed {
                speedRow
            }
            HStack(spacing: Signal.Space.s2) {
                ModeSwitch(mode: controller.mode, compact: isCompact) { controller.setMode($0) }
                Spacer(minLength: 0)
                Button(action: controller.rewind) {
                    Image(systemName: "backward.end.fill").font(.system(size: 18))
                }
                .buttonStyle(.signalQuiet)
                .accessibilityLabel("Back one sentence")

                Button(action: controller.togglePlay) {
                    Label(controller.state.isRunning ? "Pause" : "Play",
                          systemImage: controller.state.isRunning ? "pause.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: isCompact ? 72 : 96)
                }
                .buttonStyle(PrimaryButtonStyle(height: 52))
                .disabled(controller.isEmpty)

                Button(action: controller.skipForward) {
                    Image(systemName: "forward.end.fill").font(.system(size: 18))
                }
                .buttonStyle(.signalQuiet)
                .accessibilityLabel("Ahead one sentence")
                Spacer(minLength: 0)
                Button(action: controller.restart) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.signalQuiet)
                .accessibilityLabel("Restart from the beginning")
                .keyboardShortcut("r", modifiers: [.command])
            }
        }
        .padding(.horizontal, Signal.Space.s4)
        .padding(.top, Signal.Space.s3)
        .padding(.bottom, Signal.Space.s3)
        .background(Signal.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Signal.line).frame(height: 1) }
        .environment(\.colorScheme, .dark)
    }

    private var speedRow: some View {
        @Bindable var store = settingsStore
        return HStack(spacing: Signal.Space.s3) {
            Button { controller.adjustSpeed(by: -10) } label: {
                Image(systemName: "minus").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.signalQuiet)
            .accessibilityLabel("Slower")

            Slider(value: $store.settings.wordsPerMinute, in: ReaderSettings.wordsPerMinuteRange, step: 5) { editing in
                if editing { controller.noteInteraction() }
            }
            .tint(Signal.accent)
            .accessibilityLabel("Scroll speed")
            .accessibilityValue("\(Int(settingsStore.settings.wordsPerMinute)) words per minute")

            Button { controller.adjustSpeed(by: 10) } label: {
                Image(systemName: "plus").font(.system(size: 16, weight: .semibold))
            }
            .buttonStyle(.signalQuiet)
            .accessibilityLabel("Faster")

            Text("\(Int(settingsStore.settings.wordsPerMinute)) WPM")
                .signal(.mono)
                .foregroundStyle(Signal.ink)
                .frame(minWidth: 72, alignment: .trailing)
        }
    }
}

private struct ModeSwitch: View {
    let mode: PrompterMode
    let compact: Bool
    let onSelect: (PrompterMode) -> Void

    var body: some View {
        if compact {
            Button { onSelect(mode == .voiceFollow ? .timed : .voiceFollow) } label: {
                Image(systemName: mode.systemImage).font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(QuietButtonStyle(size: 44, isSelected: true))
            .accessibilityLabel("Mode: \(mode.title)")
            .accessibilityHint("Switches to \(mode == .voiceFollow ? PrompterMode.timed.title : PrompterMode.voiceFollow.title)")
        } else {
            segmented
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            ForEach(PrompterMode.allCases) { option in
                Button { onSelect(option) } label: {
                    HStack(spacing: Signal.Space.s1) {
                        Image(systemName: option.systemImage)
                        if !compact { Text(option.shortTitle).signal(.label) }
                    }
                    .padding(.horizontal, compact ? 0 : Signal.Space.s2)
                }
                .buttonStyle(QuietButtonStyle(size: 40, isSelected: option == mode))
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(option == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Signal.Radius.sm + 2).fill(Signal.surfaceSunken))
    }
}

private struct CountdownOverlay: View {
    let seconds: Int
    let total: Int
    /// The dial reads through the same glass as the script, so it follows its mirror and flip.
    let mirror: Bool
    let flip: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Signal.scrim.ignoresSafeArea()
            VStack(spacing: Signal.Space.s4) {
                ZStack {
                    Circle().stroke(Signal.line, lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(seconds) / CGFloat(max(total, 1)))
                        .stroke(Signal.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.9), value: seconds)
                    Text("\(seconds)")
                        .font(Font(SignalFont.figtree(size: 88, weight: 700)))
                        .monospacedDigit()
                        .foregroundStyle(Signal.ink)
                        .contentTransition(.numericText(countsDown: true))
                }
                .frame(width: 180, height: 180)
                .scaleEffect(x: mirror ? -1 : 1, y: flip ? -1 : 1)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.signalSecondary)
            }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Starting in \(seconds)")
    }
}

private struct ResumeBanner: View {
    let percent: Int
    let onResume: () -> Void
    let onStartOver: () -> Void

    var body: some View {
        HStack(spacing: Signal.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pick up where you left off").signal(.subheading).foregroundStyle(Signal.ink)
                Text("You stopped at \(percent)% last time.").signal(.bodySmall).foregroundStyle(Signal.inkMuted)
            }
            Spacer(minLength: Signal.Space.s2)
            Button("Start over", action: onStartOver).buttonStyle(.signalQuiet)
            Button("Resume", action: onResume).buttonStyle(.signalSecondary)
        }
        .padding(Signal.Space.s4)
        .background(RoundedRectangle(cornerRadius: Signal.Radius.md).fill(Signal.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: Signal.Radius.md).strokeBorder(Signal.line))
        .environment(\.colorScheme, .dark)
    }
}

private struct EmptyScriptNotice: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Signal.Space.s4) {
            Text("Nothing to read yet").signal(.heading).foregroundStyle(Signal.ink)
            Text("This script is empty. Add text in the editor, then come back to start.")
                .signal(.bodyLarge)
                .foregroundStyle(Signal.inkMuted)
                .multilineTextAlignment(.center)
            Button("Back to editor", action: onClose).buttonStyle(.signalSecondary)
        }
        .padding(Signal.Space.s8)
        .frame(maxWidth: 420)
        .environment(\.colorScheme, .dark)
    }
}

extension SpeechIssue: Identifiable {
    var id: String { title }
}

/// Explains why Voice Follow cannot listen and offers the way forward.
struct SpeechIssueSheet: View {
    let issue: SpeechIssue
    let onUseTimed: () -> Void
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Signal.Space.s4) {
            Text("Voice Follow").signal(.eyebrow).foregroundStyle(Signal.accent)
            Text(issue.title).signal(.heading).foregroundStyle(Signal.ink)
            Text(issue.message).signal(.bodyLarge).foregroundStyle(Signal.inkMuted)
            if issue.canOpenSettings {
                Text("Settings > CuePrompter > \(issue == .microphoneDenied ? "Microphone" : "Speech Recognition")")
                    .signal(.mono)
                    .foregroundStyle(Signal.ink)
                    .padding(Signal.Space.s3)
                    .background(RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(Signal.surfaceSunken))
            }
            Spacer(minLength: 0)
            HStack(spacing: Signal.Space.s3) {
                if issue.canOpenSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.signalSecondary)
                }
                Button("Use Timed Scroll") {
                    onUseTimed()
                }
                .buttonStyle(.signalPrimary)
                Spacer(minLength: 0)
            }
        }
        .padding(Signal.Space.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Signal.surface.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onDisappear(perform: onClose)
    }
}

/// Hardware keyboard and presentation remote support. Most remotes send
/// arrow or page keys; these work even when the on-screen controls are hidden.
private struct KeyCommandBridge: UIViewControllerRepresentable {
    let controller: PrompterController

    func makeUIViewController(context: Context) -> KeyCommandController {
        let vc = KeyCommandController()
        vc.controller = controller
        return vc
    }

    func updateUIViewController(_ vc: KeyCommandController, context: Context) {
        vc.controller = controller
    }

    final class KeyCommandController: UIViewController {
        weak var controller: PrompterController?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: " ", modifierFlags: [], action: #selector(toggle)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(toggle)),
                UIKeyCommand(input: "b", modifierFlags: [], action: #selector(toggle)),
                UIKeyCommand(input: "m", modifierFlags: [], action: #selector(mirror)),
                UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(nextSentence)),
                UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(nextSentence)),
                UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(previousSentence)),
                UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(previousSentence)),
                UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(faster)),
                UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(slower))
            ].map { command in
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }

        @objc private func nextSentence() { controller?.skipForward() }
        @objc private func previousSentence() { controller?.rewind() }
        @objc private func toggle() { controller?.togglePlay() }
        @objc private func faster() { controller?.adjustSpeed(by: 10) }
        @objc private func slower() { controller?.adjustSpeed(by: -10) }
        @objc private func mirror() { controller?.toggleMirror() }
    }
}
