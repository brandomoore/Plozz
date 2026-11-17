#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CoreUI
import CoreModels

struct PlayerOptionsDivider: View {
    @Environment(\.plozzHDRDisplayActive) private var hdrDisplayActive

    var body: some View {
        Color.primary.opacity(hdrDisplayActive ? 0.10 : 0.16)
            .frame(height: PlozzFrostedSurface.dividerHeight)
    }
}

/// A reusable full-width column of selectable / toggle track rows, extracted from
/// `PlayerControls`. Shared by the Subtitles track list and the Audio pane — both
/// render the same compact rows (title, optional external badge / subtitle,
/// selection mark), differing only in the `TrackRow` data they feed in. Each row
/// binds to the shared `@FocusState` via its stable `row(id)` slot, so focus
/// behaviour is identical wherever the stack is used.
struct PlayerMenuRowStack: View {
    let rows: [PlayerControls.TrackRow]
    let palette: ThemePalette
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: rows.contains { $0.versionPresentation != nil } ? 12 : 2) {
            ForEach(rows) { row in
                if row.startsSection {
                    PlayerOptionsDivider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .accessibilityHidden(true)
                }
                if let presentation = row.versionPresentation {
                    MediaVersionChoiceButton(
                        presentation: presentation,
                        isSelected: row.isSelected,
                        isFocused: focus == .row(row.id),
                        action: row.action
                    )
                    .accessibilityIdentifier("player-option-row-\(row.id)")
                    .focused($focus, equals: .row(row.id))
                } else if let submenu = row.submenu {
                    PlayerOptionsRow(row: submenu, palette: palette, focus: $focus, titleLineLimit: 2)
                } else if row.isToggle {
                    compactToggleRow(row)
                } else {
                    compactSelectableRow(row)
                }
            }
        }
    }

    private func compactSelectableRow(_ row: PlayerControls.TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    #if os(tvOS)
                    if row.marqueeTitle {
                        MarqueeText(text: row.title)
                    } else {
                        row.title.font(.body).lineLimit(row.titleLineLimit)
                    }
                    #else
                    row.title.font(.body).lineLimit(row.titleLineLimit)
                    #endif
                    if let facts = row.facts {
                        facts
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let subtitle = row.subtitle {
                        subtitle
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(2)
                            .truncationMode(row.facts == nil ? .tail : .middle)
                    }
                }
                .multilineTextAlignment(.leading)
                if row.isExternal {
                    // Marks a subtitle that isn't embedded in the video — one you
                    // downloaded this session, or a local sidecar file — so it's
                    // findable in a list full of same-language embedded tracks.
                    ExternalSubtitleBadge()
                }
                Spacer(minLength: 8)
                if row.isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .accessibilityIdentifier("player-option-row-\(row.id)")
        .accessibilityAddTraits(row.isSelected ? .isSelected : [])
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }

    private func compactToggleRow(_ row: PlayerControls.TrackRow) -> some View {
        Button(action: row.action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    row.title.font(.body.weight(.medium)).lineLimit(1)
                    if let subtitle = row.subtitle {
                        subtitle
                            .font(.caption2)
                            .playerMenuRowSecondary()
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if row.isUpdating {
                    ProgressView()
                } else {
                    Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .playerMenuRowMark(isSelected: row.isSelected, accent: palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        #if os(tvOS)
        .accessibilityIdentifier("player-option-row-\(row.id)")
        .accessibilityValue(row.isUpdating ? Text("Updating") : (row.isSelected ? Text("On") : Text("Off")))
        #endif
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.id))
    }
}

/// The Audio menu: one full-width column of selectable tracks (plus any Dialog
/// Enhance toggle row baked into the row data). Extracted from `PlayerControls`;
/// the parent still computes the `audioRows` (its selection state feeds the
/// focus logic too) and passes them in.
struct AudioPaneView: View {
    let rows: [PlayerControls.TrackRow]
    let palette: ThemePalette
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let close: () -> Void

    @ViewBuilder
    var body: some View {
        if rows.isEmpty {
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 12) {
                Text("No audio controls available")
                    .font(.title3)
                    .plozzForeground(.secondary)
                Button("Back", action: close)
                    .buttonStyle(PlayerMenuRowButtonStyle())
                    .focusEffectDisabled()
                    .focused($focus, equals: .subBack)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            #else
            Text("No alternate audio")
                .font(.title3)
                .plozzForeground(.secondary)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            #endif
        } else {
            PlayerMenuRowStack(rows: rows, palette: palette, focus: $focus)
                .padding(.horizontal, 14)
        }
    }
}

/// The Speed menu: a fine − {value}× + stepper (0.25×–2× in 0.05 steps) over a
/// divider and a short list of quick presets, all driving the same
/// `model.playbackSpeed`. Extracted from `PlayerControls`; the speed grid math
/// stays on `PlayerControls` as shared statics.
struct SpeedPaneView: View {
    let model: PlayerControlsModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fine control: − {value}× + in 0.05 steps (0.25×–2×). Drives the same
            // model.playbackSpeed as the presets below, so they stay in sync.
            HStack {
                Spacer(minLength: 0)
                SettingsStepper(
                    options: Array(0..<PlayerControls.speedGridCount),
                    selection: Binding(
                        get: { PlayerControls.nearestSpeedIndex(model.playbackSpeed) },
                        set: { actions.setPlaybackSpeed(PlayerControls.speedGridValue($0)) }
                    ),
                    compact: true,
                    verbatimTitle: { PlayerControls.speedLabel(PlayerControls.speedGridValue($0)) }
                )
                Spacer(minLength: 0)
            }
            // The enclosing ScrollView already adds 10pt above this pane, so give
            // the stepper less top / more bottom padding to visually center it
            // between the panel header and the presets divider (≈14pt each side).
            .padding(.top, 4)
            .padding(.bottom, 14)

            Divider()
                .background(.white.opacity(0.12))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            // Quick presets.
            ForEach(Array(PlayerControls.speedPresets.enumerated()), id: \.offset) { index, speed in
                selectableRow(
                    title: Text(verbatim: PlayerControls.speedLabel(speed)),
                    isSelected: abs(model.playbackSpeed - speed) < 0.001,
                    index: index
                ) {
                    actions.setPlaybackSpeed(speed)
                }
            }
        }
    }

    private func selectableRow(
        title: Text,
        isSelected: Bool,
        index: Int,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                title.font(.body).lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .playerMenuRowMark(isSelected: true, accent: palette.accent)
                }
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

