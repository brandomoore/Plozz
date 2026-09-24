import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

/// The EPG grid inside the player's Guide card, under the pill row.
///
/// The same `PrototypeBrowser` grid the guide page uses, with state of its own
/// so opening it never disturbs the page's position or focus restoration.
/// Down from the Guide pill walks into it and Up from its top row walks back
/// out; opened by the remote's Guide button it takes focus on the playing
/// channel instead. Choosing a row tunes and closes the card; Menu returns to
/// the pills.
struct LiveTVPlayerGuideOverlay: View {
    let model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    let playingChannelID: String
    let libraryCatalog: PrototypeLibraryCatalogRevision?
    let loadLibraryGuide: ((Set<String>, DateInterval) -> Void)?
    let embedding: LiveChannelGuideEmbedding
    let tune: (String) -> Void

    @State private var selectedID: String?
    @State private var rowID: LiveTVGuideRowID?
    @State private var railActive = false
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var hasFocus = false
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1_800) * 1_800)
    @State private var timelineOffset: CGFloat = 0
    @State private var restoring: Bool

    init(
        model: LiveTVPrototypeModel, imports: LiveTVPrototypeImportModel, playingChannelID: String,
        libraryCatalog: PrototypeLibraryCatalogRevision?,
        loadLibraryGuide: ((Set<String>, DateInterval) -> Void)?,
        embedding: LiveChannelGuideEmbedding, tune: @escaping (String) -> Void
    ) {
        self.model = model
        self.imports = imports
        self.playingChannelID = playingChannelID
        self.libraryCatalog = libraryCatalog
        self.loadLibraryGuide = loadLibraryGuide
        self.embedding = embedding
        self.tune = tune
        _restoring = State(initialValue: embedding.focusesPlayingChannel)
    }

    var body: some View {
        PrototypeBrowser(
            model: model, imports: imports,
            selectedID: $selectedID, selectedRowID: $rowID,
            railActive: $railActive, focusedProgram: $focusedProgram, hasFocus: $hasFocus,
            topRequest: 0, nowRequest: 0, guideOffset: $guideOffset,
            timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
            restoreFocusRequest: 1, isPresented: true, isRestoringFocus: restoring,
            restoresPlaybackFocus: true, watchOrigin: model.guideRow(for: playingChannelID),
            focusRestored: { _ in restoring = false },
            tune: { choose($0.channelID) },
            details: { choose($0.channelID) },
            openControls: {}, openSources: {}, openGuideTime: {},
            openToolbar: { embedding.back() },
            isLoading: false, loadFailed: false, reload: {},
            libraryCatalog: libraryCatalog, loadLibraryGuide: loadLibraryGuide
        )
        .onAppear {
            rowID = model.guideRow(for: playingChannelID)
            selectedID = playingChannelID
        }
        .accessibilityIdentifier("live-channel-guide-overlay")
    }

    private func choose(_ channelID: String) {
        embedding.didTune()
        if channelID != playingChannelID { tune(channelID) }
    }
}
