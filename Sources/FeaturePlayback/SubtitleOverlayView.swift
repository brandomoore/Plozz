#if canImport(SwiftUI)
import SwiftUI
import UIKit
import CoreModels
import CoreUI

enum SubtitleOverlayGeometry {
    static var controlsClearance: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    static func upwardOffset(
        for subtitle: CGRect, avoiding controls: CGRect?, in bounds: CGRect,
        clearance: CGFloat = controlsClearance
    ) -> CGFloat {
        upwardOffset(for: subtitle, avoiding: controls.map { [$0] } ?? [], in: bounds, clearance: clearance)
    }

    static func upwardOffset(
        for subtitle: CGRect, avoiding controls: [CGRect], in bounds: CGRect,
        clearance: CGFloat = controlsClearance
    ) -> CGFloat {
        func valid(_ rect: CGRect) -> Bool {
            !rect.isNull && !rect.isEmpty && rect.minX.isFinite && rect.minY.isFinite
                && rect.width.isFinite && rect.height.isFinite
        }
        guard valid(subtitle), valid(bounds) else { return 0 }
        let visible = controls.filter(valid).map { $0.intersection(bounds) }.filter(valid)
        var moved = subtitle
        var total: CGFloat = 0
        for _ in visible {
            guard let top = visible.filter({ moved.intersects($0) }).map(\.minY).min() else { break }
            let lift = min(0, max(top - max(0, clearance) - moved.maxY, bounds.minY - moved.minY))
            guard lift < 0 else { break }
            moved = moved.offsetBy(dx: 0, dy: lift)
            total += lift
        }
        return total
    }

    static func aspectFitRect(
        in bounds: CGRect,
        aspectRatio: CGFloat?
    ) -> CGRect? {
        guard bounds.width > 0,
              bounds.height > 0,
              let aspectRatio,
              aspectRatio.isFinite,
              aspectRatio > 0 else {
            return nil
        }

        let boundsAspectRatio = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio >= boundsAspectRatio {
            size = CGSize(
                width: bounds.width,
                height: bounds.width / aspectRatio
            )
        } else {
            size = CGSize(
                width: bounds.height * aspectRatio,
                height: bounds.height
            )
        }

        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    static func bitmapRect(
        normalizedRect: CGRect,
        canvasSize: CGSize,
        videoRect: CGRect
    ) -> CGRect {
        let canvasRect: CGRect
        if canvasSize.width > 0,
           canvasSize.height > 0,
           canvasSize.width.isFinite,
           canvasSize.height.isFinite {
            let scale = videoRect.width / canvasSize.width
            let mappedHeight = canvasSize.height * scale
            canvasRect = CGRect(
                x: videoRect.minX,
                y: videoRect.midY - mappedHeight / 2,
                width: videoRect.width,
                height: mappedHeight
            )
        } else {
            canvasRect = videoRect
        }

        return CGRect(
            x: canvasRect.minX + normalizedRect.minX * canvasRect.width,
            y: canvasRect.minY + normalizedRect.minY * canvasRect.height,
            width: normalizedRect.width * canvasRect.width,
            height: normalizedRect.height * canvasRect.height
        )
    }
}

private struct SubtitleLaneHeight: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Anchors the visible text block while retaining empty dual-subtitle lanes.
/// Measuring the outer ink edges separately keeps lane padding off screen edges.
private struct SubtitlePositionLayout: Layout {
    let verticalPosition: Double
    let verticalAnchor: SubtitleStyle.VerticalAnchor
    let spacing: CGFloat
    let controlsFrames: [CGRect]

