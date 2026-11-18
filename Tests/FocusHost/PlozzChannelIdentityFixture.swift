import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI
@testable import FeatureLiveTV

struct PlozzChannelIdentityFixture: View {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let theme = ProcessInfo.processInfo.environment["PLOZZ_CHANNEL_IDENTITY_THEME"] ?? "dark"
    private var palette: ThemePalette {
        switch theme {
        case "light": .light
        case "black": .pureBlack
        default: .dark
        }
    }
    @State private var model = makeModel()
    @State private var imports = LiveTVPrototypeImportModel()
    @State private var selectedID: String? = "identity-0"
    @State private var selectedRow: LiveTVGuideRowID? = .init(channelID: "identity-0")
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var hasFocus = false
    @State private var railActive = false
    @State private var restoring = true
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor = Self.now
    @State private var timelineOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(
                size: geometry.size, safeAreaInsets: geometry.safeAreaInsets
            )
            ZStack(alignment: .topLeading) {
                AppBackground(palette: palette).ignoresSafeArea()
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: geometry.size.width) {
                    PrototypeBrowseLayout(layout: layout) {
                        PrototypePreviewHero(
                            channel: model.channel(id: selectedID ?? "identity-0"),
                            program: focusedProgram ?? model.currentProgram(for: "identity-0"),
                            layout: layout, watch: {}
                        )
                    } sidebar: {
                        PrototypeBrowseSidebar(
                            model: model, configuration: imports.configuration, active: $railActive,
                            lastFocusedControl: .constant(nil), focusRequest: 0,
                            search: {}, enterGuide: {}, selectSource: { _ in }, addSource: {},
                            multiviews: {}, manageChannels: {}
                        )
                        .disabled(true)
                    } guide: {
                        browser
                    }
                }
            }
        }
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .environment(\.locale, Locale(identifier: "en_US"))
    }

    private var browser: some View {
        PrototypeBrowser(
            model: model, imports: imports,
            selectedID: $selectedID, selectedRowID: $selectedRow,
            railActive: $railActive, focusedProgram: $focusedProgram, hasFocus: $hasFocus,
            topRequest: 0, nowRequest: 0,
            guideOffset: $guideOffset, timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
            restoreFocusRequest: 1, isPresented: true, isRestoringFocus: restoring,
            restoresPlaybackFocus: true, watchOrigin: .init(channelID: "identity-0"),
            focusRestored: { _ in restoring = false },
            tune: { _ in }, details: { _ in }, openControls: {}, openSources: {},
            openGuideTime: {}, openToolbar: nil, isLoading: false, loadFailed: false, reload: {}
        )
    }

    private static func makeModel() -> LiveTVPrototypeModel {
        let names = ["Movies", "TV Shows", "Animation", "Documentary & Nature", "Studio Ghibli", "North News"]
        let moods: [LibraryChannelArtworkMood?] = [.cinematic, .neutral, .playful, .calm, .cinematic, nil]
        let titles = [
            ["The Evening Feature", "Midnight Express"],
            ["A Place Called Home", "The Next Chapter"],
            ["The Lost Map", "A Small Adventure"],
            ["Wild Coast", "Life in the Forest"],
            ["After the Rain", "The Wind and the Sea"],
            ["The World Tonight", "Tomorrow's Headlines"]
        ]
        let channels = names.enumerated().map { index, name in
            LiveTVPrototypeChannel(
                id: "identity-\(index)", number: index + 1, name: name,
                category: index == 5 ? "News" : "Plozz channels",
                symbol: "tv", accent: index, source: index == 5 ? .iptv : .plozz,
                tagline: "A selection from your library.", plozzChannelMood: moods[index]
            )
        }
        let model = LiveTVPrototypeModel(now: now, channels: channels)
        let programs = channels.enumerated().flatMap { index, channel in
            [
                LiveTVPrototypeProgram(
                    id: "identity-current-\(index)", channelID: channel.id,
                    title: titles[index][0], subtitle: index == 1 ? "S1 E3" : "",
                    start: now.addingTimeInterval(-900), end: now.addingTimeInterval(4_500),
                    details: LiveTVProgramDetails(description:
                        "A journey of unexpected discoveries, familiar faces, and new beginnings."
                    )
                ),
                LiveTVPrototypeProgram(
                    id: "identity-next-\(index)", channelID: channel.id,
                    title: titles[index][1], subtitle: "",
                    start: now.addingTimeInterval(4_500), end: now.addingTimeInterval(10_800)
                )
            ]
        }
        do { try model.replacePrograms(programs) }
        catch { preconditionFailure("Invalid channel identity fixture: \(error)") }
        return model
    }
}
