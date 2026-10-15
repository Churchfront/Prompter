import SwiftUI
import UIKit
import TeleprompterCore

/// Everything that affects how the prompter text looks.
struct PrompterStyle: Equatable {
    var font: UIFont
    var textColor: UIColor
    var highlightColor: UIColor
    var lineSpacing: CGFloat
    var alignment: NSTextAlignment
    /// Side margin as a fraction of the width.
    var margin: CGFloat
    /// Reading line as a fraction of the height.
    var readingLine: CGFloat
    /// Stage directions: smaller and quieter than the script.
    var cueFont: UIFont
    var cueColor: UIColor

    init(settings: ReaderSettings) {
        font = settings.prompterFont()
        textColor = settings.textColor.uiColor
        highlightColor = settings.highlightColor.uiColor
        lineSpacing = CGFloat(settings.lineSpacing)
        alignment = settings.alignment.nsAlignment
        margin = CGFloat(settings.horizontalMargin)
        readingLine = CGFloat(settings.readingLine)
        cueFont = settings.prompterFont(size: max(14, settings.fontSize * 0.42))
        cueColor = settings.highlightColor.uiColor.withAlphaComponent(0.55)
    }

    /// Changes that move words around (as opposed to color-only changes).
    func affectsLayout(comparedTo other: PrompterStyle) -> Bool {
        font != other.font || lineSpacing != other.lineSpacing || alignment != other.alignment
            || margin != other.margin || readingLine != other.readingLine || cueFont != other.cueFont
    }

    var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineHeightMultiple = lineSpacing
        paragraph.paragraphSpacing = font.pointSize * 0.5
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }
}

/// The scrolling script. A UITextView on an explicit TextKit 1 stack, so every
/// word's line and position can be measured exactly.
///
/// The text container's top inset equals the reading line and its bottom inset
/// equals the rest of the screen, so offset 0 puts the first line on the
/// reading line and the maximum offset puts the last line there. The reading
/// position (a fractional token index) is captured before any relayout
/// (rotation, font size, margins) and restored after it.
@MainActor
final class PrompterTextSurface: UITextView, PrompterSurface {
    weak var controller: PrompterController?

    private(set) var geometry = TokenGeometry(readingY: [])
    private let tokens: TokenizedScript
    private let storage: NSTextStorage
    private let textLayout: NSLayoutManager
    private var style: PrompterStyle
    private var lastLayoutSize: CGSize = .zero
    private var appliedHighlight: PrompterHighlight?
    /// -1 is the very top of the script, so an opening stage direction is visible.
    private var anchorPosition: Double = -1
    private var isRelayingOut = false

