import SwiftUI
import UIKit

enum PrompterMode: String, Codable, CaseIterable, Identifiable {
    case voiceFollow
    case timed

    var id: String { rawValue }
    var title: String { self == .voiceFollow ? "Voice Follow" : "Timed Scroll" }
    var shortTitle: String { self == .voiceFollow ? "Voice" : "Timed" }
    var systemImage: String { self == .voiceFollow ? "waveform" : "timer" }
}

enum PrompterTypeface: String, Codable, CaseIterable, Identifiable {
    case figtree, system, rounded, serif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .figtree: "Figtree"
        case .system: "SF Pro"
        case .rounded: "SF Rounded"
        case .serif: "New York"
        }
    }
}

enum PrompterWeight: String, Codable, CaseIterable, Identifiable {
    case regular, medium, semibold, bold
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var value: CGFloat {
        switch self {
        case .regular: 400
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        }
    }
}

enum PrompterAlignment: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String { self == .leading ? "Left" : self == .center ? "Center" : "Right" }
    var systemImage: String {
        switch self {
        case .leading: "text.alignleft"
        case .center: "text.aligncenter"
        case .trailing: "text.alignright"
        }
    }
    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }
}

enum HighlightMode: String, Codable, CaseIterable, Identifiable {
    case off, word, phrase, sentence
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum AppearancePreference: String, Codable, CaseIterable, Identifiable {
    case dark, light, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

/// Color stored as sRGB components so it survives encoding.
struct RGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(hex: UInt32, alpha: Double = 1) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
        self.alpha = alpha
    }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        red = Double(r); green = Double(g); blue = Double(b); alpha = Double(a)
    }

    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(uiColor: uiColor) }
}

/// A named text and background pairing for the prompter stage.
struct ColorPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let text: RGBAColor
    let background: RGBAColor
    let highlight: RGBAColor

    static let all: [ColorPreset] = [
        ColorPreset(id: "midnight", name: "Midnight",
                    text: RGBAColor(hex: Signal.greyHex), background: RGBAColor(hex: Signal.midnightHex),
                    highlight: RGBAColor(hex: Signal.refreshHex)),
        ColorPreset(id: "black", name: "Studio black",
                    text: RGBAColor(hex: 0xFFFFFF), background: RGBAColor(hex: 0x000000),
                    highlight: RGBAColor(hex: Signal.refreshHex)),
        ColorPreset(id: "grey", name: "Grey",
                    text: RGBAColor(hex: Signal.midnightHex), background: RGBAColor(hex: Signal.greyHex),
                    highlight: RGBAColor(hex: 0x155C8F)),
        ColorPreset(id: "amber", name: "Low light",
                    text: RGBAColor(hex: 0xF2B84B), background: RGBAColor(hex: 0x000000),
                    highlight: RGBAColor(hex: 0xFFFFFF))
    ]
}

/// Every reader preference. Remembered between sessions by `SettingsStore`.
/// Decoding falls back to defaults for missing or unknown values, so adding a
/// setting in a later version never wipes the reader's existing preferences.
struct ReaderSettings: Codable, Equatable {
    // Mode
    var mode: PrompterMode = .voiceFollow
    var appearance: AppearancePreference = .dark

    // Text
    var typeface: PrompterTypeface = .figtree
    var weight: PrompterWeight = .semibold
    var fontSize: Double = 44
    var lineSpacing: Double = 1.3
    var alignment: PrompterAlignment = .leading
    /// Side margin as a fraction of the screen width.
    var horizontalMargin: Double = 0.07
    /// Reading line position as a fraction of the screen height. Lower values
    /// show more upcoming text below the line.
    var readingLine: Double = 0.3
    var showReadingMarker = true

    // Colors
    var textColor = RGBAColor(hex: Signal.greyHex)
    var backgroundColor = RGBAColor(hex: Signal.midnightHex)
    var highlightColor = RGBAColor(hex: Signal.refreshHex)

