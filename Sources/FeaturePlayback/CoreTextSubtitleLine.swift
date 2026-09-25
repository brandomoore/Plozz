#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreText
import CoreGraphics
import CoreModels

/// A soft drop / hard directional shadow for the subtitle renderer.
struct SubtitleShadowSpec: Equatable {
    var offset: CGSize
    var blur: CGFloat
    var color: UIColor
}

/// An optional rounded background box drawn *behind* one subtitle line. It is
/// rendered inside ``CoreTextSubtitleLine`` (not as a SwiftUI `.background`) so it
/// hugs the text box at the user's padding while the view itself can extend well
/// past it for big outlines/shadows without clipping or a loose-looking box.
struct SubtitleBackgroundSpec: Equatable {
    var color: UIColor
    var cornerRadius: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
}

/// SwiftUI wrapper around a Core Text **glyph-path** subtitle line.
///
/// Outlines are drawn with the canonical **stroke-behind / fill-on-top**
/// technique used by libass and VLC: each glyph's real vector outline
/// (`CTFontCreatePathForGlyph`) is collected into one path, stroked in the
/// outline colour at **twice** the visible width with round joins/caps, and then
/// the fill is painted on top — so only the *outer* half of the stroke shows.
///
/// This is the fix for the old centered `NSAttributedString.strokeWidth`, which
/// grows half-*inward*: it ate the glyph fill and turned letters solid black as
/// the width increased. A path stroke behind the fill can never do that.
///
/// The view self-sizes (wrapping at the proposed width) and pads itself so the
/// outer outline and shadow are never clipped. It also drives the **CJK font
/// cascade** (Hiragino / PingFang / Apple SD Gothic Neo) so mixed-language and
/// dual-subtitle lines render with the bundled Latin face *and* system CJK.
/// A span of the line filled in a source-declared colour instead of the
/// style's, as a UTF-16 range into the line's text.
struct SubtitleFillSpan: Equatable {
    var location: Int
    var length: Int
    var color: UIColor
}

struct CoreTextSubtitleLine: UIViewRepresentable {
    let text: String
    let family: SubtitleFontFamily
    let weight: SubtitleFontWeight
    let fontSize: CGFloat
    let isBold: Bool
    let isItalic: Bool
    let fill: UIColor
    let outline: UIColor?
    /// Visible outline width in points (the renderer strokes at 2× this).
    let outlineWidth: CGFloat
    let shadow: SubtitleShadowSpec?
    let background: SubtitleBackgroundSpec?
    let alignment: NSTextAlignment
    var fillSpans: [SubtitleFillSpan] = []
    var systemFontDescriptor: UIFontDescriptor? = nil
    var glyphBackground: UIColor? = nil

    func makeUIView(context: Context) -> SubtitleLineView { SubtitleLineView() }

    func updateUIView(_ view: SubtitleLineView, context: Context) {
        view.configure(configuration)
    }

    var configuration: SubtitleLineView.Config {
        SubtitleLineView.Config(
            text: text, family: family, weight: weight, fontSize: fontSize,
            isBold: isBold, isItalic: isItalic,
            fill: fill, outline: outline, outlineWidth: outlineWidth,
            shadow: shadow, background: background, alignment: alignment,
            fillSpans: fillSpans, systemFontDescriptor: systemFontDescriptor,
            glyphBackground: glyphBackground)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SubtitleLineView, context: Context) -> CGSize? {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        return uiView.measure(maxWidth: w)
    }
}

/// UIKit view that lays out one subtitle line with Core Text and draws it with a
/// proper outer outline. Layout (the expensive part — shaping + glyph-path
/// extraction) is cached and only rebuilt when the config or wrap width changes,
/// so a 60 fps `TimelineView` redraw just re-fills a cached `CGPath`.
final class SubtitleLineView: UIView {

    struct Config: Equatable {
        var text: String
        var family: SubtitleFontFamily
        var weight: SubtitleFontWeight
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var fill: UIColor
        var outline: UIColor?
        var outlineWidth: CGFloat
        var shadow: SubtitleShadowSpec?
        var background: SubtitleBackgroundSpec?
        var alignment: NSTextAlignment
        var fillSpans: [SubtitleFillSpan] = []
        var systemFontDescriptor: UIFontDescriptor? = nil
        var glyphBackground: UIColor? = nil
    }

