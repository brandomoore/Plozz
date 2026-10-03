#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import SwiftUI

struct PlaybackOptionsPane: View {
    static let zoomSlot = 0
    static let amountSlot = 20
    static let speedSlot = 2
    static let customSlot = 12

    static func modeSlot(_ mode: PlayerVideoZoom.Mode) -> Int { 10 + mode.rawValue }

    let model: PlayerControlsModel
    let zoom: PlayerVideoZoomModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    let screen: PlayerControls.PlaybackScreen
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var offersPlaybackSpeed = true
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
            if screen == .zoom {
                PlayerMenuRowStack(rows: [PlayerVideoZoom.Mode.fit, .fill].map { mode in
                    PlayerControls.TrackRow(
                        id: Self.modeSlot(mode), header: nil, title: Text(mode.title), subtitle: nil,
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
            offersPlaybackSpeed: offersPlaybackSpeed, openScreen: openScreen
        )
    }

    static func rows(
        model: PlayerControlsModel, zoom: PlayerVideoZoomModel,
        actions: PlayerOptionsActions,
        screen: PlayerControls.PlaybackScreen = .options,
        offersPlaybackSpeed: Bool = true,
        openScreen: @escaping (PlayerControls.PlaybackScreen) -> Void
    ) -> [PlayerOptionsRowSpec] {
        if screen == .customZoom {
            return [.init(slot: Self.amountSlot, title: "Zoom Amount", kind: .number(
                value: Text(Double(zoom.settings.customPercent) / 100, format: .percent.precision(.fractionLength(0))),
                step: { zoom.setCustomPercent(zoom.settings.customPercent + $0) }
            ))]
        }
        if screen == .zoom {
            return [.init(slot: Self.customSlot, title: "Custom", kind: .submenu(
                summary: Text(Double(zoom.settings.customPercent) / 100, format: .percent.precision(.fractionLength(0))),
                open: {
                    zoom.settings.mode = .custom
                    openScreen(.customZoom)
                }
            ))]
        }
        var rows: [PlayerOptionsRowSpec] = []
        if model.engineCapabilities.contains(.videoZoom) {
            rows.append(.init(slot: Self.zoomSlot, title: "Zoom Mode", kind: .submenu(
                summary: Text(zoom.settings.mode.title),
                open: { openScreen(.zoom) }
            )))
        }
        if offersPlaybackSpeed, model.engineCapabilities.contains(.playbackSpeed) {
            rows.append(.init(slot: Self.speedSlot, title: "Playback Speed", kind: .number(
                value: Text(verbatim: PlayerControls.speedLabel(model.playbackSpeed)),
                step: { delta in
                    let index = PlayerControls.nearestSpeedIndex(model.playbackSpeed)
                    let next = min(max(index + delta, 0), PlayerControls.speedGridCount - 1)
                    actions.setPlaybackSpeed(PlayerControls.speedGridValue(next))
                }
            )))
        }
        return rows
    }
}
#endif