/// The A/V Sync menu: shared Audio Sync and coarse Subtitle Delay steppers,
/// each gated on the running engine's capabilities. Extracted
/// from `PlayerControls`; the shared `delayLabel` formatter stays on
/// `PlayerControls` (the subtitle-sync screen uses it too).
struct SyncPaneView: View {
    let model: PlayerControlsModel
    let actions: PlayerOptionsActions
    @FocusState.Binding var focus: PlayerControls.FocusSlot?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if model.engineCapabilities.contains(.audioDelay) {
                AudioSyncScreen(model: model, actions: actions, focus: $focus)
            }
            if model.engineCapabilities.contains(.subtitleDelay) {
                delayRow(
                    title: "Subtitle Delay",
                    value: model.subtitleDelaySeconds,
                    firstSlot: 10,
                    onAdjust: { actions.setSubtitleDelay(model.subtitleDelaySeconds + $0) },
                    onReset: { actions.setSubtitleDelay(0) }
                )
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
    }

    private func delayRow(
        title: LocalizedStringResource,
        value: TimeInterval,
        firstSlot: Int,
        onAdjust: @escaping (TimeInterval) -> Void,
        onReset: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.medium))
                Spacer()
                Text(PlayerControls.delayLabel(value))
                    .monospacedDigit()
                    .plozzForeground(.secondary)
            }
            HStack(spacing: 12) {
                stepButton("−500 ms", slot: firstSlot + 0) { onAdjust(-0.5) }
                stepButton("−50 ms", slot: firstSlot + 1) { onAdjust(-0.05) }
                stepButton("Reset", slot: firstSlot + 2, action: onReset)
                stepButton("+50 ms", slot: firstSlot + 3) { onAdjust(0.05) }
                stepButton("+500 ms", slot: firstSlot + 4) { onAdjust(0.5) }
            }
        }
    }

    private func stepButton(_ title: LocalizedStringResource, slot: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout.weight(.medium))
        }
        .focused($focus, equals: .row(slot))
    }
}
#endif
