#if os(iOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit

public enum PlayerMenuDestination: String, Identifiable {
    case subtitleSearch, subtitleAdvanced, audioSync, speed, zoom, quality, versions, multiview, timestamps
    public var id: Self { self }
}

public enum PlayerMenuLayout: Equatable {
    case consolidated, separate

    public init(size: CGSize) {
        self = size.width > size.height ? .separate : .consolidated
    }
}

public enum PlayerMenuSection: String, CaseIterable, Identifiable {
    case subtitles, audio, speed = "playback-speed", video, versions, multiview, timestamps
    public var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .speed: "Playback Speed"
        case .video: "Video"
        case .versions: "Version"
        case .multiview: "Multiview"
        case .timestamps: "Community timestamps"
        }
    }

    var kind: PlayerOptionsMenuButton.Kind? {
        switch self {
        case .subtitles: .subtitles
        case .audio: .audio
        case .speed: .speed
        case .video: .video
        case .versions, .multiview, .timestamps: nil
        }
    }

    var destination: PlayerMenuDestination? {
        switch self {
        case .versions: .versions
        case .multiview: .multiview
        case .timestamps: .timestamps
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .versions: "rectangle.stack"
        case .multiview: "rectangle.split.2x2"
        case .timestamps: "list.bullet.rectangle"
        default: kind?.symbol ?? "ellipsis"
        }
    }
}

/// A native menu's dismissal completion, not a timer, releases sheet requests.
@MainActor @Observable
public final class PlayerMenuPresentation {
    public private(set) var isPresented = false
    public private(set) var destination: PlayerMenuDestination?
    public private(set) var generation: UInt64 = 0
    private var pending: PlayerMenuDestination?
    @ObservationIgnored private var owners = Set<UUID>()
    private let defaultOwner = UUID()
    public var isBusy: Bool { isPresented || pending != nil || destination != nil }

    public init() {}

    public func setPresented(_ presented: Bool, owner: UUID? = nil) {
        let owner = owner ?? defaultOwner
        if presented { owners.insert(owner) }
        else if owners.remove(owner) == nil { return }
        isPresented = !owners.isEmpty
        if !isPresented, let pending {
            self.pending = nil
            destination = pending
        }
    }

    public func request(_ destination: PlayerMenuDestination, generation: UInt64) {
        guard generation == self.generation else { return }
        if isPresented { pending = destination }
        else { self.destination = destination }
    }

    public func takeDestination() -> PlayerMenuDestination? {
        guard !isPresented else { return nil }
        defer { destination = nil }
        return destination
    }

    public func reset() {
        generation &+= 1
        owners.removeAll()
        pending = nil
        destination = nil
        isPresented = false
    }
}

public struct PlayerMoreMenuAvailability {
    public var maximumSpeed: Double?
    public var video: Bool
    public var videoModel: PlayerVideoZoomModel?
    public var quality: Bool
    public var versions: Bool
    public var multiview: Bool
    public var timestamps: Bool

    public init(
        maximumSpeed: Double? = nil, video: Bool = true, videoModel: PlayerVideoZoomModel? = nil, quality: Bool = false,
        versions: Bool = false, multiview: Bool = false, timestamps: Bool = false
    ) {
        self.maximumSpeed = maximumSpeed
        self.video = video
        self.videoModel = videoModel
        self.quality = quality
        self.versions = versions
        self.multiview = multiview
        self.timestamps = timestamps
    }
}

@MainActor
public struct PlayerMoreMenuActions {
    public var isCurrent: () -> Bool = { true }
    public var selectAudio: (Int) -> Void = { _ in }
    public var selectSubtitle: (Int) -> Void = { _ in }
    public var setDialogueEnhancement: (Bool) -> Void = { _ in }
    public var setSpeed: (Double) -> Void = { _ in }
    public var request: (PlayerMenuDestination) -> Void = { _ in }
    public init() {}
}

@MainActor
public enum PlayerMoreMenu {
    public static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    public static func hasOptions(_ model: PlayerControlsModel, availability: PlayerMoreMenuAvailability) -> Bool {
        !sections(model, availability: availability).isEmpty
    }

    public static func sections(_ model: PlayerControlsModel, availability: PlayerMoreMenuAvailability) -> [PlayerMenuSection] {
        var sections: [PlayerMenuSection] = []
        if !model.subtitleOptions.isEmpty || model.subtitleDownload.canSearch { sections.append(.subtitles) }
        if !model.audioOptions.isEmpty || model.engineCapabilities.contains(.dialogEnhance)
            || model.engineCapabilities.contains(.audioDelay) { sections.append(.audio) }
        if availability.maximumSpeed != nil, model.engineCapabilities.contains(.playbackSpeed) { sections.append(.speed) }
        if availability.quality || (availability.video && model.engineCapabilities.contains(.videoZoom)) {
            sections.append(.video)
        }
        if availability.versions { sections.append(.versions) }
        if availability.multiview { sections.append(.multiview) }
        if availability.timestamps { sections.append(.timestamps) }
        return sections
    }

