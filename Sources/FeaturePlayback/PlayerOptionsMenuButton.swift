#if os(iOS)
import CoreUI
import SwiftUI
import UIKit

@MainActor
final class PlayerOverflowOrigin {
    weak var surface: UIView?
}

struct PlayerOverflowSurface: UIViewRepresentable {
    let origin: PlayerOverflowOrigin

    func makeUIView(context: Context) -> UIView {
        let surface = UIView()
        surface.isAccessibilityElement = false
        origin.surface = surface
        return surface
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Builds a native menu only when opened, not on the player's clock updates.
public struct PlayerOptionsMenuButton: UIViewRepresentable {
    public enum Kind {
        case playbackOptions, settings, audio, subtitles, speed, video

        var symbol: String {
            switch self {
            case .playbackOptions, .settings: "ellipsis"
            case .audio: PlayerControls.Category.audio.icon
            case .subtitles: PlayerControls.Category.subtitles.icon
            case .speed: "speedometer"
            case .video: PlayerControls.Category.playback.icon
            }
        }

        var label: LocalizedStringResource {
            switch self {
            case .playbackOptions: "Playback options"
            case .settings: "Playback settings"
            case .audio: "Audio"
            case .subtitles: "Subtitles"
            case .speed: "Playback Speed"
            case .video: "Video"
            }
        }

        var identifier: String {
            switch self {
            case .playbackOptions: "player-playback-options"
            case .settings: "player-settings"
            case .audio: "player-audio"
            case .subtitles: "player-subtitles"
            case .speed: "player-playback-speed"
            case .video: "player-video"
            }
        }
    }

    private let kind: Kind
    private let valueTitle: String?
    private var overflowOrigin: PlayerOverflowOrigin?
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
        self.valueTitle = nil
        self.accessibilityIdentifier = accessibilityIdentifier ?? kind.identifier
        self.makeMenu = makeMenu
        self.onPresentationChange = { _, presented in onPresentationChange(presented) }
    }

    public init(
        kind: Kind = .playbackOptions,
        valueTitle: String? = nil,
        accessibilityIdentifier: String? = nil,
        makeMenu: @escaping @MainActor () -> UIMenu?,
        onPresentationChange: @escaping @MainActor (UUID, Bool) -> Void
    ) {
        self.kind = kind
        self.valueTitle = valueTitle
        self.accessibilityIdentifier = accessibilityIdentifier ?? kind.identifier
        self.makeMenu = makeMenu
        self.onPresentationChange = onPresentationChange
    }

    func anchorOverflow(at origin: PlayerOverflowOrigin?) -> Self {
        var copy = self
        copy.overflowOrigin = origin
        return copy
    }

    public func makeUIView(context: Context) -> UIButton {
        let button = PlayerOptionsMenuControl(type: .system)
        if valueTitle == nil {
            button.setImage(UIImage(systemName: kind.symbol,
                                    withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)), for: .normal)
        } else {
            button.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        }
        button.tintColor = context.environment.playerControlTint
        // Scope the native media menu's light labels to its owner, never the player or sheets.
        button.overrideUserInterfaceStyle = .dark
        button.showsMenuAsPrimaryAction = true
        button.isContextMenuInteractionEnabled = true
        button.preferredMenuElementOrder = .fixed
        if let overflowOrigin { button.anchorOverflow(at: overflowOrigin) }
        button.accessibilityIdentifier = accessibilityIdentifier
        return button
    }

    public func updateUIView(_ uiView: UIButton, context: Context) {
        guard let button = uiView as? PlayerOptionsMenuControl else { return }
        button.tintColor = context.environment.playerControlTint
        button.menuProvider = makeMenu
        button.setTitle(valueTitle, for: .normal)
        button.accessibilityValue = valueTitle
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
        button.presentationInteraction?.dismissMenu()
        button.removeOverflowAnchor()
        if wasPresented {
            DispatchQueue.main.async { notify?(false) }
        }
    }
}

final class PlayerOptionsMenuControl: UIButton {
    private var overflowAnchor: PlayerOptionsMenuControl?
    var presentationInteraction: UIContextMenuInteraction? { overflowAnchor?.contextMenuInteraction ?? contextMenuInteraction }

    func anchorOverflow(at origin: PlayerOverflowOrigin) {
        let anchor = PlayerOptionsMenuControl(type: .custom)
        anchor.isAccessibilityElement = false
        anchor.accessibilityElementsHidden = true
        anchor.showsMenuAsPrimaryAction = true
        anchor.isContextMenuInteractionEnabled = true
        anchor.overrideUserInterfaceStyle = .dark
        anchor.preferredMenuElementOrder = .fixed
        anchor.menuProvider = { [weak self] in self?.menuProvider?() }
        anchor.onPresentationChange = { [weak self, weak anchor] presented in
            self?.onPresentationChange?(presented)
            if !presented { anchor?.removeFromSuperview() }
        }
        overflowAnchor = anchor
        showsMenuAsPrimaryAction = false
        isContextMenuInteractionEnabled = false
        addAction(UIAction { [weak self] _ in
            guard let self, let anchor = overflowAnchor, let surface = origin.surface else { return }
            anchor.frame = surface.bounds
            surface.addSubview(anchor)
            anchor.performPrimaryAction()
        }, for: .primaryActionTriggered)
    }

    func removeOverflowAnchor() { overflowAnchor?.removeFromSuperview() }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: max(44, size.width + (currentTitle == nil ? 0 : 8)), height: max(44, size.height))
    }

    let presentationOwner = UUID()
    var menuProvider: (@MainActor () -> UIMenu?)?
    var onPresentationChange: (@MainActor (Bool) -> Void)?
    private var snapshot: UIMenu?
    var presentedMenu: UIMenu? { overflowAnchor?.presentedMenu ?? snapshot }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let menu: UIMenu
        if let presentedMenu {
            menu = presentedMenu
        } else {
            guard let provided = menuProvider?(), !provided.children.isEmpty else { return nil }
            menu = provided
            snapshot = menu
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
            self?.snapshot = nil
            self?.onPresentationChange?(false)
        }
        if let animator { animator.addCompletion(finish) } else { finish() }
    }
}
#endif
