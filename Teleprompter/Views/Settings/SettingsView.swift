import SwiftUI
import UIKit
import Speech

/// Reading preferences. Opened from the library (all settings) or over the
/// prompter (applies live, while the script keeps its place).
struct SettingsView: View {
    enum Context { case library, prompter }
    let context: Context

    @Environment(SettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                SettingsPreview(settings: store.settings)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if context == .library {
                Section {
                    Picker("Default mode", selection: $store.settings.mode) {
                        ForEach(PrompterMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Appearance", selection: $store.settings.appearance) {
                        ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    SectionHeader("General")
                } footer: {
                    Text("Voice Follow moves the script as you speak. Timed Scroll moves at a steady speed.")
                }
            }

            Section {
                Picker("Typeface", selection: $store.settings.typeface) {
                    ForEach(PrompterTypeface.allCases) { Text($0.title).tag($0) }
                }
                Picker("Weight", selection: $store.settings.weight) {
                    ForEach(PrompterWeight.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Size", value: $store.settings.fontSize, range: ReaderSettings.fontSizeRange,
                          step: 2, format: { "\(Int($0)) pt" })
                SliderRow(title: "Line spacing", value: $store.settings.lineSpacing,
                          range: ReaderSettings.lineSpacingRange, step: 0.05,
                          format: { String(format: "%.2f×", $0) })
                Picker("Alignment", selection: $store.settings.alignment) {
                    ForEach(PrompterAlignment.allCases) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Side margins", value: $store.settings.horizontalMargin,
                          range: ReaderSettings.marginRange, step: 0.01,
                          format: { "\(Int($0 * 100))%" })
            } header: {
                SectionHeader("Text")
            }

            Section {
                SliderRow(title: "Reading line", value: $store.settings.readingLine,
                          range: ReaderSettings.readingLineRange, step: 0.01,
                          format: { "\(Int($0 * 100))% from top" })
                Toggle("Show reading marker", isOn: $store.settings.showReadingMarker)
                Picker("Highlight", selection: $store.settings.highlightMode) {
                    ForEach(HighlightMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Dim text already read", isOn: $store.settings.dimReadText)
            } header: {
                SectionHeader("Position and highlight")
            } footer: {
                Text("A higher reading line shows more upcoming text below it.")
            }

            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Signal.Space.s3) {
                        ForEach(ColorPreset.all) { preset in
                            PresetSwatch(preset: preset, isSelected: store.settings.matchingPreset == preset) {
                                store.settings.apply(preset)
                            }
                        }
                    }
                    .padding(.vertical, Signal.Space.s1)
                }
                ColorPicker("Text", selection: colorBinding(\.textColor), supportsOpacity: false)
                ColorPicker("Background", selection: colorBinding(\.backgroundColor), supportsOpacity: false)
                ColorPicker("Highlight", selection: colorBinding(\.highlightColor), supportsOpacity: false)
            } header: {
                SectionHeader("Colors")
            }

            Section {
                SliderRow(title: "Pause grace", value: $store.settings.pauseGrace,
                          range: ReaderSettings.pauseGraceRange, step: 0.1,
                          format: { String(format: "%.1f s", $0) })
                SliderRow(title: "Matching tolerance", value: $store.settings.matchTolerance,
                          range: 0...1, step: 0.05,
                          format: { $0 < 0.34 ? "Strict" : $0 > 0.66 ? "Lenient" : "Balanced" })
                Toggle("Prefer on-device recognition", isOn: $store.settings.preferOnDeviceRecognition)
            } header: {
                SectionHeader("Voice Follow")
            } footer: {
                Text("Pause grace is how long the text keeps gliding after you stop speaking. Use a lenient tolerance for strong accents or noisy rooms, strict to avoid false moves. On-device recognition keeps speech on this device and has no time limit; the text is never stored.")
            }

            Section {
                SliderRow(title: "Speed", value: $store.settings.wordsPerMinute,
                          range: ReaderSettings.wordsPerMinuteRange, step: 5,
                          format: { "\(Int($0)) WPM" })
            } header: {
                SectionHeader("Timed Scroll")
            } footer: {
                Text("Most people read aloud between 130 and 160 words per minute.")
            }

            Section {
                Stepper(value: $store.settings.countdownSeconds, in: ReaderSettings.countdownRange) {
                    HStack {
                        Text("Countdown")
                        Spacer()
                        Text(store.settings.countdownSeconds == 0 ? "Off" : "\(store.settings.countdownSeconds) s")
                            .signal(.mono)
                            .foregroundStyle(Signal.inkMuted)
                    }
                }
                Toggle("Tap text to pause", isOn: $store.settings.tapToPause)
                Toggle("Hide controls while playing", isOn: $store.settings.autoHideControls)
            } header: {
                SectionHeader("Playback")
            }

            Section {
                Toggle("Voice commands", isOn: $store.settings.voiceCommands)
            } header: {
                SectionHeader("Voice commands")
            } footer: {
                Text("Say \u{201C}Teleprompter\u{201D} and then a command: \u{201C}go back one paragraph\u{201D}, \u{201C}next sentence\u{201D}, \u{201C}start over\u{201D}, \u{201C}pause\u{201D}, \u{201C}play\u{201D}, \u{201C}speed up 5 words per minute\u{201D}, \u{201C}set speed to 150\u{201D}, \u{201C}bigger text\u{201D}, \u{201C}mirror\u{201D}, \u{201C}switch to timed\u{201D}. The microphone stays on while the prompter is open, in both modes and while paused. Audio is never recorded.")
            }

            Section {
                Toggle("Mirror horizontally", isOn: $store.settings.mirrorHorizontally)
                Toggle("Flip vertically", isOn: $store.settings.flipVertically)
            } header: {
                SectionHeader("Mirror")
            } footer: {
                Text("For beam-splitter glass. Mirror horizontally so the reflection reads correctly; flip vertically if your rig mounts the display upside down.")
            }

            if context == .library {
                Section {
                    PermissionStatusRow()
                } header: {
                    SectionHeader("Permissions")
                }
            }

            Section {
                Button("Reset reading settings", role: .destructive) { confirmReset = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Signal.bg.ignoresSafeArea())
        .tint(Signal.accent)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Reset all reading settings?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset settings", role: .destructive) { store.resetToDefaults() }
        } message: {
            Text("Scripts are not affected.")
        }
    }

    private func colorBinding(_ keyPath: WritableKeyPath<ReaderSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: { store.settings[keyPath: keyPath].color },
            set: { store.settings[keyPath: keyPath] = RGBAColor($0) }
        )
    }
}

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).signal(.eyebrow).foregroundStyle(Signal.inkSubtle)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: Signal.Space.s1) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).signal(.mono).foregroundStyle(Signal.inkMuted)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
        }
    }
}

