#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import CoreModels
import SwiftUI

struct PlaybackOptionsPane: View {
    static let zoomSlot = 0
    static let speedSlot = 2
    static let upscalingSlot = 4
    static let versionSlot = 5
    static let multiviewSlot = 6
    static var customSlot: Int { modeSlot(.custom) }

    static func modeSlot(_ mode: PlayerVideoZoom.Mode) -> Int { 10 + mode.rawValue }

    let model: PlayerControlsModel
    let zoom: PlayerVideoZoomModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    let screen: PlayerControls.PlaybackScreen
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var speedOnly = false
    var additionalRows: [PlayerOptionsRowSpec] = []
    let openScreen: (PlayerControls.PlaybackScreen) -> Void

    var body: some View {
        let rows = rows
        PlayerOptionsInputScope(
            screen: screen, rows: rows, focus: $focus,
            content: content(rows: rows)
        )
    }

    @ViewBuilder
    private func content(rows: [PlayerOptionsRowSpec]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if screen == .upscaling {
                PlayerMenuRowStack(rows: VideoUpscaling.allCases.enumerated().map { index, selection in
                    PlayerControls.TrackRow(
                        id: index, header: nil, title: Text(selection.title), subtitle: nil,
                        isSelected: model.upscaling.selection == selection, isToggle: false,
                        action: { actions.setVideoUpscaling(selection) }
                    )
                }, palette: palette, focus: $focus)
                .disabled(model.upscaling.isChanging)
                if model.upscaling.isChanging {
                    Text("Applying…")
                        .font(.caption)
                        .plozzForeground(.secondary)
                        .padding(16)
                }
            }
            if screen == .zoom {
                PlayerMenuRowStack(rows: zoom.availableModes.filter { $0 != .custom }.map { mode in
                    PlayerControls.TrackRow(
                        id: Self.modeSlot(mode), header: nil, title: Text(mode.menuTitle),
                        subtitle: nil,
                        isSelected: zoom.settings.mode == mode, isToggle: false,
                        action: {
                            zoom.settings.mode = mode
                            openScreen(.options)
                        }
                    )
                }, palette: palette, focus: $focus)
            }
            ForEach(rows) { row in
                PlayerOptionsRow(row: row, palette: palette, focus: $focus)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    var rows: [PlayerOptionsRowSpec] {
        Self.rows(
            model: model, zoom: zoom, actions: actions, screen: screen,
            speedOnly: speedOnly, additionalRows: additionalRows, openScreen: openScreen
        )
    }

    static func rows(
        model: PlayerControlsModel, zoom: PlayerVideoZoomModel,
        actions: PlayerOptionsActions,
        screen: PlayerControls.PlaybackScreen = .options,
        speedOnly: Bool = false,
        additionalRows: [PlayerOptionsRowSpec] = [],
        openScreen: @escaping (PlayerControls.PlaybackScreen) -> Void
    ) -> [PlayerOptionsRowSpec] {
        if speedOnly {
            guard model.engineCapabilities.contains(.playbackSpeed) else { return [] }
            return [.init(slot: Self.speedSlot, title: "Speed", kind: .number(
                value: Text(verbatim: PlayerControls.speedLabel(model.playbackSpeed)),
                step: { delta in
                    let index = PlayerControls.nearestSpeedIndex(model.playbackSpeed)
                    let next = min(max(index + delta, 0), PlayerControls.speedGridCount - 1)
                    actions.setPlaybackSpeed(PlayerControls.speedGridValue(next))
                }
            ))]
        }
        if screen == .upscaling || screen == .version { return [] }
        if screen == .zoom {
            return [.init(slot: Self.customSlot, title: "Custom", kind: .number(
                value: Text(Double(zoom.settings.customPercent) / 100, format: .percent.precision(.fractionLength(0))),
                step: { zoom.setCustomPercent(zoom.settings.customPercent + $0) }
            ), isSelected: zoom.settings.mode == .custom)]
        }
        var rows = additionalRows
        if model.engineCapabilities.contains(.videoZoom) {
            rows.append(.init(slot: Self.zoomSlot, title: "Zoom Mode", kind: .submenu(
                summary: Text(zoom.settings.mode.title),
                open: { openScreen(.zoom) }
            )))
        }
        if model.upscaling.isAvailable {
            rows.append(.init(slot: Self.upscalingSlot, title: "Upscaling", kind: .submenu(
                summary: Text(model.upscaling.selection.title), open: { openScreen(.upscaling) }
            )))
        }
        if model.felConversion.isAvailable {
            rows.append(.init(slot: 3, title: "P7 FEL → P8.1 conversion", kind: .toggle(
                isOn: model.felConversion.isEnabled,
                flip: { actions.setDolbyVisionFELConversion(!model.felConversion.isEnabled) }
            )))
        }
        if model.versions.isAvailable {
            rows.append(.init(slot: Self.versionSlot, title: "Version", kind: .submenu(
                summary: Text(verbatim: ""), open: { openScreen(.version) }
            )))
        }
        return rows
    }
}
#endif
