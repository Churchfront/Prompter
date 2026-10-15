import SwiftUI
import UIKit
import CoreText

// Churchfront Signal, the design system for software Churchfront builds,
// translated to native SwiftUI. Dark (Midnight) is the default theme.
// Semantic tokens only; values come from the Signal tokens file.

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Dark value unless the interface is explicitly light (dark first).
    static func signal(dark: UInt32, light: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark)
        }
    }
}

enum Signal {
    // Brand core. Never tinted or replaced.
    static let midnightHex: UInt32 = 0x090E14
    static let greyHex: UInt32 = 0xE6E7E8
    static let refreshHex: UInt32 = 0xCAE7F9

    // Semantic tokens (dark, light).
    static let bg = Color(uiColor: .signal(dark: 0x090E14, light: 0xE6E7E8))
    static let surface = Color(uiColor: .signal(dark: 0x0F161F, light: 0xF4F5F6))
    static let surfaceRaised = Color(uiColor: .signal(dark: 0x172230, light: 0xFFFFFF))
    static let surfaceSunken = Color(uiColor: .signal(dark: 0x05080C, light: 0xD9DCDF))
    static let line = Color(uiColor: .signal(dark: 0x223040, light: 0xC9CED4))
    static let lineStrong = Color(uiColor: .signal(dark: 0x66778B, light: 0x6F7C8A))
    static let ink = Color(uiColor: .signal(dark: 0xE6E7E8, light: 0x090E14))
    static let inkMuted = Color(uiColor: .signal(dark: 0xA7B1BC, light: 0x3A4858))
    static let inkSubtle = Color(uiColor: .signal(dark: 0x8491A0, light: 0x526172))
    static let accent = Color(uiColor: .signal(dark: 0xCAE7F9, light: 0x155C8F))
    static let accentSoft = Color(uiColor: .signal(dark: 0x12283B, light: 0xCAE7F9))
    static let action = Color(uiColor: .signal(dark: 0xCAE7F9, light: 0x090E14))
    static let onAction = Color(uiColor: .signal(dark: 0x090E14, light: 0xE6E7E8))
    static let focusRing = Color(uiColor: .signal(dark: 0x7CC2EE, light: 0x1A73B3))
    static let success = Color(uiColor: .signal(dark: 0x4FD8C4, light: 0x0B6E68))
    static let successSoft = Color(uiColor: .signal(dark: 0x0A2B28, light: 0xD2F5EF))
    static let warning = Color(uiColor: .signal(dark: 0xF2B84B, light: 0x7A5000))
    static let warningSoft = Color(uiColor: .signal(dark: 0x2E2208, light: 0xF8E7C2))
    static let danger = Color(uiColor: .signal(dark: 0xFF6B5E, light: 0xB42318))
    static let dangerSoft = Color(uiColor: .signal(dark: 0x34120F, light: 0xFBDAD6))
    static let scrim = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(hex: 0x090E14, alpha: 0.40)
            : UIColor(hex: 0x05080C, alpha: 0.72)
    })

    // Spacing (4 pt base).
    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 20, s6: CGFloat = 24, s8: CGFloat = 32, s10: CGFloat = 40
    }

    // Radius: tight corners echo the logo's hard cuts.
    enum Radius {
        static let xs: CGFloat = 2, sm: CGFloat = 4, md: CGFloat = 6, lg: CGFloat = 10
    }

    // Control heights. Touch surfaces use the large size.
    enum Control {
        static let md: CGFloat = 36, lg: CGFloat = 44
    }
}

// MARK: - Typography

enum SignalTextStyle {
    case display, title, heading, subheading, statement, bodyLarge, body, bodySmall
    case label, eyebrow, readout, mono, monoSmall

    var size: CGFloat {
        switch self {
        case .display: 48
        case .title: 28
        case .heading, .statement: 20
        case .subheading: 16
        case .bodyLarge: 17
        case .body: 14
        case .bodySmall, .mono: 13
        case .label: 12
        case .eyebrow, .monoSmall: 11
        case .readout: 32
        }
    }

    var weight: CGFloat {
        switch self {
        case .display, .title, .heading, .label, .eyebrow: 700
        case .subheading, .statement: 600
        case .bodyLarge: 300
        case .body, .bodySmall, .mono, .monoSmall: 400
        case .readout: 500
        }
    }

    /// Letter spacing in points (the tokens give em).
    var tracking: CGFloat {
        switch self {
        case .display: -0.02 * size
        case .title: -0.01 * size
        case .heading: -0.005 * size
        case .label: 0.09 * size
        case .eyebrow: 0.14 * size
        case .readout: -0.02 * size
        default: 0
        }
    }

    var isUppercase: Bool {
        switch self {
        case .display, .title, .label, .eyebrow: true
        default: false
        }
    }

    var isMonospaced: Bool { self == .mono || self == .monoSmall || self == .readout }

    var textStyle: UIFont.TextStyle {
        switch self {
        case .display, .title: .largeTitle
        case .heading, .statement: .title3
        case .subheading: .headline
        case .bodyLarge: .body
        case .body, .mono: .subheadline
        case .bodySmall: .footnote
        case .label, .eyebrow, .monoSmall: .caption1
        case .readout: .title1
        }
    }
}