private struct PresetSwatch: View {
    let preset: ColorPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Signal.Space.s1) {
                Text("Aa")
                    .font(Font(SignalFont.figtree(size: 22, weight: 600)))
                    .foregroundStyle(preset.text.color)
                    .frame(width: 72, height: 48)
                    .background(RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(preset.background.color))
                    .overlay(
                        RoundedRectangle(cornerRadius: Signal.Radius.sm)
                            .strokeBorder(isSelected ? Signal.accent : Signal.line, lineWidth: isSelected ? 2 : 1)
                    )
                Text(preset.name).signal(.bodySmall).foregroundStyle(Signal.inkMuted)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name) colors")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A few lines styled exactly like the prompter.
private struct SettingsPreview: View {
    let settings: ReaderSettings

    var body: some View {
        let size = min(settings.fontSize, 40)
        let font = settings.prompterFont(size: size)
        VStack(alignment: horizontalAlignment, spacing: 0) {
            (Text("Read slowly, and it waits for you. ").foregroundColor(settings.textColor.color.opacity(settings.dimReadText ? 0.4 : 1))
             + Text("Read quickly,").foregroundColor(settings.highlightMode == .off ? settings.textColor.color : settings.highlightColor.color)
             + Text(" and it keeps up.").foregroundColor(settings.textColor.color))
                .font(Font(font))
                .lineSpacing(CGFloat(size) * (settings.lineSpacing - 1) + 2)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
        .padding(.vertical, Signal.Space.s5)
        .padding(.horizontal, Signal.Space.s4 + 200 * settings.horizontalMargin)
        .background(RoundedRectangle(cornerRadius: Signal.Radius.md).fill(settings.backgroundColor.color))
        .scaleEffect(x: settings.mirrorHorizontally ? -1 : 1, y: settings.flipVertically ? -1 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the prompter text")
    }

    private var textAlignment: TextAlignment {
        switch settings.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch settings.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch settings.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Shows whether Voice Follow can listen, without prompting.
private struct PermissionStatusRow: View {
    @Environment(\.openURL) private var openURL
    @State private var status: SpeechAuthorization = .notDetermined

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphone and speech recognition")
                Text(description).signal(.bodySmall).foregroundStyle(Signal.inkMuted)
            }
            Spacer()
            switch status {
            case .authorized:
                StatusBadge(text: "On", systemImage: "checkmark", tone: .success)
            case .notDetermined:
                StatusBadge(text: "Not asked", systemImage: "questionmark", tone: .neutral)
            case .denied:
                Button("Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(SecondaryButtonStyle(height: Signal.Control.md))
            }
        }
        .onAppear { status = SpeechRecognizer.authorization() }
    }

    private var description: String {
        switch status {
        case .authorized: "Voice Follow is ready."
        case .notDetermined: "You will be asked the first time you use Voice Follow."
        case .denied(let issue): issue.title
        }
    }
}