    private struct Layout {
        var path: CGPath          // combined glyph outline, positioned in flipped coords
        var spanFills: [SpanFill] // glyphs painted in a source colour over the default fill
        var totalSize: CGSize     // text size + outline/shadow/background insets
        var colorGlyphs: [ColorGlyph]  // emoji / colour glyphs (no vector path) drawn on top
        var background: BackgroundFill?  // rounded box hugging the text, drawn first
        var glyphBackgrounds: [CGRect] = []
        var defaultFillPath: CGPath? = nil
    }

    /// Glyphs of one source-coloured span, in the same coordinates as `path`.
    private struct SpanFill {
        var path: CGPath
        var color: UIColor
    }

    /// Tags the ranges a source colour covers so glyph extraction can group them.
    private static let fillSpanKey = NSAttributedString.Key("PlozzSubtitleFillSpan")

    /// A resolved background box in the line's flipped drawing coordinates.
    private struct BackgroundFill {
        var rect: CGRect
        var color: UIColor
        var cornerRadius: CGFloat
    }

    /// A colour/bitmap glyph (e.g. emoji) that exposes no vector outline and so
    /// must be drawn directly rather than stroked/filled as part of the path.
    private struct ColorGlyph {
        var font: CTFont
        var glyph: CGGlyph
        var position: CGPoint
        var opacity: CGFloat
    }

    private var config: Config?
    private var layout: Layout?
    private var layoutWidth: CGFloat = -1

