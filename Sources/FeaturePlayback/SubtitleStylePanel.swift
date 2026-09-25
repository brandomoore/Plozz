#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

/// The live subtitle-appearance editor, extracted from `PlayerControls`. Hosts
/// the Style screen and its detail sub-screens (Font / Shadow & Outline /
/// Background / Dual Subtitles) over the running video so every tweak previews
/// instantly on the real subtitles behind the panel.
///
/// It owns only the appearance-editing content and its hold-to-accelerate ramp
/// (`styleAccelerator`); the panel morph + focus-restore choreography stays in
/// `PlayerControls` and is reached through the injected `openScreen` closure
/// (which forwards to the parent's `openSubtitleScreen`, preserving the deferred
/// focus write). Edits funnel through `updateStyle` -> `actions.setSubtitleStyle`
/// exactly as before, so live preview + profile persistence are unchanged.
struct SubtitleStylePanel: View {
    static let panelWidth: CGFloat = 520

    /// Which style sub-screen to render (style / styleFont / styleOutline /
    /// styleBackground / styleDual). Non-style screens are never routed here.
    let screen: PlayerControls.SubtitleScreen
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    /// Forwards to `PlayerControls.openSubtitleScreen`, which animates the panel
    /// morph and defers the focus write. Kept in the parent so the fragile
    /// focus-restore choreography is unchanged by this extraction.
    let openScreen: (PlayerControls.SubtitleScreen) -> Void
    var secondaryPreview: Binding<Bool>? = nil

    /// Hold-to-accelerate state for the numeric style rows (see the field in the
    /// former PlayerControls home). Lives here because only `handleStyleMove`
    /// touches it.
    @State private var styleAccelerator = SubtitleStyleAccelerator()
    private var effectiveStyle: SubtitleStyle { SystemCaptionStyle.shared.resolved(model.subtitleStyle) }

    @ViewBuilder
    var body: some View {
        switch screen {
        case .style:
            // A bitmap primary (PGS/DVD/…) is pre-rendered by the source, so NONE
            // of the appearance controls apply. Replace the whole editor with a
            // centered explanation rather than showing dead knobs.
            if let format = model.secondarySubtitleImagePrimaryFormat {
                styleUnavailableForImageSubtitle(format: format)
            } else {
                let main = styleMainRows
                styleScreen(main.rows, dividerBefore: main.dividerBefore)
            }
        case .styleFont: styleFontScreen
        case .styleSystemFont: systemFontScreen
        case .styleOutline: styleScreen(styleOutlineRows)
        case .styleBackground: styleScreen(styleBackgroundRows)
        case .styleDual: styleScreen(styleDualRows)
        default: EmptyView()
        }
    }


    struct StyleRowSpec: Identifiable {
        enum Kind {
            /// Numeric range: ←/→ step (hold to accelerate), Select nudges up one.
            /// `step` moves by a signed number of grid indices, clamped at the ends.
            case number(value: Text, step: (Int) -> Void)
            /// Small enum: Select cycles next (wrap); ←/→ cycle; no ± glyphs.
            case choice(value: Text, prev: () -> Void, next: () -> Void)
            /// On/off: Select flips.
            case toggle(isOn: Bool, flip: () -> Void)
            /// Opens a detail sub-screen: Select opens; shows a `›` chevron.
            case submenu(summary: Text, open: () -> Void)
            /// One-shot: Select runs it.
            case action(run: () -> Void)
        }
        let slot: Int
        let title: LocalizedStringResource
        let kind: Kind
        var id: Int { slot }
    }