    private var anchorFraction: CGFloat {
        switch verticalAnchor {
        case .top: 0
        case .center: 0.5
        case .bottom: 1
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let height = zip(subviews, sizes).reduce(CGFloat.zero) {
            $0 + max($1.0[SubtitleLaneHeight.self], $1.1.height)
        } + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(
            width: proposal.width ?? sizes.map(\.width).max() ?? 0,
            height: proposal.height ?? height
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let contentProposal = ProposedViewSize(width: bounds.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(contentProposal) }
        let heights = zip(subviews, sizes).map { max($0.0[SubtitleLaneHeight.self], $0.1.height) }
        let last = sizes.count - 1
        let topInset = sizes[0].height > 0 ? (heights[0] - sizes[0].height) * anchorFraction : 0
        let bottomInset = sizes[last].height > 0
            ? (heights[last] - sizes[last].height) * (1 - anchorFraction) : 0
        let height = heights.reduce(0, +) + spacing * CGFloat(last) - topInset - bottomInset
        let travel = bounds.height - height
        let origin: CGFloat
        if verticalPosition < 0 {
            // Continue smoothly below 0% regardless of the selected anchor.
            origin = travel - bounds.height * verticalPosition
        } else {
            let anchored = bounds.height * (1 - verticalPosition) - height * anchorFraction
            origin = min(max(anchored, min(0, travel)), max(0, travel))
        }
        var visibleBlock = CGRect.null
        var naturalY = origin - topInset
        for index in sizes.indices {
            if sizes[index].width > 0, sizes[index].height > 0 {
                visibleBlock = visibleBlock.union(CGRect(
                    x: (bounds.width - sizes[index].width) / 2,
                    y: naturalY + (heights[index] - sizes[index].height) * anchorFraction,
                    width: sizes[index].width, height: sizes[index].height
                ))
            }
            naturalY += heights[index] + spacing
        }
        let lift = SubtitleOverlayGeometry.upwardOffset(
            for: visibleBlock, avoiding: controlsFrames,
            in: CGRect(origin: .zero, size: bounds.size)
        )
        var y = bounds.minY + origin - topInset + lift
        for (index, subview) in subviews.enumerated() {
            let inset = (heights[index] - sizes[index].height) * anchorFraction
            subview.place(at: CGPoint(x: bounds.midX, y: y + inset), anchor: .top, proposal: contentProposal)
            y += heights[index] + spacing
        }
    }
}

private struct SubtitleSourcePositionLayout: Layout {
    let layout: SubtitleCueLayout
    let videoRect: CGRect
    let controlsFrames: [CGRect]
    let titleSafeFraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let safe = CGRect(
            x: videoRect.minX + videoRect.width * (titleSafeFraction + layout.margins.leading),
            y: videoRect.minY + videoRect.height * (titleSafeFraction + layout.margins.top),
            width: max(0, videoRect.width * (1 - 2 * titleSafeFraction - layout.margins.leading - layout.margins.trailing)),
            height: max(0, videoRect.height * (1 - 2 * titleSafeFraction - layout.margins.top - layout.margins.bottom))
        )
        let width = layout.anchor == nil ? min(safe.width, videoRect.width * 0.92) : videoRect.width * 0.92
        let contentProposal = ProposedViewSize(width: width, height: nil)
        let size = subview.sizeThatFits(contentProposal)
        let origin: CGPoint
        if let anchor = layout.anchor {
            let horizontalAnchor: CGFloat
            switch layout.alignment.horizontal {
            case .leading: horizontalAnchor = 0
            case .center: horizontalAnchor = 0.5
            case .trailing: horizontalAnchor = 1
            }
            origin = CGPoint(
                x: videoRect.minX + anchor.x * videoRect.width - width / 2 + (width - size.width) * horizontalAnchor,
                y: videoRect.minY + anchor.y * videoRect.height - size.height / 2
            )
        } else {
            let x: CGFloat
            switch layout.alignment.horizontal {
            case .leading: x = safe.minX
            case .center: x = safe.midX - size.width / 2
            case .trailing: x = safe.maxX - size.width
            }
            let y: CGFloat
            switch layout.alignment.vertical {
            case .top: y = safe.minY
            case .middle: y = safe.midY - size.height / 2
            case .bottom: y = safe.maxY - size.height
            }
            origin = CGPoint(x: x, y: y)
        }
        let lift = SubtitleOverlayGeometry.upwardOffset(
            for: CGRect(origin: origin, size: size), avoiding: controlsFrames,
            in: CGRect(origin: .zero, size: bounds.size)
        )
        subview.place(
            at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y + lift),
            anchor: .topLeading, proposal: contentProposal
        )
    }
}

/// Plozz's **own** subtitle renderer: an engine-agnostic SwiftUI overlay that
/// draws a normalized `[SubtitleCue]` stream with full styling.
///
/// This is the keystone of the v2 subtitle architecture. Neither AVPlayer nor
/// Plozzigen (AetherEngine) draws subtitles any more — they emit cues, and this
/// view renders them. That single inversion is what makes HDR-luminance control,
/// live restyling, bitmap subtitles, dual subtitles, offset/sync and (later)
/// word-level features all possible, because we control every pixel.
///
/// It is deliberately **pure data-in**: it has no reference to the player, the
/// engines, or AVFoundation. It takes cues + a ``SubtitleStyle`` and renders.
/// That is why the same view serves both the debug preview harness (mock cues
/// over a backdrop) and, later, live playback (real cues over the video surface)
/// with no changes.
///
/// ### HDR luminance
/// The overlay is an SDR UI layer, so on an HDR display the system already maps
/// its "white" to reference white (~100–203 nits) rather than peak — subtitles
/// don't glare by default. ``SubtitleStyle/hdrLuminanceScale`` then lets the user
/// dim the white point further on HDR frames (a future EDR path can push it
/// brighter). The scale is applied to the text fill and to bitmap cues only on
/// HDR frames; SDR frames are untouched.
public struct SubtitleOverlayView: View {