    public static func make(
        model: PlayerControlsModel, availability: PlayerMoreMenuAvailability,
        locale: Locale = .current, section: PlayerMenuSection? = nil, actions: PlayerMoreMenuActions
    ) -> UIMenu {
        func localized(_ resource: LocalizedStringResource) -> String {
            var resource = resource
            resource.locale = locale
            return String(localized: resource) // l10n:content - native menu boundary.
        }
        func destination(_ title: LocalizedStringResource, _ value: PlayerMenuDestination) -> UIAction {
            UIAction(title: localized(title)) { _ in actions.request(value) }
        }
        var entries: [PlayerMenuSection: UIMenuElement] = [:]
        if !model.subtitleOptions.isEmpty || model.subtitleDownload.canSearch {
            let tracks = model.subtitleOptions.map { option in
                UIAction(title: option.nativeTitle, state: option.isSelected ? .on : .off) { _ in
                    actions.selectSubtitle(option.id)
                }
            }
            var subtitles: [UIMenuElement] = []
            if !tracks.isEmpty {
                subtitles.append(UIMenu(options: [.displayInline, .singleSelection], children: tracks))
            }
            var more: [UIMenuElement] = []
            if model.subtitleDownload.canSearch {
                more.append(destination("Search & Download…", .subtitleSearch))
            }
            if (model.subtitleStyleAdjustable && model.secondarySubtitleImagePrimaryFormat == nil)
                || model.subtitleDelayAdjustable || !model.secondarySubtitleOptions.isEmpty {
                more.append(destination("Advanced…", .subtitleAdvanced))
            }
            if !more.isEmpty { subtitles.append(UIMenu(options: .displayInline, children: more)) }
            entries[.subtitles] = UIMenu(title: localized(PlayerMenuSection.subtitles.title), children: subtitles)
        }
        if !model.audioOptions.isEmpty || model.engineCapabilities.contains(.dialogEnhance)
            || model.engineCapabilities.contains(.audioDelay) {
            let menu = PlayerAudioMenu.make(
                options: model.audioOptions,
                dialogueEnhancement: model.engineCapabilities.contains(.dialogEnhance) ? model.dialogEnhanceEnabled : nil,
                locale: locale, onSelect: actions.selectAudio, onSetDialogueEnhancement: actions.setDialogueEnhancement
            )
            var audio = menu.children
            if model.engineCapabilities.contains(.audioDelay) {
                audio.append(UIMenu(options: .displayInline, children: [
                    destination("Audio Sync…", .audioSync)
                ]))
            }
            entries[.audio] = UIMenu(title: menu.title, children: audio)
        }
        if let maximum = availability.maximumSpeed, model.engineCapabilities.contains(.playbackSpeed) {
            let speeds = speedPresets.filter { $0 <= maximum }.map { speed in
                let title = speed.formatted(.number.locale(locale).precision(.fractionLength(0...2))) + "×" // l10n:content - numeric rate.
                return UIAction(title: title, state: abs(model.playbackSpeed - speed) < 0.001 ? .on : .off) { _ in
                    actions.setSpeed(speed)
                }
            }
            entries[.speed] = UIMenu(title: localized(PlayerMenuSection.speed.title), children: [
                UIMenu(options: [.displayInline, .singleSelection], children: speeds),
                UIMenu(options: .displayInline, children: [destination("Custom…", .speed)])
            ])
        }
        var video: [UIMenuElement] = []
        if availability.video, model.engineCapabilities.contains(.videoZoom) {
            let zoom = PlayerZoomMenu.make(model: availability.videoModel ?? model.videoZoom, locale: locale, isCurrent: actions.isCurrent) {
                actions.request(.zoom)
            }
            video.append(UIMenu(title: zoom.title, options: [.displayInline, .singleSelection], children: zoom.children))
        }
        if availability.quality {
            video.append(UIMenu(options: .displayInline, children: [destination("Quality", .quality)]))
        }
        if !video.isEmpty {
            entries[.video] = UIMenu(title: section == .video ? "" : localized(PlayerMenuSection.video.title), children: video)
        }
        if availability.versions { entries[.versions] = destination(PlayerMenuSection.versions.title, .versions) }
        if availability.multiview { entries[.multiview] = destination(PlayerMenuSection.multiview.title, .multiview) }
        if availability.timestamps { entries[.timestamps] = destination(PlayerMenuSection.timestamps.title, .timestamps) }
        if let section {
            if let menu = entries[section] as? UIMenu { return menu }
            return UIMenu(children: entries[section].map { [$0] } ?? [])
        }
        var items = [PlayerMenuSection.subtitles, .audio, .speed].compactMap { entries[$0] }
        let secondary = [PlayerMenuSection.video, .versions, .multiview, .timestamps].compactMap { entries[$0] }
        if !secondary.isEmpty { items.append(UIMenu(options: .displayInline, children: secondary)) }
        return UIMenu(children: items)
    }
}

