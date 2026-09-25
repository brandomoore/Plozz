#if canImport(SwiftUI)
import CoreModels
import SwiftUI

/// The appearance editor needs a style mirror and edit callbacks, not a player.
@MainActor
public struct SubtitleStyleEditingContext {
    public let controls: PlayerControlsModel
    let secondaryPreview: Binding<Bool>?
    private let update: (SubtitleStyle) -> Void
    private let selectSecondary: (Int) -> Void

    public init(player: PlayerViewModel) {
        controls = player.controls
        secondaryPreview = nil
        update = { player.applySubtitleStyle($0) }
        selectSecondary = { player.selectSecondarySubtitleOption(id: $0) }
    }

    init(controls: PlayerControlsModel, style: Binding<SubtitleStyle>, secondaryPreview: Binding<Bool>) {
        self.controls = controls
        self.secondaryPreview = secondaryPreview
        update = {
            controls.subtitleStyle = $0
            style.wrappedValue = $0
        }
        selectSecondary = { _ in
            assertionFailure("A style preview cannot select a playback track.")
        }
    }

    var hasSecondarySubtitle: Bool {
        secondaryPreview?.wrappedValue ?? controls.secondarySubtitleOptions.contains {
            $0.isSelected && $0.id != PlayerTrackOption.offID
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) { update(style) }
    func selectSecondarySubtitleOption(id: Int) { selectSecondary(id) }
}
#endif