    /// Cues currently on screen for the primary track (already time-filtered via
    /// `Sequence.active(at:offset:)`). Overlapping cues are allowed.
    public var primary: [SubtitleCue]
    /// Cues for an optional secondary (dual-subtitle) track.
    public var secondary: [SubtitleCue]
    /// Whether a secondary (dual) track is actively selected. The reserved second
    /// lane is drawn only when this is `true`, so a persisted secondary *style*
    /// alone (with no active second track) never reserves a phantom empty lane.
    public var secondaryActive: Bool
    public var style: SubtitleStyle
    /// Whether the underlying video frame is HDR; gates luminance scaling.
    public var isHDR: Bool
    /// The on-screen rect of the video image, used to place bitmap cues. `nil`
    /// means "fill the container" (fine for text and for the harness).
    public var videoRect: CGRect?
    /// Visible bottom controls in global coordinates; never a persisted position.
    public var controlsFrame: CGRect?
    public var controlsFrames: [CGRect]

    public init(
        primary: [SubtitleCue],
        secondary: [SubtitleCue] = [],
        secondaryActive: Bool = false,
        style: SubtitleStyle,
        isHDR: Bool = false,
        videoRect: CGRect? = nil,
        controlsFrame: CGRect? = nil,
        controlsFrames: [CGRect] = []
    ) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryActive = secondaryActive
        self.style = style
        self.isHDR = isHDR
        self.videoRect = videoRect
        self.controlsFrame = controlsFrame
        self.controlsFrames = controlsFrames
    }

    /// Platform baseline at `fontScale == 1.0`: 42 points for the 10-foot tvOS
    /// experience and 25 points on iPhone/iPad. The iOS value matches the former
    /// 60% rendering size, which is the appropriate native-device default.
    static var baseFontSize: CGFloat {
        #if os(iOS)
        25
        #else
        42
        #endif
    }

    private var lumaScale: Double { isHDR ? style.hdrLuminanceScale : 1.0 }

