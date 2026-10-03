#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import SwiftUI

struct PlaybackOptionsPane: View {
    static let zoomSlot = 0
    static let amountSlot = 1
    static let speedSlot = 2

    let model: PlayerControlsModel
    let zoom: PlayerVideoZoomModel
    let palette: ThemePalette
    let actions: PlayerOptionsActions
    let screen: PlayerControls.PlaybackScreen
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var offersPlaybackSpeed = true
    let openSpeed: () -> Void

    var body: some View {
        let rows = rows
        PlayerOptionsInputScope(
            screen: screen, rows: screen == .options ? rows : [], focus: $focus,
            content: content(rows: rows)
        )
    }

    @ViewBuilder
    private func content(rows: [PlayerOptionsRowSpec]) -> some View {
        switch screen {
        case .options:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows) { row in
                    PlayerOptionsRow(row: row, palette: palette, focus: $focus)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        case .speed:
            SpeedPaneView(model: model, palette: palette, actions: actions, focus: $focus)
        }
    }

    var rows: [PlayerOptionsRowSpec] {
        Self.rows(model: model, zoom: zoom, offersPlaybackSpeed: offersPlaybackSpeed, openSpeed: openSpeed)
    }

    static func rows(
        model: PlayerControlsModel, zoom: PlayerVideoZoomModel,
        offersPlaybackSpeed: Bool = true, openSpeed: @escaping () -> Void
    ) -> [PlayerOptionsRowSpec] {
        var rows: [PlayerOptionsRowSpec] = []
        if model.engineCapabilities.contains(.videoZoom) {
            rows.append(.init(slot: Self.zoomSlot, title: "Zoom Mode", kind: .choice(
                value: Text(zoom.settings.mode.title),
                prev: { zoom.cycleMode(forward: false) },
                next: { zoom.cycleMode(forward: true) }
            )))
            if zoom.settings.mode == .custom {
                rows.append(.init(slot: Self.amountSlot, title: "Zoom Amount", kind: .number(
                    value: Text(Double(zoom.settings.customPercent) / 100, format: .percent.precision(.fractionLength(0))),
                    step: { zoom.setCustomPercent(zoom.settings.customPercent + $0) }
                )))
            }
        }
        if offersPlaybackSpeed, model.engineCapabilities.contains(.playbackSpeed) {
            rows.append(.init(slot: Self.speedSlot, title: "Playback Speed", kind: .submenu(
                summary: Text(verbatim: PlayerControls.speedLabel(model.playbackSpeed)),
                open: openSpeed
            )))
        }
        return rows
    }
}
#endif
