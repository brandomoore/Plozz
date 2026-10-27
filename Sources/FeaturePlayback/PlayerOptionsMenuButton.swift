#if os(iOS)
import CoreUI
import SwiftUI
import UIKit

/// Builds a native menu only when opened, not on the player's clock updates.
public struct PlayerOptionsMenuButton: UIViewRepresentable {
    public enum Kind {
        case playbackOptions, audio, subtitles, speed, video

        var symbol: String {
            switch self {
            case .playbackOptions: "ellipsis"
            case .audio: PlayerControls.Category.audio.icon
            case .subtitles: PlayerControls.Category.subtitles.icon
            case .speed: "speedometer"
            case .video: PlayerControls.Category.playback.icon
            }
        }

        var label: LocalizedStringResource {
            switch self {
            case .playbackOptions: "Playback options"
            case .audio: "Audio"
            case .subtitles: "Subtitles"
            case .speed: "Playback Speed"
            case .video: "Video"
            }
        }

        var identifier: String {
            switch self {
            case .playbackOptions: "player-playback-options"
            case .audio: "player-audio"
            case .subtitles: "player-subtitles"
            case .speed: "player-playback-speed"
            case .video: "player-video"
            }
        }
    }

    private let kind: Kind
    private let accessibilityIdentifier: String
    private let makeMenu: @MainActor () -> UIMenu?
    private let onPresentationChange: @MainActor (UUID, Bool) -> Void
    @Environment(\.locale) private var locale

    public init(
        kind: Kind = .playbackOptions,
        accessibilityIdentifier: String? = nil,
        makeMenu: @escaping @MainActor () -> UIMenu?,
        onPresentationChange: @escaping @MainActor (Bool) -> Void
    ) {
        self.kind = kind
        self.accessibilityIdentifier = accessibilityIdentifier ?? kind.identifier
        self.makeMenu = makeMenu
        self.onPresentationChange = { _, presented in onPresentationChange(presented) }
    }

    public init(
        kind: Kind = .playbackOptions,
        accessibilityIdentifier: String? = nil,
        makeMenu: @escaping @MainActor () -> UIMenu?,
        onPresentationChange: @escaping @MainActor (UUID, Bool) -> Void
    ) {
        self.kind = kind
        self.accessibilityIdentifier = accessibilityIdentifier ?? kind.identifier
        self.makeMenu = makeMenu
        self.onPresentationChange = onPresentationChange
    }

    public func makeUIView(context: Context) -> UIButton {
        let button = PlayerOptionsMenuControl(type: .system)
        button.setImage(UIImage(systemName: kind.symbol,
                                withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)), for: .normal)
        button.tintColor = context.environment.playerControlTint
        // Scope the native media menu's light labels to its owner, never the player or sheets.
        button.overrideUserInterfaceStyle = .dark
        button.showsMenuAsPrimaryAction = true
        button.isContextMenuInteractionEnabled = true
        button.preferredMenuElementOrder = .fixed
        button.accessibilityIdentifier = accessibilityIdentifier
        return button
    }

    public func updateUIView(_ uiView: UIButton, context: Context) {
        guard let button = uiView as? PlayerOptionsMenuControl else { return }
        button.tintColor = context.environment.playerControlTint
        button.menuProvider = makeMenu
        let owner = button.presentationOwner
        button.onPresentationChange = { onPresentationChange(owner, $0) }
        var label = kind.label
        label.locale = locale
        button.accessibilityLabel = String(localized: label) // l10n:content - UIKit accessibility boundary; updated with the current environment locale.
    }

    public static func dismantleUIView(_ uiView: UIButton, coordinator: ()) {
        guard let button = uiView as? PlayerOptionsMenuControl else { return }
        let wasPresented = button.presentedMenu != nil
        let notify = button.onPresentationChange
        button.onPresentationChange = nil
        button.menuProvider = nil
        button.contextMenuInteraction?.dismissMenu()
        if wasPresented {
            DispatchQueue.main.async { notify?(false) }
        }
    }
}

final class PlayerOptionsMenuControl: UIButton {
    let presentationOwner = UUID()
    var menuProvider: (@MainActor () -> UIMenu?)?
    var onPresentationChange: (@MainActor (Bool) -> Void)?
    private(set) var presentedMenu: UIMenu?

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let menu: UIMenu
        if let presentedMenu {
            menu = presentedMenu
        } else {
            guard let provided = menuProvider?(), !provided.children.isEmpty else { return nil }
            menu = provided
            presentedMenu = menu
            onPresentationChange?(true)
        }
        let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
        // This custom configuration must also preserve top-to-bottom order when opening upward.
        configuration.preferredMenuElementOrder = .fixed
        return configuration
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        let finish: () -> Void = { [weak self] in
            self?.presentedMenu = nil
            self?.onPresentationChange?(false)
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }
}
#endif
