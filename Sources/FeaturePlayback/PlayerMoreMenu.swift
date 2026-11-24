#if os(iOS)
import CoreModels
import CoreUI
import Observation
import SwiftUI
import UIKit

public enum PlayerMenuDestination: String, Identifiable {
    case subtitleSearch, subtitleAdvanced, audioSync, speed, zoom, quality, versions, multiview
    case discMenu, discVideos, playVideo, discRegion
    public var id: Self { self }
}

public enum PlayerMenuLayout: Equatable {
    case consolidated, separate

    public init(size: CGSize) {
        self = size.width > size.height ? .separate : .consolidated
    }
}

public enum PlayerMenuSection: String, CaseIterable, Identifiable {
    case subtitles, audio, speed = "playback-speed", quality, multiview, zoom, versions, upscaling, fel
    case discMenu, discVideos, playVideo, discRegion
    public var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .subtitles: "Subtitles"
        case .audio: "Audio"
        case .speed: "Playback Speed"
        case .quality: "Quality"
        case .zoom: "Zoom"
        case .upscaling: "Upscaling"
        case .fel: "P7 FEL → P8.1 conversion"
        case .versions: "Version"
        case .multiview: "Multiview"
        case .discMenu: "Disc menu"
        case .discVideos: "Disc videos"
        case .playVideo: "Play video"
        case .discRegion: "Try another region"
        }
    }

    var kind: PlayerOptionsMenuButton.Kind? {
        switch self {
        case .subtitles: .subtitles
        case .audio: .audio
        case .speed: .speed
        default: nil
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
    public struct Disc {
        var canNavigate: Bool
        var canPlayVideo: Bool

        @MainActor public init?(player: PlayerViewModel) {
            guard player.isDiscMenuPlayback || player.hasDiscVideos else { return nil }
            canNavigate = player.isDiscMenuPlayback && player.videoEngine.discMenu != nil
            canPlayVideo = player.isDiscMenuPlayback || player.isSelectedDiscVideo
        }
    }

    public var maximumSpeed: Double?
    public var video: Bool
    public var videoModel: PlayerVideoZoomModel?
    public var quality: StreamingQuality?
    public var qualitySupport: StreamingQualitySupport
    public var versions: Bool
    public var multiview: Bool
    public var disc: Disc?

    public init(
        maximumSpeed: Double? = nil, video: Bool = true, videoModel: PlayerVideoZoomModel? = nil, quality: StreamingQuality? = nil,
        qualitySupport: StreamingQualitySupport = .standard, versions: Bool = false, multiview: Bool = false, disc: Disc? = nil
    ) {
        self.maximumSpeed = maximumSpeed
        self.video = video
        self.videoModel = videoModel
        self.quality = quality
        self.qualitySupport = qualitySupport
        self.versions = versions
        self.multiview = multiview
        self.disc = disc
    }
}

@MainActor
public struct PlayerMoreMenuActions {
    public var isCurrent: () -> Bool = { true }
    public var selectAudio: (Int) -> Void = { _ in }
    public var selectSubtitle: (Int) -> Void = { _ in }
    public var setDialogueEnhancement: (Bool) -> Void = { _ in }
    public var setVolumeBoost: (PlayerVolumeBoost) -> Void = { _ in }
    public var setSpeed: (Double) -> Void = { _ in }
    public var setQuality: (StreamingQuality) -> Void = { _ in }
    public var setDolbyVisionFELConversion: (Bool) -> Void = { _ in }
    public var setVideoUpscaling: (VideoUpscaling) -> Void = { _ in }
    public var request: (PlayerMenuDestination) -> Void = { _ in }
    public init() {}
}

@MainActor
public enum PlayerMoreMenu {
    public static let speedPresets: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func rateTitle(_ speed: Double, locale: Locale) -> String {
        speed.formatted(.number.locale(locale).precision(.fractionLength(0...2))) + "×" // l10n:content - numeric rate.
    }

    public static func hasOptions(_ model: PlayerControlsModel, availability: PlayerMoreMenuAvailability) -> Bool {
        !sections(model, availability: availability).isEmpty
    }

    public static func sections(_ model: PlayerControlsModel, availability: PlayerMoreMenuAvailability) -> [PlayerMenuSection] {
        var sections: [PlayerMenuSection] = []
        if !model.subtitleOptions.isEmpty || model.subtitleDownload.canSearch { sections.append(.subtitles) }
        if !model.audioOptions.isEmpty || model.engineCapabilities.contains(.dialogEnhance)
            || !model.engineCapabilities.intersection([.audioDelay, .volumeBoost]).isEmpty { sections.append(.audio) }
        if availability.maximumSpeed != nil, model.engineCapabilities.contains(.playbackSpeed) { sections.append(.speed) }
        if availability.quality != nil { sections.append(.quality) }
        if availability.multiview { sections.append(.multiview) }
        if availability.video && model.engineCapabilities.contains(.videoZoom) { sections.append(.zoom) }
        if availability.versions { sections.append(.versions) }
        if model.upscaling.isAvailable { sections.append(.upscaling) }
        if model.felConversion.isAvailable { sections.append(.fel) }
        if let disc = availability.disc {
            if disc.canNavigate { sections.append(.discMenu) }
            sections.append(.discVideos)
            if disc.canPlayVideo { sections.append(.playVideo) }
            if disc.canNavigate { sections.append(.discRegion) }
        }
        return sections
    }

    public static func make(
        model: PlayerControlsModel, availability: PlayerMoreMenuAvailability,
        locale: Locale = .current, section: PlayerMenuSection? = nil, settingsOnly: Bool = false,
        actions: PlayerMoreMenuActions
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
            if model.subtitleStyleAdjustable
                || model.subtitleDelayAdjustable || !model.secondarySubtitleOptions.isEmpty {
                more.append(destination("Advanced…", .subtitleAdvanced))
            }
            if !more.isEmpty { subtitles.append(UIMenu(options: .displayInline, children: more)) }
            entries[.subtitles] = UIMenu(title: localized(PlayerMenuSection.subtitles.title), children: subtitles)
        }
        if !model.audioOptions.isEmpty || model.engineCapabilities.contains(.dialogEnhance)
            || !model.engineCapabilities.intersection([.audioDelay, .volumeBoost]).isEmpty {
            let menu = PlayerAudioMenu.make(
                options: model.audioOptions,
                dialogueEnhancement: model.engineCapabilities.contains(.dialogEnhance) ? model.dialogEnhanceEnabled : nil,
                locale: locale, onSelect: actions.selectAudio, onSetDialogueEnhancement: actions.setDialogueEnhancement
            )
            var audio = menu.children
            if model.engineCapabilities.contains(.volumeBoost) {
                let choices = PlayerVolumeBoost.allCases.map { boost in
                    let title = boost == .off ? localized("Off") : (Double(boost.rawValue) / 100).formatted(.percent.locale(locale))
                    return UIAction(title: title, state: model.volumeBoost == boost ? .on : .off) { _ in
                        actions.setVolumeBoost(boost)
                    }
                }
                audio.append(UIMenu(title: localized("Volume Boost"), options: .singleSelection, children: choices))
            }
            if model.engineCapabilities.contains(.audioDelay) {
                audio.append(UIMenu(options: .displayInline, children: [
                    destination("Audio Sync…", .audioSync)
                ]))
            }
            entries[.audio] = UIMenu(title: menu.title, children: audio)
        }
        if let maximum = availability.maximumSpeed, model.engineCapabilities.contains(.playbackSpeed) {
            let speeds = speedPresets.filter { $0 <= maximum }.map { speed in
                let title = rateTitle(speed, locale: locale)
                return UIAction(title: title, state: abs(model.playbackSpeed - speed) < 0.001 ? .on : .off) { _ in
                    actions.setSpeed(speed)
                }
            }
            entries[.speed] = UIMenu(title: localized(PlayerMenuSection.speed.title), children: [
                UIMenu(options: [.displayInline, .singleSelection], children: speeds),
                UIMenu(options: .displayInline, children: [destination("Custom…", .speed)])
            ])
        }
        if model.upscaling.isAvailable {
            entries[.upscaling] = UIMenu(
                title: localized(PlayerMenuSection.upscaling.title),
                children: VideoUpscaling.allCases.map { selection in
                    UIAction(
                        title: localized(selection.title),
                        attributes: model.upscaling.isChanging ? [.disabled] : [],
                        state: model.upscaling.selection == selection ? .on : .off
                    ) { _ in
                        guard actions.isCurrent() else { return }
                        actions.setVideoUpscaling(selection)
                    }
                }
            )
        }
        if model.felConversion.isAvailable {
            let enabled = model.felConversion.isEnabled
            entries[.fel] = UIAction(title: localized(PlayerMenuSection.fel.title), state: enabled ? .on : .off) { _ in
                guard actions.isCurrent() else { return }
                actions.setDolbyVisionFELConversion(!enabled)
            }
        }
        if availability.video, model.engineCapabilities.contains(.videoZoom) {
            let zoom = PlayerZoomMenu.make(model: availability.videoModel ?? model.videoZoom, locale: locale, isCurrent: actions.isCurrent) {
                actions.request(.zoom)
            }
            entries[.zoom] = UIMenu(title: localized(PlayerMenuSection.zoom.title), options: .singleSelection, children: zoom.children)
        }
        if let quality = availability.quality {
            let support = availability.qualitySupport
            var presets = StreamingQuality.allCases.filter { support.validationMessage(for: $0) == nil }
            if !presets.contains(quality) { presets.append(quality) }
            let choices = presets.map { preset in
                UIAction(title: localized(preset.title),
                         attributes: support.validationMessage(for: preset) == nil ? [] : .disabled,
                         state: preset == quality ? .on : .off) { _ in actions.setQuality(preset) }
            }
            // An inline section adds separator padding above and below the presets,
            // pushing Advanced out of the visible menu on compact landscape players.
            let menu = UIMenu(title: localized(PlayerMenuSection.quality.title),
                              children: choices + [destination("Advanced…", .quality)])
            menu.subtitle = localized(quality.title)
            entries[.quality] = menu
        }
        if availability.versions { entries[.versions] = destination(PlayerMenuSection.versions.title, .versions) }
        if availability.multiview { entries[.multiview] = destination(PlayerMenuSection.multiview.title, .multiview) }
        if let disc = availability.disc {
            if disc.canNavigate {
                entries[.discMenu] = destination(PlayerMenuSection.discMenu.title, .discMenu)
                entries[.discRegion] = destination(PlayerMenuSection.discRegion.title, .discRegion)
            }
            entries[.discVideos] = destination(PlayerMenuSection.discVideos.title, .discVideos)
            if disc.canPlayVideo { entries[.playVideo] = destination(PlayerMenuSection.playVideo.title, .playVideo) }
        }
        if let section {
            if let menu = entries[section] as? UIMenu { return menu }
            return UIMenu(children: entries[section].map { [$0] } ?? [])
        }
        let sections = sections(model, availability: availability)
        var items = settingsOnly ? [] : sections.filter { $0.kind != nil }.compactMap { entries[$0] }
        let secondary = sections.filter { $0.kind == nil }.compactMap { entries[$0] }
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
    @State private var overflowOrigin = PlayerOverflowOrigin()

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
        PlayerGlassControlGroup { controls(sections) }
            .background(alignment: .topTrailing) {
                if layout == .separate, sections.contains(where: { $0.kind == nil }) {
                    // Keep the native menu's origin outside the glass capsule so
                    // UIKit doesn't expand the menu over the whole control row.
                    PlayerOverflowSurface(origin: overflowOrigin)
                        .frame(width: 1, height: 1)
                        .offset(y: -9)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: layout) { presentation.reset() }
            .onChange(of: sections) { presentation.reset() }
            .onChange(of: availability.quality) { presentation.reset() }
            .onChange(of: availability.qualitySupport) { presentation.reset() }
    }

    private func controls(_ sections: [PlayerMenuSection]) -> some View {
        HStack(spacing: 0) {
            if !sections.isEmpty {
                if layout == .consolidated {
                    PlayerNativeSectionMenu(
                        model: model, availability: availability, presentation: presentation, section: nil,
                        identifier: accessibilityIdentifier, actions: actions
                    )
                } else {
                    ForEach([PlayerMenuSection.audio, .subtitles, .speed].filter(sections.contains)) { section in
                        PlayerNativeSectionMenu(
                            model: model, availability: availability, presentation: presentation, section: section,
                            identifier: identifier(section.rawValue), actions: actions
                        )
                    }
                    if sections.contains(where: { $0.kind == nil }) {
                        PlayerNativeSectionMenu(
                            model: model, availability: availability, presentation: presentation, section: nil,
                            settingsOnly: true, overflowOrigin: overflowOrigin,
                            identifier: identifier("settings"), actions: actions
                        )
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func identifier(_ action: String) -> String {
        let suffix = "playback-options"
        if accessibilityIdentifier.hasSuffix(suffix) {
            return String(accessibilityIdentifier.dropLast(suffix.count)) + action
        }
        return accessibilityIdentifier + "-" + action
    }
}

private struct PlayerNativeSectionMenu: View {
    let model: PlayerControlsModel
    let availability: PlayerMoreMenuAvailability
    let presentation: PlayerMenuPresentation
    let section: PlayerMenuSection?
    var settingsOnly = false
    var overflowOrigin: PlayerOverflowOrigin?
    let identifier: String
    let actions: PlayerMoreMenuActions
    @Environment(\.locale) private var locale

    var body: some View {
        PlayerOptionsMenuButton(
            kind: section?.kind ?? (settingsOnly ? .settings : .playbackOptions),
            valueTitle: section == .speed ? PlayerMoreMenu.rateTitle(model.playbackSpeed, locale: locale) : nil,
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
                guarded.setVolumeBoost = { if isCurrent() { actions.setVolumeBoost($0) } }
                guarded.setSpeed = { if isCurrent() { actions.setSpeed($0) } }
                guarded.setQuality = { if isCurrent() { actions.setQuality($0) } }
                guarded.setDolbyVisionFELConversion = { if isCurrent() { actions.setDolbyVisionFELConversion($0) } }
                guarded.setVideoUpscaling = { if isCurrent() { actions.setVideoUpscaling($0) } }
                guarded.request = { if isCurrent() { presentation.request($0, generation: generation) } }
                return PlayerMoreMenu.make(
                    model: model, availability: availability, locale: locale, section: section,
                    settingsOnly: settingsOnly, actions: guarded
                )
            },
            onPresentationChange: { owner, presented in presentation.setPresented(presented, owner: owner) }
        )
        .anchorOverflow(at: overflowOrigin)
        .fixedSize(horizontal: section == .speed, vertical: false)
        .frame(minWidth: 44, maxWidth: section == .speed ? nil : 44)
        .frame(height: 44)
        .id(presentation.generation)
    }
}
#endif
