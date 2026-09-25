#if canImport(SwiftUI)
import CoreModels
import MediaAccessibility
import SwiftUI

/// The appearance editor needs a style mirror and edit callbacks, not a player.
@MainActor
public struct SubtitleStyleEditingContext {
    public let controls: PlayerControlsModel
    let offersDualSubtitles: Bool
    let secondaryPreview: Binding<Bool>?
    private let update: (SubtitleStyle) -> Void
    private let selectSecondary: (Int) -> Void
    private let systemCaptionStyle: SystemCaptionStyle

    public init(player: PlayerViewModel) {
        controls = player.controls
        offersDualSubtitles = true
        systemCaptionStyle = .shared
        secondaryPreview = nil
        update = { player.applySubtitleStyle($0) }
        selectSecondary = { player.selectSecondarySubtitleOption(id: $0) }
    }

    init(
        controls: PlayerControlsModel, style: Binding<SubtitleStyle>, secondaryPreview: Binding<Bool>,
        systemCaptionStyle: SystemCaptionStyle = .shared, offersDualSubtitles: Bool = true
    ) {
        self.controls = controls
        self.offersDualSubtitles = offersDualSubtitles
        self.systemCaptionStyle = systemCaptionStyle
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
        offersDualSubtitles && (secondaryPreview?.wrappedValue ?? controls.secondarySubtitleOptions.contains {
            $0.isSelected && $0.id != PlayerTrackOption.offID
        })
    }

    func applySubtitleStyle(_ style: SubtitleStyle) { update(style) }
    var effectiveStyle: SubtitleStyle { systemCaptionStyle.resolved(controls.subtitleStyle) }

    func editSubtitleStyle(_ mutate: (inout SubtitleStyle) -> Void) {
        let next = systemCaptionStyle.editing(controls.subtitleStyle, mutate)
        if next != controls.subtitleStyle { update(next) }
    }
    func selectSecondarySubtitleOption(id: Int) { selectSecondary(id) }
}

enum SubtitleStyleEditorValues {
    static func edgeName(_ style: SubtitleStyle) -> LocalizedStringResource {
        if let raw = style.captionEdgeStyleRawValue {
            if raw == Int(MACaptionAppearanceTextEdgeStyle.undefined.rawValue) { return "Unspecified (Shadow)" }
            let known: [MACaptionAppearanceTextEdgeStyle] = [.none, .raised, .depressed, .uniform, .dropShadow]
            if !known.contains(where: { Int($0.rawValue) == raw }) { return "Unrecognized (Shadow)" }
        }
        return style.edge.style.displayName
    }

    static func color(_ color: SubtitleColor) -> String {
        let components = [color.red, color.green, color.blue].map {
            $0.formatted(.number.precision(.fractionLength(0...4)))
        }
        return "RGB " + components.joined(separator: ", ")
    }
}
#endif