enum SignalFont {
    /// PostScript name of the bundled variable font's default instance.
    static let figtree = "Figtree-Light"
    private static let weightAxis = 0x77676874 // 'wght'
    private static var cache: [String: UIFont] = [:]

    /// Registers the bundled Figtree variable font for this process.
    static func register() {
        // Info.plist (UIAppFonts) registers the font; this is only a fallback.
        guard !isFigtreeAvailable else { return }
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static var isFigtreeAvailable: Bool { UIFont(name: figtree, size: 12) != nil }

    /// Figtree at a given weight (300...900) using the variable weight axis.
    /// Falls back to the system font if the bundled font is missing.
    static func figtree(size: CGFloat, weight: CGFloat) -> UIFont {
        let key = "\(size)-\(weight)"
        if let cached = cache[key] { return cached }
        let font: UIFont
        if isFigtreeAvailable {
            let descriptor = UIFontDescriptor(name: figtree, size: size).addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [weightAxis: weight]
            ])
            font = UIFont(descriptor: descriptor, size: size)
        } else {
            font = .systemFont(ofSize: size, weight: systemWeight(weight))
        }
        cache[key] = font
        return font
    }

    static func systemWeight(_ weight: CGFloat) -> UIFont.Weight {
        switch weight {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    static func uiFont(_ style: SignalTextStyle) -> UIFont {
        let base: UIFont = style.isMonospaced
            ? .monospacedSystemFont(ofSize: style.size, weight: systemWeight(style.weight))
            : figtree(size: style.size, weight: style.weight)
        return UIFontMetrics(forTextStyle: style.textStyle).scaledFont(for: base)
    }
}

private struct SignalTextModifier: ViewModifier {
    let style: SignalTextStyle
    // Re-evaluated when Dynamic Type changes.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content
            .font(Font(SignalFont.uiFont(style)))
            .tracking(style.tracking)
            .textCase(style.isUppercase ? .uppercase : nil)
            .monospacedDigit()
    }
}

extension View {
    func signal(_ style: SignalTextStyle) -> some View {
        modifier(SignalTextModifier(style: style))
    }
}

// MARK: - Signature shape and buttons

/// The Churchfront primary button shape: a true semicircle on the left and a
/// straight edge slanted about 12 degrees on the right.
struct SignatureShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let inset = 0.211 * rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addRelativeArc(center: CGPoint(x: rect.minX + radius, y: rect.midY),
                            radius: radius, startAngle: .degrees(90), delta: .degrees(180))
        path.closeSubpath()
        return path
    }
}

/// Primary: the one action a view is for. At most one per view.
struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = Signal.Control.lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .signal(.label)
            .foregroundStyle(Signal.onAction)
            .padding(.leading, Signal.Space.s5)
            .padding(.trailing, Signal.Space.s5 + 0.211 * height)
            .frame(minHeight: height)
            .background(SignatureShape().fill(Signal.action))
            .contentShape(SignatureShape())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary: the default button.
struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = Signal.Control.lg
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .signal(.label)
            .foregroundStyle(Signal.ink)
            .padding(.horizontal, Signal.Space.s4)
            .frame(minHeight: height)
            .background(
                RoundedRectangle(cornerRadius: Signal.Radius.sm)
                    .fill(configuration.isPressed ? Signal.surfaceRaised : Color.clear)
            )
            .overlay(RoundedRectangle(cornerRadius: Signal.Radius.sm).strokeBorder(Signal.lineStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Signal.Radius.sm))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet: toolbars and low-stakes actions. Icon-only use needs an accessibility label.
struct QuietButtonStyle: ButtonStyle {
    var size: CGFloat = Signal.Control.lg
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? Signal.accent : Signal.ink)
            .frame(minWidth: size, minHeight: size)
            .background(
                RoundedRectangle(cornerRadius: Signal.Radius.sm)
                    .fill(configuration.isPressed || isSelected ? Signal.surfaceRaised : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Signal.Radius.sm))
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var signalPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}
extension ButtonStyle where Self == SecondaryButtonStyle {
    static var signalSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
extension ButtonStyle where Self == QuietButtonStyle {
    static var signalQuiet: QuietButtonStyle { QuietButtonStyle() }
}

/// A status line that always pairs color with a word and an icon.
struct StatusBadge: View {
    enum Tone { case neutral, success, warning, danger, accent }
    let text: String
    let systemImage: String
    var tone: Tone = .neutral

    var body: some View {
        Label(text, systemImage: systemImage)
            .signal(.label)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .padding(.horizontal, Signal.Space.s2)
            .padding(.vertical, Signal.Space.s1)
            .background(RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(background))
    }

    private var foreground: Color {
        switch tone {
        case .neutral: Signal.inkMuted
        case .success: Signal.success
        case .warning: Signal.warning
        case .danger: Signal.danger
        case .accent: Signal.accent
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: Signal.surfaceRaised
        case .success: Signal.successSoft
        case .warning: Signal.warningSoft
        case .danger: Signal.dangerSoft
        case .accent: Signal.accentSoft
        }
    }
}