public struct PlayerMoreMenuButton: View {
    public let model: PlayerControlsModel
    public let availability: PlayerMoreMenuAvailability
    public let presentation: PlayerMenuPresentation
    public let layout: PlayerMenuLayout
    public var accessibilityIdentifier: String
    public let actions: PlayerMoreMenuActions

    public init(
        model: PlayerControlsModel, availability: PlayerMoreMenuAvailability,
        presentation: PlayerMenuPresentation, layout: PlayerMenuLayout = .consolidated,
        accessibilityIdentifier: String = "player-playback-options",
        actions: PlayerMoreMenuActions
    ) {
        self.model = model
        self.availability = availability
        self.presentation = presentation
        self.layout = layout
        self.accessibilityIdentifier = accessibilityIdentifier
        self.actions = actions
    }

    public var body: some View {
        let sections = PlayerMoreMenu.sections(model, availability: availability)
        HStack(spacing: 0) {
            if !sections.isEmpty {
                if layout == .consolidated {
                    PlayerNativeSectionMenu(
                        model: model, availability: availability, presentation: presentation, section: nil,
                        identifier: accessibilityIdentifier, actions: actions
                    )
                } else {
                    ForEach(sections) { section in
                        if let destination = section.destination {
                            Button {
                                guard actions.isCurrent() else { return }
                                presentation.request(destination, generation: presentation.generation)
                            } label: {
                                Image(systemName: section.symbol)
                                    .font(.title3)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PlayerGlassCircleButtonStyle(diameter: 44))
                            .accessibilityLabel(Text(section.title))
                            .accessibilityIdentifier(identifier(section))
                        } else {
                            PlayerNativeSectionMenu(
                                model: model, availability: availability, presentation: presentation, section: section,
                                identifier: identifier(section), actions: actions
                            )
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onChange(of: layout) { presentation.reset() }
        .onChange(of: sections) { presentation.reset() }
        .onChange(of: availability.quality) { presentation.reset() }
        .onChange(of: availability.video && model.engineCapabilities.contains(.videoZoom)) { presentation.reset() }
    }

    private func identifier(_ section: PlayerMenuSection) -> String {
        let suffix = "playback-options"
        if accessibilityIdentifier.hasSuffix(suffix) {
            return String(accessibilityIdentifier.dropLast(suffix.count)) + section.rawValue
        }
        return accessibilityIdentifier + "-" + section.rawValue
    }
}

private struct PlayerNativeSectionMenu: View {
    let model: PlayerControlsModel
    let availability: PlayerMoreMenuAvailability
    let presentation: PlayerMenuPresentation
    let section: PlayerMenuSection?
    let identifier: String
    let actions: PlayerMoreMenuActions
    @Environment(\.locale) private var locale

    var body: some View {
        PlayerOptionsMenuButton(
            kind: section?.kind ?? .playbackOptions,
            accessibilityIdentifier: identifier,
            makeMenu: {
                let generation = presentation.generation
                let isCurrent = { presentation.generation == generation && actions.isCurrent() }
                guard isCurrent() else { return nil }
                var guarded = PlayerMoreMenuActions()
                guarded.isCurrent = isCurrent
                guarded.selectAudio = { if isCurrent() { actions.selectAudio($0) } }
                guarded.selectSubtitle = { if isCurrent() { actions.selectSubtitle($0) } }
                guarded.setDialogueEnhancement = { if isCurrent() { actions.setDialogueEnhancement($0) } }
                guarded.setSpeed = { if isCurrent() { actions.setSpeed($0) } }
                guarded.request = { if isCurrent() { presentation.request($0, generation: generation) } }
                return PlayerMoreMenu.make(
                    model: model, availability: availability, locale: locale, section: section, actions: guarded
                )
            },
            onPresentationChange: { owner, presented in presentation.setPresented(presented, owner: owner) }
        )
        .frame(width: 44, height: 44)
        .id(presentation.generation)
    }
}
#endif