    // Voice follow
    var highlightMode: HighlightMode = .phrase
    var dimReadText = true
    /// Seconds the text keeps gliding after the last recognized word.
    var pauseGrace: Double = 1.2
    /// 0 strict ... 1 lenient.
    var matchTolerance: Double = 0.5
    var preferOnDeviceRecognition = true

    // Timed scroll
    var wordsPerMinute: Double = 140

    // Playback
    var countdownSeconds: Int = 3
    var tapToPause = true
    var autoHideControls = true
    /// Listen for "Teleprompter, ..." commands while the prompter is open.
    var voiceCommands = false

    // Mirror
    var mirrorHorizontally = false
    var flipVertically = false

    static let fontSizeRange: ClosedRange<Double> = 20...140
    static let lineSpacingRange: ClosedRange<Double> = 1.0...2.2
    static let marginRange: ClosedRange<Double> = 0...0.3
    static let readingLineRange: ClosedRange<Double> = 0.12...0.6
    static let wordsPerMinuteRange: ClosedRange<Double> = 40...320
    static let countdownRange: ClosedRange<Int> = 0...10
    static let pauseGraceRange: ClosedRange<Double> = 0.3...3.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ReaderSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        mode = value(.mode, d.mode)
        appearance = value(.appearance, d.appearance)
        typeface = value(.typeface, d.typeface)
        weight = value(.weight, d.weight)
        fontSize = value(.fontSize, d.fontSize).clamped(to: Self.fontSizeRange)
        lineSpacing = value(.lineSpacing, d.lineSpacing).clamped(to: Self.lineSpacingRange)
        alignment = value(.alignment, d.alignment)
        horizontalMargin = value(.horizontalMargin, d.horizontalMargin).clamped(to: Self.marginRange)
        readingLine = value(.readingLine, d.readingLine).clamped(to: Self.readingLineRange)
        showReadingMarker = value(.showReadingMarker, d.showReadingMarker)
        textColor = value(.textColor, d.textColor)
        backgroundColor = value(.backgroundColor, d.backgroundColor)
        highlightColor = value(.highlightColor, d.highlightColor)
        highlightMode = value(.highlightMode, d.highlightMode)
        dimReadText = value(.dimReadText, d.dimReadText)
        pauseGrace = value(.pauseGrace, d.pauseGrace).clamped(to: Self.pauseGraceRange)
        matchTolerance = value(.matchTolerance, d.matchTolerance).clamped(to: 0...1)
        preferOnDeviceRecognition = value(.preferOnDeviceRecognition, d.preferOnDeviceRecognition)
        wordsPerMinute = value(.wordsPerMinute, d.wordsPerMinute).clamped(to: Self.wordsPerMinuteRange)
        countdownSeconds = min(max(value(.countdownSeconds, d.countdownSeconds), 0), 10)
        tapToPause = value(.tapToPause, d.tapToPause)
        autoHideControls = value(.autoHideControls, d.autoHideControls)
        voiceCommands = value(.voiceCommands, d.voiceCommands)
        mirrorHorizontally = value(.mirrorHorizontally, d.mirrorHorizontally)
        flipVertically = value(.flipVertically, d.flipVertically)
    }

    mutating func apply(_ preset: ColorPreset) {
        textColor = preset.text
        backgroundColor = preset.background
        highlightColor = preset.highlight
    }

    var matchingPreset: ColorPreset? {
        ColorPreset.all.first { $0.text == textColor && $0.background == backgroundColor && $0.highlight == highlightColor }
    }

    /// Base font for the prompter text.
    func prompterFont(size: Double? = nil) -> UIFont {
        let pointSize = CGFloat(size ?? fontSize)
        switch typeface {
        case .figtree:
            return SignalFont.figtree(size: pointSize, weight: weight.value)
        case .system, .rounded, .serif:
            let base = UIFont.systemFont(ofSize: pointSize, weight: SignalFont.systemWeight(weight.value))
            let design: UIFontDescriptor.SystemDesign = typeface == .rounded ? .rounded : typeface == .serif ? .serif : .default
            guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return UIFont(descriptor: descriptor, size: pointSize)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