    /// The live subtitle-appearance editor, hosted over the running video so every
    /// tweak previews instantly on the real subtitles behind the panel. Each row is
    /// a single full-width Button (one focus target spanning the width, so vertical
    /// focus lands predictably), value right-aligned. Steppers reveal −/+ glyphs
    /// only while focused (press ←/→ on the remote to adjust); the container's
    /// `.onMoveCommand` — attached to the non-focusable VStack so children keep
    /// native up/down nav — dispatches those left/right steps to the focused row.
    /// Edits funnel through `updateStyle` → `actions.setSubtitleStyle` (live overlay
    /// + profile persistence). Back lives in the panel header.
    @ViewBuilder
    private func styleScreen(_ rows: [StyleRowSpec], dividerBefore: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(rows) { row in
                if let d = dividerBefore, row.slot == d {
                    PlozzDivider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                styleRow(row)
            }
            if screen == .style {
                Text("Matching shows the device’s current values. Editing a value keeps this appearance and turns matching off.")
                    .font(.footnote).playerMenuRowSecondary().padding(16)
            } else if screen == .styleBackground {
                Text("Window padding is set by Plozz. Apple does not expose caption padding or line spacing. File override preferences apply only when a cue supplies that attribute.")
                    .font(.footnote).playerMenuRowSecondary().padding(16)
            } else if screen == .styleOutline {
                Text("Apple supplies the text edge style, including Uniform Outline, but not its color or thickness. Those are Plozz rendering values.")
                    .font(.footnote).playerMenuRowSecondary().padding(16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
        .plozzMoveCommand { direction in
            handleStyleMove(direction, rows: rows)
        }
    }

    /// One rendered row, laid out to match the track/audio rows exactly: a full-width
    /// Button with the title hard-left and the value/glyph hard-right, so titles and
    /// values carry equal edge gutters. Steppers reveal −/+ flanking the value on
    /// focus; submenus show a trailing chevron.
    @ViewBuilder
    private func styleRow(_ row: StyleRowSpec) -> some View {
        let isFocused = focus == .row(row.slot)
        Button {
            switch row.kind {
            case let .number(_, step): step(1)
            case let .choice(_, _, next): next()
            case let .toggle(_, flip): flip()
            case let .submenu(_, open): open()
            case let .action(run): run()
            }
        } label: {
            // Mirror the track/audio rows exactly: title hard-left, a Spacer, and
            // the value/glyph hard-right against the same trailing padding the
            // checkmark uses. Title and trailing element therefore carry equal edge
            // gutters (no extra leading slot pushing the title in).
            HStack(spacing: 10) {
                Text(row.title).font(.body).lineLimit(1)
                Spacer(minLength: 8)
                styleRowTrailing(row, isFocused: isFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.slot))
    }

    @ViewBuilder
    private func styleRowTrailing(_ row: StyleRowSpec, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            // − appears on focus for steppers, immediately left of the value.
            if case .number = row.kind, isFocused {
                Image(systemName: "minus").font(.body.weight(.semibold))
            }

            styleRowValue(row)

            // + on focus for steppers, or a persistent chevron for submenus — both
            // sit at the trailing edge, exactly where the track rows put their
            // checkmark, so the value column hugs the right like every other menu.
            switch row.kind {
            case .number:
                if isFocused { Image(systemName: "plus").font(.body.weight(.semibold)) }
            case .submenu:
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .playerMenuRowSecondary()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func styleRowValue(_ row: StyleRowSpec) -> some View {
        switch row.kind {
        case let .number(value, _):
            value.font(.body).monospacedDigit().playerMenuRowSecondary()
        case let .choice(value, _, _):
            value.font(.body).lineLimit(2).multilineTextAlignment(.trailing).playerMenuRowSecondary()
        case let .toggle(isOn, _):
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
        case let .submenu(summary, _):
            summary.font(.body).playerMenuRowSecondary()
        case .action:
            EmptyView()
        }
    }

    /// Container-level ←/→ handler: looks up the focused slot's row and steps it.
    /// Up/down are left to the native focus engine (single column → left/right
    /// find no sibling, so focus stays put and this handler fires instead).
    private func handleStyleMove(_ direction: PlozzMoveCommandDirection, rows: [StyleRowSpec]) {
        guard case let .row(slot)? = focus,
              let row = rows.first(where: { $0.slot == slot }) else { return }
        switch (direction, row.kind) {
        case let (.left, .number(_, step)):
            step(-styleAccelerator.magnitude(slot: slot, sign: -1))
        case let (.right, .number(_, step)):
            step(styleAccelerator.magnitude(slot: slot, sign: 1))
        case let (.left, .choice(_, prev, _)):
            prev()
        case let (.right, .choice(_, _, next)):
            next()
        default:
            break
        }
    }

    // MARK: Per-screen row builders

    /// Main flat Style screen: the common per-glyph knobs, a divider, then the
    /// submenu groups (outline/border, background box, dual subtitles) and Reset.
    /// The submenus own the quick control as their first row *and* echo its current
    /// value as their summary, so there is exactly one entry per concern here.
    /// Controls always show the effective look, including while matching.
    private var styleMainRows: (rows: [StyleRowSpec], dividerBefore: Int) {
        let s = effectiveStyle
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(StyleRowSpec(slot: slot, title: "Use System Caption Style", kind: .toggle(isOn: s.followsSystemStyle, flip: { updateStyle { $0.followsSystemStyle.toggle() } }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Font", kind: .submenu(summary: Text(verbatim: s.fontDisplayName), open: { openScreen(.styleFont) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Weight", kind: .choice(
            value: Text(verbatim: s.fontWeightDisplayName),
            prev: { updateStyle { $0.selectFontWeight(SubtitleSystemFonts.adjacentWeight(for: s, forward: false)) } },
            next: { updateStyle { $0.selectFontWeight(SubtitleSystemFonts.adjacentWeight(for: s, forward: true)) } }
        ))); slot += 1
        rows.append(numberRow(slot, "Text Size", options: Self.sizeOptions, current: Int((s.fontScale * 100).rounded()), displayValue: Text(s.fontScale, format: .percent.precision(.fractionLength(0...3))), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.fontScale = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(
            slot, "Position",
            options: Self.positionOptions,
            current: Int((s.verticalPosition / SubtitleStyle.verticalPositionStep).rounded()),
            label: { Text(Double($0) * SubtitleStyle.verticalPositionStep, format: .percent.precision(.fractionLength(0...1))) }
        ) { v in updateStyle { $0.verticalPosition = Double(v) * SubtitleStyle.verticalPositionStep } }); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Use File Positions", kind: .toggle(isOn: s.usesSourcePosition, flip: { updateStyle { $0.usesSourcePosition.toggle() } }))); slot += 1
        rows.append(choiceRow(
            slot,
            LocalizedStringResource(
                "Extra Line Position",
                comment: "Subtitle setting for where additional wrapped lines appear: Above, Center, or Below. Not the placement of a second-language subtitle track."
            ),
            options: SubtitleStyle.VerticalAnchor.allCases,
            current: s.verticalAnchor,
            label: { $0.displayName }
        ) { v in updateStyle { $0.verticalAnchor = v } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Offset", options: Self.hOffsetOptions, current: Int((s.horizontalOffset * 100).rounded()), label: { Text(PlayerControlsFormatting.hOffsetLabel($0)) }) { v in updateStyle { $0.horizontalOffset = Double(v) / 100 } }); slot += 1
        rows.append(colorRow(slot, "Text Color", options: Self.textColorOptions, current: s.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.textColor = c } }); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Use File Colors", kind: .toggle(isOn: s.usesSourceColors, flip: { updateStyle { $0.usesSourceColors.toggle() } }))); slot += 1
        rows.append(numberRow(slot, "Text Opacity", options: Self.alphaOptions, current: Int((s.textColor.alpha * 100).rounded()), displayValue: Text(s.textColor.alpha, format: .percent.precision(.fractionLength(0...3))), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.textColor.alpha = Double(v) / 100 } }); slot += 1
        rows.append(numberRow(slot, "Overall Opacity", options: Self.opacityOptions, current: Int((s.opacity * 100).rounded()), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.opacity = Double(v) / 100 } }); slot += 1
        if s.captionSourceOverrides != nil {
            rows.append(sourceOverrideRow(slot, "Allow File Font", keyPath: \.font)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Size", keyPath: \.relativeSize)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Text Color", keyPath: \.foregroundColor)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Text Opacity", keyPath: \.foregroundOpacity)); slot += 1
        }
        // Only affects HDR frames, so it appears exclusively while HDR is live —
        // mirroring how the bitmap-primary gate hides controls that can't act.
        if model.subtitlesRenderHDR {
            rows.append(numberRow(slot, "HDR Brightness", options: Self.hdrBrightnessOptions, current: Int((s.hdrLuminanceScale * 100).rounded()), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.hdrLuminanceScale = Double(v) / 100 } }); slot += 1
        }

        // The submenu group + Reset sit under a divider, wherever the knobs above end.
        let dividerBefore = slot
        rows.append(StyleRowSpec(slot: slot, title: "Shadow & Outline", kind: .submenu(summary: Text(SubtitleStyleEditorValues.edgeName(s)), open: { openScreen(.styleOutline) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Background", kind: .submenu(summary: s.background.isEnabled || s.glyphBackground.alpha > 0 ? Text("On") : Text("Off"), open: { openScreen(.styleBackground) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Dual Subtitles", kind: .submenu(summary: hasSecondaryTrack ? Text("On") : Text("Off"), open: { openScreen(.styleDual) }))); slot += 1
        rows.append(StyleRowSpec(slot: slot, title: "Reset to Default", kind: .action(run: { actions.setSubtitleStyle(.profileDefault) }))); slot += 1
        return (rows, dividerBefore)
    }

    /// The Font picker: one selectable row per family, each rendered **in its own
    /// typeface** (a touch larger than the value rows) so the list previews itself.
    /// Selecting a font applies it and returns to the Style screen; the chosen
    /// weight persists and is re-snapped to the new family's available weights by
    /// the renderer and the Weight row.
    @ViewBuilder
    private var styleFontScreen: some View {
        let current = effectiveStyle.fontFamily
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SubtitleFontFamily.allCases.enumerated()), id: \.offset) { idx, family in
                fontChoiceRow(family, index: idx, isSelected: effectiveStyle.fontDescriptor == nil && effectiveStyle.systemFont == nil && family == current)
            }
            styleRow(StyleRowSpec(
                slot: SubtitleFontFamily.allCases.count, title: "System",
                kind: .submenu(
                    summary: Text(verbatim: effectiveStyle.fontDescriptor?.displayName ?? effectiveStyle.systemFont.map(SubtitleSystemFonts.displayName) ?? ""),
                    open: { openScreen(.styleSystemFont) }
                )
            ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func fontChoiceRow(_ family: SubtitleFontFamily, index: Int, isSelected: Bool) -> some View {
        Button {
            updateStyle { $0.fontFamily = family; $0.systemFont = nil; $0.fontDescriptor = nil }
            openScreen(.style)
        } label: {
            HStack(spacing: 10) {
                Text(family.displayName)
                    .font(Self.fontPreviewFont(for: family))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .playerMenuRowMark(isSelected: isSelected, accent: palette.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(index))
    }

    private var systemFontScreen: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SubtitleSystemFonts.all.enumerated()), id: \.element.id) { index, entry in
                Button {
                    updateStyle { $0.systemFont = entry.id; $0.fontDescriptor = nil }
                    openScreen(.style)
                } label: {
                    HStack(spacing: 10) {
                        Text(verbatim: entry.name).font(entry.preview).lineLimit(1).minimumScaleFactor(0.5)
                        Spacer(minLength: 8)
                        Image(systemName: effectiveStyle.systemFont == entry.id ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .playerMenuRowMark(isSelected: effectiveStyle.systemFont == entry.id, accent: palette.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlayerMenuRowButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .row(index))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// A SwiftUI `Font` that renders a family's name in that family's own Regular
    /// face — named faces via their PostScript name, SF via the system font, and
    /// SF Rounded via the rounded system design.
    private static func fontPreviewFont(for family: SubtitleFontFamily) -> Font {
        // OpenDyslexic's wide, heavy letterforms already read large, so it gets a
        // smaller preview; every other family is bumped up for a bolder, more
        // legible list.
        let size: CGFloat = family == .openDyslexic ? 30 : 40
        if family.usesRoundedDesign { return .system(size: size, design: .rounded) }
        if let name = family.postScriptNameCandidates().first { return .custom(name, size: size) }
        return .system(size: size)
    }

    /// Apple's edge style includes uniform outline. The independent custom
    /// outline remains available; all values stay visible, even when disabled.
    private var styleOutlineRows: [StyleRowSpec] {
        let s = effectiveStyle
        var rows: [StyleRowSpec] = []
        var slot = 0

        rows.append(choiceRow(slot, "Text Edge", options: Self.shadowStyleOptions, current: s.edge.style, displayValue: Text(SubtitleStyleEditorValues.edgeName(s)), label: { $0.displayName }) { v in updateStyle { $0.edge.style = v } }); slot += 1
        rows.append(colorRow(slot, "Edge Color", options: Self.textColorOptions, current: s.edge.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.edge.color = c } }); slot += 1
        rows.append(numberRow(slot, "Edge Thickness", options: Self.thicknessOptions, current: Int(s.edge.thickness.rounded()), displayValue: Text(s.edge.thickness, format: .number.precision(.fractionLength(0...3))), label: { Text(verbatim: "\($0)") }) { v in updateStyle { $0.edge.thickness = Double(v) } }); slot += 1
        if s.captionSourceOverrides != nil {
            rows.append(sourceOverrideRow(slot, "Allow File Edge", keyPath: \.edge)); slot += 1
        }

        rows.append(StyleRowSpec(slot: slot, title: "Outline", kind: .toggle(isOn: s.border.isEnabled, flip: { updateStyle { $0.border.isEnabled.toggle() } }))); slot += 1
            rows.append(colorRow(slot, "Outline Color", options: Self.textColorOptions, current: s.border.color, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.border.color = c } }); slot += 1
            rows.append(numberRow(slot, "Outline Width", options: Self.thicknessOptions, current: Int(s.border.width.rounded()), label: { Text(verbatim: "\($0)") }) { v in updateStyle { $0.border.width = Double(v) } }); slot += 1
        return rows
    }

    /// Background box: colour, its own opacity, corner radius and padding.
    private var styleBackgroundRows: [StyleRowSpec] {
        let s = effectiveStyle
        var rows: [StyleRowSpec] = [
            StyleRowSpec(slot: 0, title: "Show Window", kind: .toggle(isOn: s.background.isEnabled, flip: { updateStyle { $0.background.isEnabled.toggle() } })),
        ]
        var slot = 1
        rows.append(colorRow(slot, "Window Color", options: Self.boxColorOptions, current: s.background.color, label: PlayerControlsFormatting.boxColorLabel) { c in updateStyle { $0.background.color = c } }); slot += 1
        rows.append(numberRow(slot, "Window Opacity", options: Self.alphaOptions, current: Int((s.background.color.alpha * 100).rounded()), displayValue: Text(s.background.color.alpha, format: .percent.precision(.fractionLength(0...3))), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.background.color.alpha = Double(v) / 100; $0.background.isEnabled = v > 0 } }); slot += 1
        rows.append(numberRow(slot, "Corner Radius", options: Self.cornerOptions, current: Int(s.background.cornerRadius.rounded()), displayValue: Text(s.background.cornerRadius, format: .number.precision(.fractionLength(0...3))), label: { Text(PlayerControlsFormatting.cornerLabel($0)) }) { v in updateStyle { $0.background.cornerRadius = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Horizontal Padding (Plozz)", options: Self.paddingOptions, current: Int(s.background.horizontalPadding.rounded()), label: { Text(verbatim: "\($0)") }) { v in updateStyle { $0.background.horizontalPadding = Double(v) } }); slot += 1
        rows.append(numberRow(slot, "Vertical Padding (Plozz)", options: Self.paddingOptions, current: Int(s.background.verticalPadding.rounded()), label: { Text(verbatim: "\($0)") }) { v in updateStyle { $0.background.verticalPadding = Double(v) } }); slot += 1
        rows.append(colorRow(slot, "Line Background Color", options: Self.textColorOptions, current: s.glyphBackground, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.glyphBackground = c } }); slot += 1
        rows.append(numberRow(slot, "Line Background Opacity", options: Self.alphaOptions, current: Int((s.glyphBackground.alpha * 100).rounded()), displayValue: Text(s.glyphBackground.alpha, format: .percent.precision(.fractionLength(0...3))), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.glyphBackground.alpha = Double(v) / 100 } }); slot += 1
        if s.captionSourceOverrides != nil {
            rows.append(sourceOverrideRow(slot, "Allow File Line Color", keyPath: \.backgroundColor)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Line Opacity", keyPath: \.backgroundOpacity)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Window Color", keyPath: \.windowColor)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Window Opacity", keyPath: \.windowOpacity)); slot += 1
            rows.append(sourceOverrideRow(slot, "Allow File Window Corners", keyPath: \.windowCornerRadius)); slot += 1
        }
        return rows
    }

    /// True when a real (non-"Off") second subtitle track is currently selected,
    /// so the main Style screen can label "Dual Subtitles" On/Off correctly.
    private var hasSecondaryTrack: Bool {
        if let secondaryPreview { return secondaryPreview.wrappedValue }
        guard let sel = model.secondarySubtitleOptions.first(where: { $0.isSelected }) else { return false }
        return sel.id != PlayerTrackOption.offID
    }

    /// Dual subtitles: pick a second track to show a second line, then (optionally)
    /// distinguish its look. The picker lists text tracks the overlay can draw
    /// (excluding the primary); its styling rows appear only once a track is on.
    private var styleDualRows: [StyleRowSpec] {
        let s = effectiveStyle
        let secOptions = model.secondarySubtitleOptions
        let count = secOptions.count
        let currentIdx = secOptions.firstIndex(where: { $0.isSelected }) ?? 0
        let step: (Int) -> Void = { delta in
            guard count > 0 else { return }
            let next = secOptions[((currentIdx + delta) % count + count) % count]
            actions.selectSecondarySubtitle(next.id)
        }
        let selected = secOptions.first(where: { $0.isSelected })
        let hasTrack = secondaryPreview?.wrappedValue
            ?? (selected != nil && selected?.id != PlayerTrackOption.offID)
        // Base value = the selected option's label; when a real track is selected,
        // annotate it with the live load status so the viewer can see whether it's
        // fetching, has no lines in this file, or the sidecar was unavailable —
        // instead of a silent blank second line. When the primary is a bitmap sub,
        // dual mode is disallowed (a PGS/DVD line can't be positioned), so say so
        // explicitly rather than the ambiguous "None available".
        let baseValue: Text
        if let format = model.secondarySubtitleImagePrimaryFormat {
            baseValue = Text(
                "Disabled for \(format)",
                comment: "Shown on the Second Track row when dual subtitles are disallowed because the primary subtitle is an image-based (bitmap) format like PGS or VobSub."
            )
        } else if secOptions.isEmpty {
            baseValue = Text(
                "None available",
                comment: "Shown on the Second Track row when there are no eligible tracks to show as a second subtitle line."
            )
        } else {
            baseValue = secOptions[currentIdx].title
        }
        let trackValue = hasTrack ? baseValue + Self.secondaryStatusSuffix(model.secondarySubtitleStatus) : baseValue
        var rows: [StyleRowSpec]
        if let secondaryPreview {
            rows = [StyleRowSpec(slot: 0, title: "Show second subtitle", kind: .toggle(
                isOn: secondaryPreview.wrappedValue, flip: { secondaryPreview.wrappedValue.toggle() }
            ))]
        } else {
            rows = [StyleRowSpec(slot: 0, title: "Second Track", kind: .choice(
                value: trackValue,
                prev: { step(-1) },
                next: { step(1) }
            ))]
        }
        if hasTrack, let sec = s.secondary {
            var slot = 1
            rows.append(choiceRow(slot, "Placement", options: SubtitleStyle.Secondary.Placement.allCases, current: sec.placement, label: { $0 == .above ? "Above" : "Below" }) { v in updateStyle { $0.secondary?.placement = v } }); slot += 1
            rows.append(StyleRowSpec(slot: slot, title: "Distinct Style", kind: .toggle(isOn: sec.differentiate, flip: { updateStyle { $0.secondary?.differentiate.toggle() } }))); slot += 1
            // Size + Colour only take effect when the secondary uses a distinct
            // style — otherwise the renderer mirrors the primary's size/colour
            // (see SubtitleOverlayView). Hide them while Distinct Style is off so
            // they're not dead controls.
            if sec.differentiate {
                rows.append(numberRow(slot, "Size", options: Self.secondarySizeOptions, current: Int((sec.relativeScale * 100).rounded()), label: { Text(verbatim: "\($0)%") }) { v in updateStyle { $0.secondary?.relativeScale = Double(v) / 100 } }); slot += 1
                rows.append(colorRow(slot, "Color", options: Self.textColorOptions, current: sec.textColor, label: PlayerControlsFormatting.colorLabel) { c in updateStyle { $0.secondary?.textColor = c } }); slot += 1
            }
            rows.append(numberRow(slot, "Gap", options: Self.gapOptions, current: Int(sec.gap.rounded()), label: { Text(verbatim: "\($0)") }) { v in updateStyle { $0.secondary?.gap = Double(v) } }); slot += 1
        }
        return rows
    }

    /// A short suffix annotating the selected second track with its live load
    /// state. Always shows the outcome (loading / cue count / no lines /
    /// unavailable) so a track that fetched cues but still won't draw is
    /// distinguishable on-screen from one that genuinely returned nothing.
    ///
    /// Returns `Text`, not a `String`: "loading…"/"no lines"/"unavailable" are
    /// Plozz's own copy, and "N cues" is a count that needs plural variations —
    /// composing them into a plain string first (as this used to) would hide
    /// that copy from the catalog. The leading "  ·  " separator is punctuation,
    /// kept verbatim.
    private static func secondaryStatusSuffix(_ status: SecondarySubtitleStatus) -> Text {
        let separator = Text(verbatim: "  ·  ")
        switch status {
        case .idle:
            return Text(verbatim: "")
        case .loading:
            return separator + Text(
                "loading…",
                comment: "Live status suffix shown next to the selected second subtitle track while its sidecar is being fetched."
            )
        case .loaded(let n) where n > 0:
            return separator + Text(
                "\(n) cues",
                comment: "Live status suffix showing how many subtitle lines (cues) were loaded for the selected second subtitle track."
            )
        case .loaded:
            return separator + Text(
                "no lines",
                comment: "Live status suffix shown when the selected second subtitle track loaded successfully but contained no lines for this file."
            )
        case .unavailable:
            return separator + Text(
                "unavailable",
                comment: "Live status suffix shown when the selected second subtitle track's sidecar could not be fetched or decoded."
            )
        }
    }

    // MARK: Row constructors

    /// Numeric stepper row over an Int grid; preserves the displayed off-grid
    /// value, snapping only the starting step index. Steps by a
    /// signed number of grid indices and clamps at both ends (no wrap), so a fast
    /// hold-to-accelerate run parks at Bottom/Top instead of jumping across.
    private func numberRow(_ slot: Int, _ title: LocalizedStringResource, options: [Int], current: Int, displayValue: Text? = nil, label: @escaping (Int) -> Text, apply: @escaping (Int) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = Self.nearestIndex(options, current)
        return StyleRowSpec(slot: slot, title: title, kind: .number(
            value: displayValue ?? label(current),
            step: { delta in
                let target = min(max(idx + delta, 0), n - 1)
                if target != idx { apply(options[target]) }
            }
        ))
    }

    /// Cycle row over any small `Equatable` set; wraps at both ends.
    private func choiceRow<V: Equatable>(_ slot: Int, _ title: LocalizedStringResource, options: [V], current: V, displayValue: Text? = nil, label: @escaping (V) -> LocalizedStringResource, apply: @escaping (V) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(of: current) ?? 0
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: displayValue ?? Text(label(current)),
            prev: { apply(options[(idx - 1 + n) % n]) },
            next: { apply(options[(idx + 1) % n]) }
        ))
    }

    /// Cycle row over a colour palette, matched by RGB so it recognises the current
    /// swatch regardless of its alpha, and preserves that alpha on change (so the
    /// separate opacity knobs stay independent of the colour choice).
    private func colorRow(_ slot: Int, _ title: LocalizedStringResource, options: [SubtitleColor], current: SubtitleColor, label: @escaping (SubtitleColor) -> String, apply: @escaping (SubtitleColor) -> Void) -> StyleRowSpec {
        let n = options.count
        let idx = options.firstIndex(where: { $0.red == current.red && $0.green == current.green && $0.blue == current.blue }) ?? 0
        func withAlpha(_ c: SubtitleColor) -> SubtitleColor { SubtitleColor(red: c.red, green: c.green, blue: c.blue, alpha: current.alpha) }
        return StyleRowSpec(slot: slot, title: title, kind: .choice(
            value: Text(verbatim: label(current) == "Custom" ? SubtitleStyleEditorValues.color(current) : label(current)),
            prev: { apply(withAlpha(options[(idx - 1 + n) % n])) },
            next: { apply(withAlpha(options[(idx + 1) % n])) }
        ))
    }

    /// Reads the mirror, applies the mutation, and routes the result through the
    /// live-apply + persist funnel. Single write path for every appearance control.
    private func updateStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        let next = SystemCaptionStyle.shared.editing(model.subtitleStyle, mutate)
        if next != model.subtitleStyle { actions.setSubtitleStyle(next) }
    }

    private func sourceOverrideRow(
        _ slot: Int, _ title: LocalizedStringResource,
        keyPath: WritableKeyPath<SubtitleCaptionSourceOverrides, Bool>
    ) -> StyleRowSpec {
        StyleRowSpec(slot: slot, title: title, kind: .toggle(
            isOn: effectiveStyle.captionSourceOverrides?[keyPath: keyPath] ?? true,
            flip: { updateStyle { $0.captionSourceOverrides?[keyPath: keyPath].toggle() } }
        ))
    }

    // MARK: Option grids

    // Precise, numeric option grids — no "low / high" buckets.
    private static let sizeOptions = SubtitleStyle.fontScalePercentages
    private static let positionOptions = SubtitleStyle.verticalPositionOptions.map {
        Int(($0 / SubtitleStyle.verticalPositionStep).rounded())
    }
    /// Horizontal nudge as a signed percentage of the max offset (±25% of width);
    /// 0 = centred. Lets subtitles dodge burned-in signage / letterbox furniture.
    private static let hOffsetOptions: [Int] = Array(stride(from: -100, through: 100, by: 5))
    private static let opacityOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    /// Public foreground/background/window alpha includes fully transparent.
    private static let alphaOptions: [Int] = Array(stride(from: 0, through: 100, by: 5))
    /// Subtitle HDR white-point scale, shown as a percentage. Mirrors the model's
    /// `hdrLuminanceScale` (0.2–1.0); only surfaced while HDR is live.
    private static let hdrBrightnessOptions: [Int] = Array(stride(from: 20, through: 100, by: 5))
    private static let thicknessOptions: [Int] = Array(stride(from: 0, through: 10, by: 1))
    /// All public device edge styles, including uniform outline.
    private static let shadowStyleOptions: [SubtitleEdgeStyle] = [.none, .dropShadow, .raised, .depressed, .uniform]
    /// Corner radius in points, then a large sentinel the box renderer clamps to a
    /// perfect capsule (`UIBezierPath` caps the radius at half the shorter side),
    /// so the top of the range always reads as "fully rounded" at any box size.
    private static let cornerFull = PlayerControlsFormatting.cornerFull
    private static let cornerOptions: [Int] = Array(stride(from: 0, through: 40, by: 2)) + [cornerFull]
    private static let paddingOptions: [Int] = Array(stride(from: 0, through: 40, by: 2))
    private static let gapOptions: [Int] = Array(stride(from: 0, through: 24, by: 2))
    private static let secondarySizeOptions: [Int] = Array(stride(from: 50, through: 100, by: 5))
    private static let textColorOptions: [SubtitleColor] = SubtitleColor.presets.map(\.color)
    // RGB representatives (alpha handled by the Box Opacity knob).
    private static let boxColorOptions: [SubtitleColor] = [
        SubtitleColor(red: 0, green: 0, blue: 0, alpha: 1),
        SubtitleColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),
        SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)
    ]

    private static func nearestIndex(_ options: [Int], _ value: Int) -> Int {
        PlayerControlsFormatting.nearestIndex(options, value)
    }

    /// Shown in place of the whole style editor when the primary subtitle is a
    /// bitmap (PGS/DVD/DVB/VobSub): those cues are pre-rendered images by the
    /// source, so none of the font/colour/size/position controls apply. A calm
    /// centered card explains why rather than presenting dead knobs.
    private func styleUnavailableForImageSubtitle(format: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "photo")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.white.opacity(0.5))
            Text("\(format) subtitles can't be restyled")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("They're rendered as images by the source, so font, color, size and position controls don't apply.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
#endif