    public var body: some View {
        GeometryReader { geo in
            let rect = videoRect ?? CGRect(origin: .zero, size: geo.size)
            let origin = geo.frame(in: .global).origin
            let controls = (controlsFrames + (controlsFrame.map { [$0] } ?? []))
                .map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ZStack {
                bitmapLayer(in: rect, bounds: CGRect(origin: .zero, size: geo.size), controls: controls)
                textLayer(in: geo.size, videoRect: rect, controls: controls)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .opacity(style.opacity)          // master opacity: text + bg + edge together
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Bitmap cues (PGS / DVB / DVD)

    @ViewBuilder
    private func bitmapLayer(in rect: CGRect, bounds: CGRect, controls: [CGRect]) -> some View {
        ForEach(primary.filter(\.isImage)) { cue in
            if case .image(let img) = cue.body {
                let frame = SubtitleOverlayGeometry.bitmapRect(
                    normalizedRect: img.normalizedRect,
                    canvasSize: img.canvasSize,
                    videoRect: rect
                )
                let w = max(1, frame.width)
                let h = max(1, frame.height)
                let lift = SubtitleOverlayGeometry.upwardOffset(for: frame, avoiding: controls, in: bounds)
                Image(decorative: img.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)
                    .position(
                        x: frame.midX,
                        y: frame.midY + lift
                    )
                    // HDR-only luminance clamp on the bitmap (white-multiply dims).
                    .colorMultiply(Color(white: lumaScale))
            }
        }
    }

    // MARK: - Text cues (primary + secondary)

    /// Fraction of the container kept as a title-safe margin for edge-anchored
    /// cues, so ASS signs near a screen edge aren't lost to tvOS overscan.
    private static let titleSafeFraction: CGFloat = 0.05

    @ViewBuilder
    private func textLayer(in size: CGSize, videoRect: CGRect, controls: [CGRect]) -> some View {
        let text = primary.filter { !$0.isImage }
        // A cue whose layout is source-positioned is a sign/caption placed
        // independently in its own plane (against the video rect). Everything
        // else is dialogue and shares the user's configured default seat — so a
        // top sign never drags dialogue with it.
        let positioned = text.filter { isSourcePositioned($0) }
        let dialogue = text.filter { !isSourcePositioned($0) }

        ZStack {
            SubtitlePositionLayout(
                verticalPosition: style.verticalPosition,
                verticalAnchor: style.verticalAnchor,
                spacing: secondaryActive ? style.secondary?.gap ?? 0 : 0,
                controlsFrames: controls.map {
                    $0.offsetBy(dx: -size.width * 0.04 - style.horizontalOffset * (size.width * 0.25), dy: 0)
                }
            ) {
                dialogueStack(dialogue)
            }
            .frame(width: size.width * 0.92, height: size.height)
            .frame(width: size.width, height: size.height)
            .offset(x: style.horizontalOffset * (size.width * 0.25))

            // Positioned cues (ASS signs / captions): each honours its own
            // layout independently, placed against the video rect.
            ForEach(positioned) { cue in
                positionedCue(cue, videoRect: videoRect, bounds: CGRect(origin: .zero, size: size), controls: controls)
            }
        }
    }

    /// Places one source-positioned cue against the video rect: at its explicit
    /// normalized `anchor` when present (ASS `\pos`, VTT position), otherwise on
    /// its `\an` plane inset by the title-safe margin plus any source margins.
    @ViewBuilder
    private func positionedCue(
        _ cue: SubtitleCue, videoRect: CGRect, bounds: CGRect, controls: [CGRect]
    ) -> some View {
        if case .text(let t) = cue.body, let layout = t.layout {
            let a = layout.alignment
            let text = StyledCueText(
                text: t,
                fontSize: Self.baseFontSize * style.fontScale,
                fillColor: scaled(style.textColor),
                textAlignment: a.textAlignment,
                style: style,
                colorScale: lumaScale
            )
            let styled = text.frame(maxWidth: videoRect.width * 0.92, alignment: a.frameTextAlignment)
            if !controls.isEmpty {
                SubtitleSourcePositionLayout(
                    layout: layout, videoRect: videoRect, controlsFrames: controls,
                    titleSafeFraction: Self.titleSafeFraction
                ) { text }
                .frame(width: bounds.width, height: bounds.height)
            } else if let anchor = layout.anchor {
                styled.position(
                    x: videoRect.minX + anchor.x * videoRect.width,
                    y: videoRect.minY + anchor.y * videoRect.height
                )
            } else {
                styled
                    .padding(.leading, videoRect.width * (Self.titleSafeFraction + layout.margins.leading))
                    .padding(.trailing, videoRect.width * (Self.titleSafeFraction + layout.margins.trailing))
                    .padding(.top, videoRect.height * (Self.titleSafeFraction + layout.margins.top))
                    .padding(.bottom, videoRect.height * (Self.titleSafeFraction + layout.margins.bottom))
                    .frame(width: videoRect.width, height: videoRect.height, alignment: a.planeAlignment)
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
    }

    /// The shared default-position stack: primary dialogue plus the optional
    /// secondary (dual-subtitle) block, ordered per ``SubtitleStyle/Secondary``.
    ///
    /// When dual subtitles are on, each line gets a **fixed lane** (a reserved
    /// one-line minimum height) so neither block collapses to zero while its cue
    /// momentarily has no text. Without that, the empty block vanishes and the
    /// other line slides into the freed space — the "second track hopping up and
    /// down as the bottom line comes and goes" that dual subtitles suffer because
    /// the two tracks' cues rarely start/end together.
    @ViewBuilder
    private func dialogueStack(_ dialogue: [SubtitleCue]) -> some View {
        if secondaryActive, let sec = style.secondary {
            let above = sec.placement == .above
            let secScale = sec.differentiate ? sec.relativeScale : 1.0
            let primaryLane = reservedLineHeight(scale: 1.0)
            let secondaryLane = reservedLineHeight(scale: secScale)
            if above {
                secondaryBlock().layoutValue(key: SubtitleLaneHeight.self, value: secondaryLane)
            }
            primaryBlock(dialogue).layoutValue(key: SubtitleLaneHeight.self, value: primaryLane)
            if !above {
                secondaryBlock().layoutValue(key: SubtitleLaneHeight.self, value: secondaryLane)
            }
        } else {
            primaryBlock(dialogue)
        }
    }

    /// Height to reserve for one subtitle line at the given scale, so a dual-sub
    /// lane holds its place while its cue is momentarily empty. Tracks the font
    /// size (a constant multiple of the glyph height) rather than a fixed point
    /// value, so it stays right as the user scales subtitles.
    private func reservedLineHeight(scale: Double) -> CGFloat {
        Self.baseFontSize * CGFloat(style.fontScale) * CGFloat(scale) * 1.25
    }

    @ViewBuilder
    private func primaryBlock(_ cues: [SubtitleCue]) -> some View {
        VStack(spacing: 2) {
            ForEach(cues) { cue in
                if case .text(let t) = cue.body {
                    StyledCueText(
                        text: t,
                        fontSize: Self.baseFontSize * style.fontScale,
                        fillColor: scaled(style.textColor),
                        style: style,
                        colorScale: lumaScale
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func secondaryBlock() -> some View {
        if let sec = style.secondary {
            // Default: the secondary line inherits the primary look (colour +
            // size) so dual subs read as one system. `differentiate` opts into a
            // distinct colour/size for language-learning clarity.
            let secFill = sec.differentiate ? scaled(sec.textColor) : scaled(style.textColor)
            let secScale = sec.differentiate ? sec.relativeScale : 1.0
            VStack(spacing: 2) {
                ForEach(secondary.filter { !$0.isImage }) { cue in
                    if case .text(let t) = cue.body {
                        // A distinct second-line colour is an explicit choice, so it
                        // wins over the file's colours.
                        StyledCueText(
                            text: t,
                            fontSize: Self.baseFontSize * style.fontScale * secScale,
                            fillColor: secFill,
                            style: style,
                            colorScale: lumaScale,
                            usesSourceColors: sec.differentiate ? false : nil
                        )
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func isSourcePositioned(_ cue: SubtitleCue) -> Bool {
        guard style.usesSourcePosition else { return false }
        if case .text(let t) = cue.body { return t.layout?.isSourcePositioned == true }
        return false
    }

    /// Apply the HDR luminance scale to a colour (no-op on SDR frames).
    private func scaled(_ c: SubtitleStyle.Color) -> Color {
        let k = lumaScale
        return Color(.sRGB, red: c.red * k, green: c.green * k, blue: c.blue * k, opacity: c.alpha)
    }
}

// MARK: - ASS `\an` plane → SwiftUI placement

private extension SubtitleAlignment {
    /// The container-fill alignment that pins a positioned cue to its `\an` plane.
    var planeAlignment: Alignment {
        let h: HorizontalAlignment
        switch horizontal {
        case .leading: h = .leading
        case .center: h = .center
        case .trailing: h = .trailing
        }
        let v: VerticalAlignment
        switch vertical {
        case .top: v = .top
        case .middle: v = .center
        case .bottom: v = .bottom
        }
        return Alignment(horizontal: h, vertical: v)
    }

    /// Multi-line justification within a positioned cue's own box.
    var textAlignment: TextAlignment {
        switch horizontal {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    /// Horizontal seat of the cue box inside its max-width frame.
    var frameTextAlignment: Alignment {
        switch horizontal {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - A single styled cue line (background, outline, shadow, glyphs)

/// Draws one text cue: an optional background box (SwiftUI) wrapping the glyphs,
/// which are rendered by ``CoreTextSubtitleLine`` with a **true outer outline**
/// and shadow. This maps the high-level ``SubtitleStyle`` (border + edge) onto the
/// renderer's outline/shadow inputs:
///
/// * **Outline** — enabled by an explicit border *or* a `.uniform` edge; colour
///   from whichever is set, width = the larger of the two, scaled with the font
///   so it stays a constant fraction of the glyph height.
/// * **Shadow** — the directional edge styles (`.dropShadow` / `.raised` /
///   `.depressed`) become a soft or hard offset shadow drawn behind the outline.
struct StyledCueText: View {
    let text: SubtitleText
    let fontSize: CGFloat
    let fillColor: Color
    var textAlignment: TextAlignment = .center
    let style: SubtitleStyle
    /// HDR luminance scale applied to source colours, matching `fillColor`.
    var colorScale: Double = 1
    var usesSourceColors: Bool? = nil

    var body: some View {
        renderedLine
    }

    var renderedLine: CoreTextSubtitleLine {
        CoreTextSubtitleLine(
            text: text.string,
            family: style.fontFamily,
            weight: style.fontWeight,
            fontSize: fontSize,
            isBold: allowsSourceFont && text.isBold,
            isItalic: allowsSourceFont && text.isItalic,
            fill: UIColor(fillColor),
            outline: outlineUIColor,
            outlineWidth: visibleOutlineWidth,
            shadow: shadowSpec,
            background: backgroundSpec,
            alignment: nsAlignment,
            fillSpans: fillSpans,
            systemFontDescriptor: fontDescriptor,
            glyphBackground: style.glyphBackground.alpha > 0 ? uiColor(style.glyphBackground) : nil
        )
    }

    private var allowsSourceFont: Bool {
        style.usesSourceEmphasis
    }

    private var fontDescriptor: UIFontDescriptor? {
        style.resolvedFontDescriptor
    }

    /// The file's colour spans, as UTF-16 ranges, when the style honours them.
    /// Uncoloured spans are left to `fillColor`.
    private var fillSpans: [SubtitleFillSpan] {
        guard usesSourceColors != false, let runs = text.runs else { return [] }
        var spans: [SubtitleFillSpan] = []
        var location = 0
        for run in runs {
            let length = (run.text as NSString).length
            if let source = run.color, let c = style.sourceTextColor(source) {
                let k = colorScale
                spans.append(SubtitleFillSpan(
                    location: location, length: length,
                    color: UIColor(red: c.red * k, green: c.green * k, blue: c.blue * k, alpha: c.alpha)
                ))
            }
            location += length
        }
        return spans
    }

    /// The rounded background box, drawn inside the renderer so it hugs the text
    /// box at the user's padding while big outlines/shadows can overflow freely.
    private var backgroundSpec: SubtitleBackgroundSpec? {
        guard style.background.isEnabled else { return nil }
        return SubtitleBackgroundSpec(
            color: uiColor(style.background.color),
            cornerRadius: style.background.cornerRadius,
            horizontalPadding: style.background.horizontalPadding,
            verticalPadding: style.background.verticalPadding)
    }

    /// Colour of the uniform outline (explicit border wins over a `.uniform` edge).
    private var outlineUIColor: UIColor? {
        if style.border.isEnabled { return uiColor(style.border.color) }
        if style.edge.style == .uniform { return uiColor(style.edge.color) }
        return nil
    }

    /// Visible outline width: the larger of the explicit border and a `.uniform`
    /// edge, scaled with the font so it tracks the glyph size (≈ a constant % of
    /// the text height) instead of being fixed in points at every scale.
    private var visibleOutlineWidth: CGFloat {
        var w: CGFloat = 0
        if style.border.isEnabled { w = max(w, style.border.width) }
        if style.edge.style == .uniform { w = max(w, style.edge.thickness) }
        guard w > 0 else { return 0 }
        return w * (fontSize / SubtitleOverlayView.baseFontSize)
    }

    /// Directional edge → a shadow spec (the `.uniform` edge is an outline, not a
    /// shadow, so it produces none here).
    private var shadowSpec: SubtitleShadowSpec? {
        let c = uiColor(style.edge.color)
        let t = CGFloat(style.edge.thickness) * (fontSize / SubtitleOverlayView.baseFontSize)
        guard t > 0 else { return nil }
        switch style.edge.style {
        case .dropShadow: return SubtitleShadowSpec(offset: CGSize(width: t * 0.6, height: t * 0.6), blur: t, color: c)
        case .raised:     return SubtitleShadowSpec(offset: CGSize(width: t, height: t), blur: 0, color: c)
        case .depressed:  return SubtitleShadowSpec(offset: CGSize(width: -t, height: -t), blur: 0, color: c)
        case .none, .uniform: return nil
        }
    }

    private var nsAlignment: NSTextAlignment {
        switch textAlignment {
        case .leading: return .left
        case .trailing: return .right
        default: return .center
        }
    }

    private func uiColor(_ c: SubtitleStyle.Color) -> UIColor {
        UIColor(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
#endif