    override init(frame: CGRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    func configure(_ c: Config) {
        guard c != config else { return }
        config = c
        layout = nil
        layoutWidth = -1
        invalidateIntrinsicContentSize()
        setNeedsDisplay()
    }

    func measure(maxWidth: CGFloat) -> CGSize {
        guard let c = config else { return .zero }
        if let l = layout, layoutWidth == maxWidth || l.totalSize.width == maxWidth {
            return l.totalSize
        }
        let l = buildLayout(c, maxWidth: maxWidth)
        layout = l
        layoutWidth = maxWidth
        return l.totalSize
    }

    override var intrinsicContentSize: CGSize {
        layout?.totalSize ?? CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measure(maxWidth: size.width)
    }

    override func draw(_ rect: CGRect) {
        guard let c = config, let ctx = UIGraphicsGetCurrentContext() else { return }
        let l: Layout
        // SwiftUI gives the view its measured (ink-tight) width, not necessarily
        // the wider wrapping proposal. Re-shaping at that smaller width wraps a
        // second time and draws extra lines above the height we just measured.
        if let cached = layout,
           layoutWidth == bounds.width || cached.totalSize.width == bounds.width {
            l = cached
        } else {
            l = buildLayout(c, maxWidth: bounds.width)
            layout = l
            layoutWidth = bounds.width
        }

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // UIKit top-left origin → Core Text / Core Graphics bottom-left origin.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        let path = l.path

        // 0. Background box: drawn first so the shadow, outline and fill all sit
        //    on top. It hugs the text at the user's padding regardless of how far
        //    the outline/shadow overflow extends the view bounds.
        if let bg = l.background {
            let box = UIBezierPath(roundedRect: bg.rect, cornerRadius: bg.cornerRadius).cgPath
            ctx.addPath(box)
            ctx.setFillColor(bg.color.cgColor)
            ctx.fillPath()
        }
        if let color = c.glyphBackground {
            ctx.setFillColor(color.cgColor)
            for rect in l.glyphBackgrounds { ctx.fill(rect) }
        }

        // 1. Soft shadow: fill the glyph silhouette with a live shadow so the
        //    blurred/offset copy shows behind everything else.
        if let sh = c.shadow {
            ctx.saveGState()
            clipOutsideGlyphs(path, in: ctx)
            // UIKit shadow offsets stay in device space even after the text
            // coordinate flip; positive height still means down on screen.
            ctx.setShadow(offset: sh.offset, blur: sh.blur, color: sh.color.cgColor)
            ctx.addPath(path)
            ctx.setFillColor(c.fill.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // 2. Outline *behind* the fill — stroke at 2× the visible width so only
        //    the outer half remains once the fill is painted over it.
        if let outline = c.outline, c.outlineWidth > 0 {
            ctx.saveGState()
            clipOutsideGlyphs(path, in: ctx)
            ctx.addPath(path)
            ctx.setStrokeColor(outline.cgColor)
            ctx.setLineWidth(c.outlineWidth * 2)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Each glyph receives one fill, so translucent source colors stay translucent.
        ctx.addPath(l.defaultFillPath ?? path)
        ctx.setFillColor(c.fill.cgColor)
        ctx.fillPath()
        for span in l.spanFills {
            ctx.addPath(span.path)
            ctx.setFillColor(span.color.cgColor)
            ctx.fillPath()
        }

        // 4. Colour-glyph pass (emoji etc.): these expose no vector outline, so
        //    we draw just those individual glyphs on top. Crucially we do NOT
        //    redraw the whole line — spaces also report "no path", and stamping
        //    the entire frame here is what double-struck the text.
        if !l.colorGlyphs.isEmpty {
            for cg in l.colorGlyphs {
                var g = cg.glyph
                var p = cg.position
                ctx.saveGState()
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.setAlpha(cg.opacity)
                CTFontDrawGlyphs(cg.font, &g, &p, 1, ctx)
                ctx.restoreGState()
            }
        }
    }

    // MARK: - Layout

    private func clipOutsideGlyphs(_ path: CGPath, in context: CGContext) {
        context.addRect(bounds)
        context.addPath(path)
        context.clip(using: .evenOdd)
    }

    private func buildLayout(_ c: Config, maxWidth: CGFloat) -> Layout {
        let font = makeCTFont(c)
        let attr = makeAttributed(c, font: font)
        let fs = CTFramesetterCreateWithAttributedString(attr)

        // Outline and shadow are independent passes over the same glyphs, so
        // reserve their maximum reach, not their sum plus an invisible margin.
        let strokeOut = max(0, c.outlineWidth)
        let sh = shadowOutsets(c)
        let padL = max(strokeOut, sh.left)
        let padR = max(strokeOut, sh.right)
        let padT = max(strokeOut, sh.top)
        let padB = max(strokeOut, sh.bottom)

        // Leave horizontal shaping room for italic overhangs and fallback glyphs.
        // This constrains wrapping only; it is not added to the drawn bounds.
        let overhang = max(ceil(c.fontSize * 0.2), 8)
        let backgroundPad = c.background?.horizontalPadding ?? 0
        let textMax = max(1, maxWidth - max(padL, backgroundPad) - max(padR, backgroundPad) - 2 * overhang)
        var fitRange = CFRange()
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: attr.length), nil,
            CGSize(width: textMax, height: .greatestFiniteMagnitude), &fitRange)
        let textSize = CGSize(width: ceil(min(suggested.width, textMax)),
                              height: ceil(suggested.height))

        // Lay the text out at the origin, then read the *actual* ink bounds.
        let boxRect = CGRect(origin: .zero, size: textSize)
        let frame = CTFramesetterCreateFrame(
            fs, CFRange(location: 0, length: attr.length),
            CGPath(rect: boxRect, transform: nil), nil)
        let (rawPath, rawDefaultFill, rawColorGlyphs, rawSpanFills) = Self.combinedGlyphPath(
            frame: frame, defaultOpacity: c.fill.cgColor.alpha
        )
        let glyphBackgrounds = c.glyphBackground == nil ? [] : Self.lineBackgroundRects(frame: frame)

        // Font ascent/descent/leading are layout metrics, not visible padding.
        // Anchor to actual ink (including fallback/colour glyphs), otherwise
        // OpenDyslexic's oversized descent keeps 0% far above the screen edge.
        var ink = CGRect.null
        if !rawPath.isEmpty { ink = ink.union(rawPath.boundingBoxOfPath) }
        for cg in rawColorGlyphs {
            var g = cg.glyph
            var b = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(cg.font, .default, &g, &b, 1)
            if !b.isNull, b.width > 0, b.height > 0 {
                ink = ink.union(b.offsetBy(dx: cg.position.x, dy: cg.position.y))
            }
        }
        guard !ink.isNull else {
            return Layout(path: rawPath, spanFills: [], totalSize: .zero, colorGlyphs: [], background: nil)
        }
        let backgroundBounds = glyphBackgrounds.reduce(ink) { $0.union($1) }

        // Grow the ink by the per-side reach to get the full drawn rect, union in
        // the optional background box (which hugs the text box at the user's
        // padding), then shift everything so the result starts at the origin.
        var drawn = CGRect(
            x: ink.minX - padL,
            y: ink.minY - padB,                       // flipped coords: bottom = min y
            width:  ink.width  + padL + padR,
            height: ink.height + padT + padB)
        drawn = drawn.union(backgroundBounds)
        var bgPre: CGRect?
        if let bg = c.background {
            let r = backgroundBounds.insetBy(dx: -bg.horizontalPadding, dy: -bg.verticalPadding)
            bgPre = r
            drawn = drawn.union(r)
        }
        var shift = CGAffineTransform(translationX: -drawn.minX, y: -drawn.minY)
        let path = rawPath.copy(using: &shift) ?? rawPath
        let spanFills = rawSpanFills.map { span in
            SpanFill(path: span.path.copy(using: &shift) ?? span.path, color: span.color)
        }
        let colorGlyphs = rawColorGlyphs.map {
            ColorGlyph(font: $0.font, glyph: $0.glyph,
                       position: CGPoint(x: $0.position.x - drawn.minX,
                                         y: $0.position.y - drawn.minY),
                       opacity: $0.opacity)
        }
        var background: BackgroundFill?
        if let bg = c.background, let r = bgPre {
            background = BackgroundFill(
                rect: r.offsetBy(dx: -drawn.minX, dy: -drawn.minY),
                color: bg.color, cornerRadius: bg.cornerRadius)
        }
        return Layout(path: path,
                      spanFills: spanFills,
                      totalSize: CGSize(width: ceil(drawn.width), height: ceil(drawn.height)),
                      colorGlyphs: colorGlyphs,
                      background: background,
                      glyphBackgrounds: glyphBackgrounds.map { $0.offsetBy(dx: -drawn.minX, dy: -drawn.minY) },
                      defaultFillPath: rawDefaultFill.copy(using: &shift) ?? rawDefaultFill)
    }

    static func lineBackgroundRects(frame: CTFrame) -> [CGRect] {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        return lines.enumerated().compactMap { index, line in
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            guard width > 0, ascent + descent > 0 else { return nil }
            return CGRect(x: origins[index].x, y: origins[index].y - descent,
                          width: width, height: ascent + descent)
        }
    }

    /// How far the soft shadow reaches beyond the glyph ink on each side.
    /// A positive `offset.height` pushes it toward the view's bottom.
    private func shadowOutsets(_ c: Config) -> UIEdgeInsets {
        guard let sh = c.shadow else { return .zero }
        let blur = max(0, sh.blur)
        return UIEdgeInsets(
            top:    blur + max(0, -sh.offset.height),
            left:   blur + max(0, -sh.offset.width),
            bottom: blur + max(0,  sh.offset.height),
            right:  blur + max(0,  sh.offset.width))
    }

    private static func combinedGlyphPath(frame: CTFrame, defaultOpacity: CGFloat) -> (CGPath, CGPath, [ColorGlyph], [SpanFill]) {
        let combined = CGMutablePath()
        let defaultFill = CGMutablePath()
        var colorGlyphs: [ColorGlyph] = []
        var spanPaths: [(path: CGMutablePath, color: UIColor)] = []
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else { return (combined, defaultFill, [], []) }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

        for (i, line) in lines.enumerated() {
            let lineOrigin = origins[i]
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { continue }
            for run in runs {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let runFontRaw = attrs[kCTFontAttributeName] else { continue }
                // CTFont is a Core Foundation class; this cast always succeeds.
                let runFont = runFontRaw as! CTFont
                // Source-coloured runs also collect into a per-colour path so the
                // fill pass can repaint just those glyphs.
                var spanPath: CGMutablePath?
                if let color = attrs[fillSpanKey] as? UIColor {
                    if let existing = spanPaths.first(where: { $0.color.isEqual(color) }) {
                        spanPath = existing.path
                    } else {
                        let created = CGMutablePath()
                        spanPaths.append((created, color))
                        spanPath = created
                    }
                }
                let count = CTRunGetGlyphCount(run)
                if count == 0 { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for j in 0..<count {
                    let pos = CGPoint(x: lineOrigin.x + positions[j].x,
                                      y: lineOrigin.y + positions[j].y)
                    if let gp = CTFontCreatePathForGlyph(runFont, glyphs[j], nil) {
                        let placed = CGAffineTransform(translationX: pos.x, y: pos.y)
                        combined.addPath(gp, transform: placed)
                        spanPath?.addPath(gp, transform: placed)
                        if spanPath == nil { defaultFill.addPath(gp, transform: placed) }
                        continue
                    }
                    // No vector outline. This is *usually* whitespace (a space has
                    // no contour) — which must be ignored, not drawn. Only a glyph
                    // with actual ink but no path (a colour/emoji glyph) needs the
                    // direct-draw pass, so distinguish them by ink bounds.
                    var g = glyphs[j]
                    var inkBounds = CGRect.zero
                    CTFontGetBoundingRectsForGlyphs(runFont, .default, &g, &inkBounds, 1)
                    if inkBounds.width > 0 && inkBounds.height > 0 {
                        colorGlyphs.append(ColorGlyph(
                            font: runFont, glyph: glyphs[j], position: pos,
                            opacity: (attrs[fillSpanKey] as? UIColor)?.cgColor.alpha ?? defaultOpacity
                        ))
                    }
                }
            }
        }
        return (combined, defaultFill, colorGlyphs, spanPaths.map { SpanFill(path: $0.path, color: $0.color) })
    }

    // MARK: - Font

    /// The named face for the requested weight/slant, or `nil`
    /// to use the system font. Picks the closest face a family actually offers:
    /// italic is preserved first (families ship italics only at Regular/Bold, and
    /// italic is per-cue emphasis), then the weight degrades toward Regular rather
    /// than letting Core Text substitute an unrelated system font.
    func postScriptName(_ c: Config) -> String? {
        let candidates = c.family.postScriptNameCandidates(weight: effectiveWeight(c), isItalic: c.isItalic)
        return candidates.first { UIFont(name: $0, size: 12) != nil }
            ?? c.family.postScriptNameCandidates().first
    }

    /// The weight to actually render for this cue: the global weight snapped to
    /// what the family bundles, bumped to the family's heaviest face when the cue
    /// itself is bold (per-cue markup), never lighter than the chosen base.
    private func effectiveWeight(_ c: Config) -> SubtitleFontWeight {
        let available = c.family.availableWeights
        let base = c.weight.snapped(to: available)
        guard c.isBold else { return base }
        let heaviest = available.last ?? .bold
        return heaviest.value >= base.value ? heaviest : base
    }

    private func uiFontWeight(_ w: SubtitleFontWeight) -> UIFont.Weight {
        switch w {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    /// Preferred CJK + emoji faces placed at the FRONT of the cascade list so
    /// mixed-script lines fall back to subtitle-weight cuts. The OS default
    /// cascade is appended after these (see `makeCTFont`) to cover every other
    /// script, so this list only needs to express CJK/emoji *preferences*.
    private static let cjkFallbackNames = [
        "HiraginoSans-W6", "HiraginoSans-W5", "HiraginoSans-W3",
        "AppleSDGothicNeo-SemiBold", "AppleSDGothicNeo-Medium", "AppleSDGothicNeo-Regular",
        "PingFangSC-Medium", "PingFangSC-Semibold", "PingFangSC-Regular",
        "PingFangTC-Medium", "PingFangHK-Medium",
        "AppleColorEmoji"
    ]

    func makeCTFont(_ c: Config) -> CTFont {
        let size = c.fontSize
        let baseDescriptor: CTFontDescriptor
        if let systemDescriptor = c.systemFontDescriptor {
            let descriptor = systemDescriptor as CTFontDescriptor
            var traits = CTFontGetSymbolicTraits(CTFontCreateWithFontDescriptor(descriptor, size, nil))
            if c.isBold { traits.insert(.traitBold) }
            if c.isItalic { traits.insert(.traitItalic) }
            baseDescriptor = c.isBold || c.isItalic
                ? CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, traits, traits) ?? descriptor
                : descriptor
        } else if let ps = postScriptName(c) {
            baseDescriptor = CTFontDescriptorCreateWithNameAndSize(ps as CFString, size)
            #if DEBUG
            // Core Text silently substitutes a fallback when a named font isn't
            // registered, so a missing UIAppFonts entry / unbundled face would
            // render every cue in the wrong font with no error. Surface it.
            let resolved = CTFontCopyPostScriptName(
                CTFontCreateWithFontDescriptor(baseDescriptor, size, nil)) as String
            if resolved.caseInsensitiveCompare(ps) != .orderedSame {
                print("⚠️ [Subtitle] requested font '\(ps)' but Core Text resolved '\(resolved)' — check UIAppFonts + that the TTF is bundled; subtitles are NOT using the intended face.")
            }
            #endif
        } else {
            let ui = UIFont.systemFont(ofSize: size, weight: uiFontWeight(effectiveWeight(c)))
            var descriptor = ui.fontDescriptor
            // SF Rounded: adopt the rounded design while preserving the weight.
            if c.family.usesRoundedDesign, let d = descriptor.withDesign(.rounded) {
                descriptor = d
            }
            if c.isItalic,
               let d = descriptor.withSymbolicTraits([descriptor.symbolicTraits, .traitItalic]) {
                descriptor = d
            }
            baseDescriptor = UIFont(descriptor: descriptor, size: size).fontDescriptor as CTFontDescriptor
        }
        // Curated CJK/emoji faces first so mixed-script Latin lines fall back to
        // subtitle-weight Hiragino/PingFang rather than the default thin cut.
        let curated = Self.cjkFallbackNames.map {
            CTFontDescriptorCreateWithNameAndSize($0 as CFString, size)
        }
        // Then the OS's own full default cascade so EVERY remaining script
        // (Arabic, Hebrew, Thai, Devanagari and other Indic, …) still resolves
        // to a real system face instead of tofu when the chosen Latin font — or
        // even SF — lacks the glyph. Universal coverage, any language, any font.
        let baseFont = CTFontCreateWithFontDescriptor(baseDescriptor, size, nil)
        // Equal point sizes do not mean equal visible sizes. Keep the default
        // Atkinson cap height, scaling each face uniformly (never distorting its
        // letterforms). makeAttributed restores fallback runs to nominal size.
        let reference = CTFontCreateWithName("AtkinsonHyperlegible-Regular" as CFString, size, nil)
        let capHeight = CTFontGetCapHeight(baseFont)
        let normalizedSize = c.systemFontDescriptor == nil && capHeight > 0
            ? size * CTFontGetCapHeight(reference) / capHeight
            : size
        let systemDefault =
            (CTFontCopyDefaultCascadeListForLanguages(baseFont, nil) as? [CTFontDescriptor]) ?? []
        let preservedCascade = CTFontDescriptorCopyAttribute(baseDescriptor, kCTFontCascadeListAttribute) as? [CTFontDescriptor] ?? []
        let cascade = preservedCascade + (c.systemFontDescriptor == nil ? curated : []) + systemDefault
        let withCascade = CTFontDescriptorCreateCopyWithAttributes(
            baseDescriptor,
            [kCTFontCascadeListAttribute: cascade] as CFDictionary)
        return CTFontCreateWithFontDescriptor(withCascade, normalizedSize, nil)
    }

    private func makeAttributed(_ c: Config, font: CTFont) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = c.alignment
        para.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: c.text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            .foregroundColor: c.fill,
            .paragraphStyle: para
        ])
        let length = attributed.length
        for span in c.fillSpans {
            let range = NSRange(location: span.location, length: span.length)
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { continue }
            attributed.addAttribute(Self.fillSpanKey, value: span.color, range: range)
        }
        // Device descriptors own their cascade sizing. The bundled-face
        // cap-height compensation below must not rewrite it.
        guard c.systemFontDescriptor == nil else { return attributed }
        // Core Text scales cascade fonts to the base size even when their
        // descriptors specify a size. Pin resolved fallback runs explicitly so
        // switching to OpenDyslexic doesn't shrink CJK, Arabic or emoji.
        let line = CTLineCreateWithAttributedString(attributed)
        let baseName = CTFontCopyPostScriptName(font) as String
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName] as! CTFont
            guard CTFontCopyPostScriptName(runFont) as String != baseName else { continue }
            let range = CTRunGetStringRange(run)
            attributed.addAttribute(
                kCTFontAttributeName as NSAttributedString.Key,
                value: CTFontCreateCopyWithAttributes(runFont, c.fontSize, nil, nil),
                range: NSRange(location: range.location, length: range.length)
            )
        }
        return attributed
    }
}
#endif
