#if os(iOS)
import CoreModels
import SwiftUI
import UIKit

@MainActor
public enum PlayerAudioMenu {
    public static func make(
        options: [PlayerTrackOption],
        dialogueEnhancement: Bool? = nil,
        locale: Locale = .current,
        onSelect: @escaping (PlayerTrackOption.ID) -> Void,
        onSetDialogueEnhancement: @escaping (Bool) -> Void = { _ in }
    ) -> UIMenu {
        func localized(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource) // l10n:content - native menu boundary; use the app's current locale.
        }
        var children: [UIMenuElement] = []
        if !options.isEmpty {
            let tracks = options.map { option in
                UIAction(
                    title: option.nativeTitle,
                    attributes: options.count == 1 ? [.disabled] : [],
                    state: option.isSelected ? .on : .off
                ) { _ in onSelect(option.id) }
            }
            children.append(UIMenu(options: [.displayInline, .singleSelection], children: tracks))
        }
        if let dialogueEnhancement {
            let choices = [false, true].map { enabled in
                UIAction(
                    title: localized(enabled ? "On" : "Off"),
                    state: dialogueEnhancement == enabled ? .on : .off
                ) { _ in onSetDialogueEnhancement(enabled) }
            }
            children.append(UIMenu(
                title: localized("Enhance Dialogue"), options: .singleSelection, children: choices
            ))
        }
        return UIMenu(title: localized("Audio"), children: children)
    }
}

public struct PlayerAudioMenuButton: View {
    public let options: [PlayerTrackOption]
    public var dialogueEnhancement: Bool?
    public var accessibilityIdentifier: String
    public let onSelect: (PlayerTrackOption.ID) -> Void
    public let onSetDialogueEnhancement: (Bool) -> Void
    public let onPresentationChange: (Bool) -> Void
    @Environment(\.locale) private var locale

    public init(
        options: [PlayerTrackOption],
        dialogueEnhancement: Bool? = nil,
        accessibilityIdentifier: String = "player-audio",
        onSelect: @escaping (PlayerTrackOption.ID) -> Void,
        onSetDialogueEnhancement: @escaping (Bool) -> Void = { _ in },
        onPresentationChange: @escaping (Bool) -> Void
    ) {
        self.options = options
        self.dialogueEnhancement = dialogueEnhancement
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onSelect = onSelect
        self.onSetDialogueEnhancement = onSetDialogueEnhancement
        self.onPresentationChange = onPresentationChange
    }

    public var body: some View {
        if !options.isEmpty || dialogueEnhancement != nil {
            PlayerOptionsMenuButton(
                kind: .audio, accessibilityIdentifier: accessibilityIdentifier,
                makeMenu: {
                    PlayerAudioMenu.make(
                        options: options, dialogueEnhancement: dialogueEnhancement, locale: locale,
                        onSelect: onSelect, onSetDialogueEnhancement: onSetDialogueEnhancement
                    )
                },
                onPresentationChange: onPresentationChange
            )
            .frame(width: 44, height: 44)
        }
    }
}
#endif