    init(text: String, tokens: TokenizedScript, style: PrompterStyle) {
        self.tokens = tokens
        self.style = style
        storage = NSTextStorage(string: text, attributes: style.attributes)
        Self.styleCues(in: storage, ranges: tokens.cueRanges, style: style)
        textLayout = NSLayoutManager()
        textLayout.allowsNonContiguousLayout = false
        storage.addLayoutManager(textLayout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        textLayout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        isEditable = false
        isSelectable = false
        isScrollEnabled = true
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        decelerationRate = .normal
        accessibilityLabel = "Script"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: PrompterSurface

    var currentOffset: CGFloat { contentOffset.y }

    var maxOffset: CGFloat {
        max(0, textHeight + textContainerInset.top + textContainerInset.bottom - bounds.height)
    }

    /// Height of the laid-out text, measured after each full layout. Recoloring
    /// words (highlight and dimming) invalidates layout without changing any
    /// metrics, and a live usedRect read in between can report only part of
    /// the text, which would end timed scrolling early.
    private var textHeight: CGFloat = 0

    var lineHeight: CGFloat { style.font.lineHeight * style.lineSpacing }

    var isUserInteracting: Bool { isTracking || isDragging || isDecelerating }

    func setOffset(_ offset: CGFloat) {
        if abs(contentOffset.y - offset) > 0.01 {
            contentOffset = CGPoint(x: 0, y: offset)
        }
        if !isRelayingOut && !geometry.isEmpty {
            anchorPosition = geometry.position(forOffset: Double(offset))
        }
    }

    // The anchor follows only deliberate movement: the controller (setOffset)
    // or the reader's finger. UIKit also nudges the offset while it re-lays out
    // text for a new size or font; those nudges must not move the anchor.
    override var contentOffset: CGPoint {
        didSet {
            if !isRelayingOut && isUserInteracting && !geometry.isEmpty {
                anchorPosition = geometry.position(forOffset: Double(contentOffset.y))
            }
        }
    }

    // MARK: Style and layout

    func apply(style newStyle: PrompterStyle) {
        guard newStyle != style else { return }
        let needsLayout = newStyle.affectsLayout(comparedTo: style)
        style = newStyle
        let full = NSRange(location: 0, length: storage.length)
        if needsLayout {
            let anchor = anchorPosition
            isRelayingOut = true
            storage.setAttributes(newStyle.attributes, range: full)
            Self.styleCues(in: storage, ranges: tokens.cueRanges, style: newStyle)
            relayout(preserving: anchor)
        } else {
            storage.addAttribute(.foregroundColor, value: newStyle.textColor, range: full)
            Self.styleCues(in: storage, ranges: tokens.cueRanges, style: newStyle)
            redrawHighlight()
        }
    }

    /// Positions the reader at a token before the first layout.
    func setInitialPosition(_ token: Int) {
        anchorPosition = Double(token)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastLayoutSize else { return }
        lastLayoutSize = bounds.size
        isRelayingOut = true
        relayout(preserving: anchorPosition)
    }

    private func relayout(preserving anchor: Double) {
        guard bounds.width > 0, bounds.height > 0 else {
            isRelayingOut = false
            return
        }
        isRelayingOut = true
        let readingY = (bounds.height * style.readingLine).rounded()
        let side = (bounds.width * style.margin).rounded()
        textContainerInset = UIEdgeInsets(top: readingY, left: side, bottom: bounds.height - readingY, right: side)
        textLayout.ensureLayout(for: textContainer)
        textHeight = textLayout.usedRect(for: textContainer).height
        rebuildGeometry()
        let restored = min(max(CGFloat(geometry.offset(forPosition: anchor)), 0), maxOffset)
        contentOffset = CGPoint(x: 0, y: restored)
        isRelayingOut = false
        anchorPosition = anchor
        redrawHighlight()
        controller?.surfaceDidRelayout(offset: restored)
    }

    /// Reading y for each token: line top plus the word's horizontal start on
    /// the line as a fraction of the line height (see TokenGeometry). The first
    /// word of a line maps to the line's top, so the start of the script is offset 0.
    private func rebuildGeometry() {
        var ys: [Double] = []
        ys.reserveCapacity(tokens.count)
        for token in tokens.tokens {
            let glyphs = textLayout.glyphRange(forCharacterRange: token.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else {
                ys.append(ys.last ?? 0)
                continue
            }
            let line = textLayout.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let used = textLayout.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let word = textLayout.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let fraction = used.width > 0 ? min(max((word.minX - used.minX) / used.width, 0), 1) : 0
            let y = Double(line.minY + fraction * line.height)
            // Monotonic, even if a layout quirk reports a word slightly above the previous one.
            ys.append(max(y, ys.last ?? y))
        }
        geometry = TokenGeometry(readingY: ys)
    }

    /// Stage directions read as small, quiet cues, not script.
    private static func styleCues(in storage: NSTextStorage, ranges: [NSRange], style: PrompterStyle) {
        guard !ranges.isEmpty else { return }
        storage.beginEditing()
        for range in ranges where NSMaxRange(range) <= storage.length {
            storage.addAttributes([.font: style.cueFont, .foregroundColor: style.cueColor], range: range)
        }
        storage.endEditing()
    }

    // MARK: Highlight

    func applyHighlight(_ highlight: PrompterHighlight) {
        guard highlight != appliedHighlight else { return }
        let previous = appliedHighlight
        appliedHighlight = highlight
        draw(highlight, replacing: previous)
    }

    private func redrawHighlight() {
        guard let highlight = appliedHighlight else { return }
        draw(highlight, replacing: nil)
    }

    /// Recolors only the words whose state changed. Color changes keep glyph
    /// metrics, so word geometry stays valid and nothing moves.
    private func draw(_ highlight: PrompterHighlight, replacing previous: PrompterHighlight?) {
        guard !tokens.isEmpty else { return }
        let n = tokens.count
        var lo = n, hi = 0
        func include(_ range: Range<Int>) {
            guard !range.isEmpty else { return }
            lo = min(lo, range.lowerBound)
            hi = max(hi, range.upperBound)
        }
        if let previous {
            let a = min(previous.readUpTo, highlight.readUpTo), b = max(previous.readUpTo, highlight.readUpTo)
            include(a..<b)
            if let current = previous.current { include(current) }
            if let current = highlight.current { include(current) }
        } else {
            include(0..<n)
        }
        lo = max(lo, 0)
        hi = min(hi, n)
        guard lo < hi else { return }

        let span = spanRange(lo..<hi)
        let read = NSIntersectionRange(span, NSRange(location: 0, length: tokenStart(highlight.readUpTo)))
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: style.textColor, range: span)
        if let current = highlight.current {
            let range = NSIntersectionRange(span, wordsRange(current))
            if range.length > 0 { storage.addAttribute(.foregroundColor, value: style.highlightColor, range: range) }
        }
        if read.length > 0 {
            storage.addAttribute(.foregroundColor, value: style.textColor.withAlphaComponent(0.4), range: read)
        }
        for cue in tokens.cueRanges {
            let range = NSIntersectionRange(cue, span)
            if range.length > 0 { storage.addAttribute(.foregroundColor, value: style.cueColor, range: range) }
        }
        storage.endEditing()
    }

    /// Character offset where token `index` starts (end of text past the last token).
    private func tokenStart(_ index: Int) -> Int {
        if index <= 0 { return 0 }
        if index >= tokens.count { return storage.length }
        return tokens.tokens[index].range.location
    }

    /// Characters from the start of token `lo` to the start of token `hi`, including punctuation between.
    private func spanRange(_ range: Range<Int>) -> NSRange {
        let start = tokenStart(range.lowerBound)
        return NSRange(location: start, length: tokenStart(range.upperBound) - start)
    }

    /// Characters from the first word of the range to the end of its last word.
    private func wordsRange(_ range: Range<Int>) -> NSRange {
        let lower = max(range.lowerBound, 0)
        let upper = min(range.upperBound, tokens.count)
        guard lower < upper else { return NSRange(location: 0, length: 0) }
        let start = tokens.tokens[lower].range.location
        return NSRange(location: start, length: NSMaxRange(tokens.tokens[upper - 1].range) - start)
    }
}

/// SwiftUI wrapper for the prompter text.
struct PrompterTextView: UIViewRepresentable {
    let controller: PrompterController
    let style: PrompterStyle

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> PrompterTextSurface {
        let view = PrompterTextSurface(text: controller.text, tokens: controller.tokens, style: style)
        view.controller = controller
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        view.addGestureRecognizer(tap)
        controller.attach(surface: view)
        return view
    }

    func updateUIView(_ view: PrompterTextSurface, context: Context) {
        view.apply(style: style)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: PrompterController

        init(controller: PrompterController) {
            self.controller = controller
        }

        @objc func tapped() {
            controller.handleTap()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            controller.userBeganInteraction()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { controller.userEndedInteraction(at: scrollView.contentOffset.y) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            controller.userEndedInteraction(at: scrollView.contentOffset.y)
        }
    }
}
