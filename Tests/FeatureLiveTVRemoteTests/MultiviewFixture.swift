import CoreModels
import CoreUI
import CoreVideo
import FeaturePlayback
import SwiftUI
import UIKit
@testable import FeatureLiveTV
@testable import FeatureLiveTVCore
@testable import AppShell

private enum MultiviewFixtureCatalog {
    static let delaysPreparation = ProcessInfo.processInfo.arguments.contains("--pending-multiview-fixture")
    static let channels = (1...4).map {
        LiveTVPrototypeChannel(
            id: "sports-\($0)", number: $0, name: "Sports \($0)",
            category: ProcessInfo.processInfo.arguments.contains("--multiview-categories") && $0 > 2 ? "News" : "Sports",
            symbol: "tv", accent: $0, source: delaysPreparation && $0 == 2 ? .jellyfin : .iptv, tagline: "",
            streamURL: URL(string: "https://example.invalid/sports-\($0).m3u8")!,
            configuredSourceID: delaysPreparation && $0 == 2 ? "fixture" : nil
        )
    }
}

private actor MultiviewFixturePendingProvider: ServerLiveTVProviding {
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func liveTVAvailability() async throws -> ServerLiveTVAvailability {
        .init(status: .available, channelCount: 1)
    }

    func liveTVChannels() async throws -> [ServerLiveTVChannel] { [] }

    func liveTVGuide(channelIDs: [String], from: Date, to: Date) async throws -> [ServerLiveTVProgramme] { [] }

    func openLiveTVChannel(id: String) async throws -> any LiveTVStreamLease {
        let request = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if released {
                    continuation.resume()
                } else {
                    waiters[request] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(request) }
        }
        try Task.checkCancellation()
        return MultiviewFixtureLease(playbackSource: .publicURL(
            try SecretFreeURLSource(url: URL(string: "https://example.invalid/\(id).m3u8")!)
        ))
    }

    func release() {
        released = true
        let pending = Array(waiters.values)
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

private struct MultiviewFixtureLease: LiveTVStreamLease {
    let playbackSource: PlaybackSource
    func report(_ update: LiveTVPlaybackUpdate) async {}
    func close() async {}
}

@MainActor
private final class MultiviewFixtureState {
    let primary = LiveTVPlaybackPreparation()
    let output = LiveChannelOutputGroup()
    let pendingProvider = MultiviewFixturePendingProvider()
    lazy var coordinator = LiveTVMultiviewCoordinator(
        primary: primary,
        makePreparation: { [pendingProvider] in
            LiveTVPlaybackPreparation(serverProviderResolver: { _ in
                LiveTVAuthorizedServerProvider(
                    accountID: "fixture", authorizationID: "fixture", kind: .jellyfin,
                    provider: pendingProvider
                )
            })
        },
        reference: { id in
            guard MultiviewFixtureCatalog.delaysPreparation, id == "sports-2" else { return nil }
            return LiveTVServerChannelReference(
                sourceID: "fixture", accountID: "fixture", authorizationID: "fixture", channelID: id
            )
        },
        authorizes: { _, _ in true }, recordWatched: { _ in }
    )
    var engines: [MultiviewFixtureEngine] = []

    let channels = MultiviewFixtureCatalog.channels
    let guide = LiveTVPrototypeModel(now: Date(), channels: MultiviewFixtureCatalog.channels)
    let guideImports = LiveTVPrototypeImportModel(configuration: .init())

    func makeEngine() -> MultiviewFixtureEngine {
        let engine = MultiviewFixtureEngine(number: engines.count + 1)
        engines.append(engine)
        return engine
    }

    func playerItems(withPrograms: Bool) -> [LiveChannelOnNowItem] {
        channels.map {
            $0.playerItem(program: withPrograms ? guide.currentProgram(for: $0.id)?.playerInfo : nil)
        }
    }

    var metrics: String {
        "Engines \(engines.count) loads \(engines.reduce(0) { $0 + $1.loads }) " +
            "stops \(engines.reduce(0) { $0 + $1.stops }) " +
            "audible \(engines.filter { $0.audible && $0.status != .idle }.count)"
    }
}

struct MultiviewFixture: View {
    @State private var state = MultiviewFixtureState()
    @State private var isFavorite = false
    @State private var channelSelection: LiveTVMultiviewSelection?
    @State private var focusPresented = false
    @State private var nativeFocusedPaneID: UUID?
    @State private var focusRequest = 0
    @State private var backRequest = 0
    @State private var requestedFocusID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func videoCardFocus(for pane: LiveTVMultiviewPane, frame: CGRect) -> VideoCardFocus? {
        let coordinator = state.coordinator
        guard coordinator.isEnabled, channelSelection == nil,
              coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id else { return nil }
        let effect = focusPresented && coordinator.expandedPaneID == nil
        return VideoCardFocus(
            identifier: "live-multiview-pane-\(pane.id.uuidString)",
            title: pane.channel?.name ?? "", audible: pane.id == coordinator.audiblePaneID,
            presentsEffect: effect,
            cornerRadius: coordinator.expandedPaneID == nil ? LiveTVMultiviewGeometry.videoCornerRadius : 0,
            horizontalInset: effect ? LiveTVMultiviewGeometry.focusInset(for: frame.width) : 0,
            request: focusRequest, prefersFocus: pane.id == (requestedFocusID ?? coordinator.audiblePaneID),
            focused: { value in
                if value { nativeFocusedPaneID = pane.id }
                else if nativeFocusedPaneID == pane.id { nativeFocusedPaneID = nil }
            },
            activate: {
                coordinator.selectAudio(pane.id)
                coordinator.promote(pane.id)
            },
            promote: { coordinator.promote(pane.id) },
            replace: { channelSelection = .replace(pane.id) },
            remove: coordinator.panes.count > 1 ? { coordinator.remove(pane.id) } : nil,
            back: { backRequest &+= 1 },
            caption: AnyView(LiveTVMultiviewFocusCaption(
                channel: pane.channel, isFocused: focusPresented && nativeFocusedPaneID == pane.id)))
    }

    var body: some View {
        GeometryReader { geometry in
            let coordinator = state.coordinator
            let bounds = PrototypePreviewLayout(size: geometry.size, safeAreaInsets: geometry.safeAreaInsets).bounds
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                ForEach(coordinator.panes) { pane in
                    if let prepared = pane.preparation.current {
                        let slot = coordinator.isEnabled ? LiveTVMultiviewGeometry.frame(
                            for: pane.id, panes: coordinator.panes.map(\.id),
                            primary: coordinator.primaryPaneID, layout: coordinator.layout,
                            corner: coordinator.corner, insetSize: coordinator.insetSize,
                            expanded: coordinator.expandedPaneID, size: bounds.size,
                            isEditing: coordinator.isEditingLayout,
                            aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                            aspectRatios: LiveTVMultiviewGeometry.aspectRatios(in: coordinator.panes)
                        ).offsetBy(dx: bounds.minX, dy: bounds.minY) : CGRect(origin: .zero, size: geometry.size)
                        let roundsPicture = coordinator.isEnabled && coordinator.expandedPaneID == nil
                        let frame = roundsPicture ? LiveTVMultiviewGeometry.contentFrame(
                            in: slot, aspectRatio: pane.videoAspectRatio.map { CGFloat($0) }) : slot
                        let focus = videoCardFocus(for: pane, frame: frame)
                        let containerFrame = LiveTVMultiviewGeometry.focusContainerFrame(
                            for: frame, horizontalInset: focus?.horizontalInset ?? 0, layout: coordinator.layout)
                        LiveChannelPlayerView(
                            channelID: prepared.channel.id, title: prepared.channel.name,
                            input: prepared.input, logoURL: nil,
                            makeEngine: { state.makeEngine() },
                            onPreviousChannel: {}, onNextChannel: {},
                            isFavorite: isFavorite,
                            canToggleFavorite: ProcessInfo.processInfo.arguments.contains("--visual-focus-fixture"),
                            onToggleFavorite: { isFavorite.toggle() },
                            isExpanded: !coordinator.isEnabled,
                            usesNativeFullscreen: !coordinator.isEnabled,
                            onReturnToGuide: {},
                            reportingID: prepared.id,
                            onVideoAspectRatioChange: {
                                coordinator.updateVideoAspectRatio($0, paneID: pane.id, preparedID: prepared.id)
                            },
                            onMultiview: {
                                guard coordinator.begin() else { return false }
                                channelSelection = .add
                                return true
                            },
                            outputGroup: state.output, outputID: pane.id,
                            isAudible: pane.id == coordinator.audiblePaneID,
                            countsAsWatching: coordinator.isEnabled,
                            isMultiview: coordinator.isEnabled,
                            displayTransitionSettings: {
                                PlaybackSettings(fadeOnDynamicRangeChange: false, fadeOnFrameRateChange: false)
                            },
                            program: state.guide.currentProgram(for: prepared.channel.id)?.playerInfo,
                            loadOnNow: { state.playerItems(withPrograms: true) },
                            onTuneChannel: { _ in },
                            guideOverlay: { embedding in
                                AnyView(LiveTVPlayerGuideOverlay(
                                    model: state.guide, imports: state.guideImports,
                                    playingChannelID: prepared.channel.id,
                                    libraryCatalog: nil, loadLibraryGuide: nil,
                                    embedding: embedding, tune: { _ in }
                                ))
                            }
                        )
                        .modifier(PrototypeVideoPlacement(frame: containerFrame, focus: focus))
                        .animation(nil, value: focusPresented)
                        .animation(coordinator.isEditingLayout ? nil : (reduceMotion ? nil : MultiviewMotion.animation),
                                   value: coordinator.isEditingLayout)
                        .animation(reduceMotion ? nil : MultiviewMotion.animation, value: frame)
                        .zIndex(coordinator.isEnabled && coordinator.expandedPaneID == nil && pane.preparation.failure == nil
                            ? (pane.id != coordinator.primaryPaneID ? 4 : 3) : 0)
                        .allowsHitTesting(channelSelection == nil
                            && (coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id))
                        .accessibilityHidden(channelSelection != nil
                            || (coordinator.expandedPaneID != nil && coordinator.expandedPaneID != pane.id))
                        .opacity(coordinator.expandedPaneID == nil || coordinator.expandedPaneID == pane.id ? 1 : 0)
                    }
                }
                if coordinator.isEnabled && channelSelection == nil {
                    LiveTVMultiviewOverlay(
                        coordinator: coordinator,
                        onFocusPresentationChange: { focusPresented = $0 },
                        nativeFocusedPaneID: nativeFocusedPaneID,
                        onRestoreVideoFocus: {
                            requestedFocusID = coordinator.audiblePaneID
                            focusRequest &+= 1
                        },
                        onRequestVideoFocus: {
                            requestedFocusID = $0
                            focusRequest &+= 1
                        },
                        backRequest: backRequest,
                        exit: { _ = coordinator.exit() },
                        returnToGuide: { _ = coordinator.exit() },
                        addChannel: { channelSelection = .add },
                        replaceChannel: { channelSelection = .replace($0) },
                        isFavorite: isFavorite, toggleFavorite: { isFavorite.toggle() }
                    )
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    .zIndex(2)
                }
                if let channelSelection {
                    MultiviewGuideFixture(
                        model: state.guide, imports: state.guideImports, selection: channelSelection,
                        selectedIDs: Set(coordinator.panes.compactMap { $0.channel?.id }),
                        cancel: { self.channelSelection = nil }
                    ) { channel in
                        channelSelection.apply(channel, to: coordinator)
                        self.channelSelection = nil
                    }
                    .frame(width: bounds.width, height: bounds.height)
                    .position(x: bounds.midX, y: bounds.midY)
                    .zIndex(2)
                }
                TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                    VStack {
                        Text(verbatim: state.metrics)
                            .font(.caption2)
                            .accessibilityIdentifier("multiview-fixture-metrics")
                            .accessibilityValue(state.engines.first?.motionWidths ?? "")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 16)
                }
                .allowsHitTesting(false)
                .zIndex(3)
            }
        }
        .environment(\.colorScheme, .dark)
        .tint(.white)
        .environment(\.plozzReducePanelGlass,
                     ProcessInfo.processInfo.arguments.contains("--reduce-panel-glass"))
        .task {
            _ = await state.primary.prepare(
                state.channels[0], isAuthorized: { true }, accept: { true }
            )
        }
        .onPlayPauseCommand {
            // Release only the fake provider's network gate; native pane focus remains untouched.
            if MultiviewFixtureCatalog.delaysPreparation {
                Task { await state.pendingProvider.release() }
            }
        }
        .background { MultiviewFocusDiagnostics() }
    }
}

private struct MultiviewGuideFixture: View {
    let model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    let selection: LiveTVMultiviewSelection
    let selectedIDs: Set<String>
    let cancel: () -> Void
    let select: (LiveTVPrototypeChannel) -> Void
    @State private var selectedID: String?
    @State private var rowID: LiveTVGuideRowID?
    @State private var controlsActive = false
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var guideHasFocus = false
    @State private var guideOffset: TimeInterval = 0
    @State private var timeAnchor = Date()
    @State private var timelineOffset: CGFloat = 0
    @State private var restoresFocus = true

    var body: some View {
        VStack(spacing: 24) {
            LiveTVMultiviewGuideSelectionHeader(selection: selection, cancel: cancel)
            PrototypeBrowser(
                model: model, imports: imports, selectedID: $selectedID, selectedRowID: $rowID,
                railActive: $controlsActive, focusedProgram: $focusedProgram, hasFocus: $guideHasFocus,
                topRequest: 0, nowRequest: 0, guideOffset: $guideOffset,
                timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
                restoreFocusRequest: 1, isPresented: true, isRestoringFocus: restoresFocus,
                restoresPlaybackFocus: false, watchOrigin: nil,
                focusRestored: { _ in restoresFocus = false },
                tune: { row in if let channel = model.channel(id: row.channelID) { select(channel) } },
                details: { _ in }, openControls: {}, openSources: {}, openGuideTime: {},
                openToolbar: cancel, isLoading: false, loadFailed: false, reload: {},
                selectionAction: selection.title, selectedChannelIDs: selectedIDs
            )
        }
        .padding(60)
        .background(.black)
    }
}

private enum LiveTVRootFixtureStorage {
    static let preferences: LiveTVPreferencesStore = {
        let suite = "com.thatcube.Plozz.MultiviewGuideFixture"
        let defaults = UserDefaults(suiteName: suite)!
        if !ProcessInfo.processInfo.arguments.contains("--preserve-multiview-favorites") {
            defaults.removePersistentDomain(forName: suite)
        }
        return LiveTVPreferencesStore(defaults: defaults)
    }()
}

struct LiveTVRootFixture: View {
    @State private var isActive = true
    @State private var hostRevision = 0
    @State private var state = MultiviewFixtureState()
    @State private var profiles = ProfilesModel(store: SourceSmokeProfiles())
    @State private var sources: SourceSmokeStore
    @State private var imports: LiveTVPrototypeImportModel
    @State private var hidesNavigation = false
    @State private var nativeSelection = NavigationRailDestination.liveTV
    @State private var nativeHandoff = NavigationDestinationFocusHandoff()
    private var usesNativeFullscreen: Bool {
        !ProcessInfo.processInfo.arguments.contains("--inline-live-tv")
    }

    init() {
        let configuration = LiveTVSourcesConfiguration(playlists: [
            LiveTVPlaylistSource(
                id: "fixture", name: "Fixture sports",
                playlistURL: URL(string: "https://example.invalid/channels.m3u")!,
                guideURLs: [URL(string: "https://example.invalid/guide.xml")!]
            )
        ])
        _sources = State(initialValue: SourceSmokeStore(configuration: configuration))
        _imports = State(initialValue: LiveTVPrototypeImportModel(
            configuration: configuration, loader: LiveTVRootFixtureLoader()
        ))
    }

    @ViewBuilder
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--multiview-native-sidebar") {
            NativeSidebarNavigation(
                selection: nativeSelection, handoff: nativeHandoff,
                content: TabView(selection: $nativeSelection) {
                    Tab("Home", systemImage: "house", value: NavigationRailDestination.home) {
                        Button("Fixture home") {}
                    }
                    Tab("Live TV", systemImage: "tv", value: NavigationRailDestination.liveTV) {
                        NativeSidebarFocusDestination(
                            destination: .liveTV, selection: nativeSelection,
                            handoff: nativeHandoff, content: guide)
                    }
                }.tabViewStyle(.sidebarAdaptable))
                .environment(\.layoutDirection, ProcessInfo.processInfo.arguments.contains("--multiview-rtl")
                    ? .rightToLeft : .leftToRight)
        } else {
            guide
        }
    }

    private var guide: some View {
        RetainedFullscreenWorkspace { guideContent }
            .ignoresSafeArea()
    }

    private var liveTVContent: some View {
        LiveTVPrototypeView(
            isActive: isActive,
            usesNativeFullscreen: usesNativeFullscreen,
            preferencesStore: LiveTVRootFixtureStorage.preferences,
            viewSettingsStore: LiveTVRootFixtureSettings(),
            sourceStore: sources,
            serverAuthorizationID: "fixture-\(hostRevision)",
            onExpandedChange: { hidesNavigation = $0 },
            importModel: imports,
            profileID: profiles.activeProfileID,
            preferencesNamespace: profiles.activeNamespace,
            sourceApprovalContext: { [profiles] in LiveTVSourceApprovalContext(profiles: profiles) }
        ) { playback in
            LiveChannelPlayerView(
                channelID: playback.channel.id, title: playback.channel.name,
                input: playback.input, logoURL: nil,
                makeEngine: { state.makeEngine() },
                onPreviousChannel: playback.previousChannel, onNextChannel: playback.nextChannel,
                isFavorite: playback.isFavorite, canToggleFavorite: playback.canToggleFavorite,
                onToggleFavorite: playback.onToggleFavorite,
                isExpanded: playback.isExpanded,
                usesNativeFullscreen: usesNativeFullscreen && !playback.isMultiview,
                isActive: playback.isPlaybackActive, onReturnToGuide: playback.returnToGuide,
                playPauseRequest: playback.playPauseRequest, onPlaybackStarted: playback.playbackStarted,
                reportingID: playback.reportingID, onPlaybackUpdate: playback.playbackUpdate,
                onPlaybackFailed: playback.playbackFailed,
                onVideoAspectRatioChange: playback.videoAspectRatioChanged,
                onMultiview: playback.canOpenMultiview ? playback.openMultiview : nil,
                outputGroup: state.output, outputID: playback.paneID, isAudible: playback.isAudible,
                countsAsWatching: playback.countsAsWatching, isMultiview: playback.isMultiview,
                displayTransitionSettings: {
                    PlaybackSettings(fadeOnDynamicRangeChange: false, fadeOnFrameRateChange: false)
                },
                isAuthorized: playback.isAuthorized
            )
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        if usesNativeFullscreen {
            NavigationStack { liveTVContent }
        } else {
            liveTVContent
        }
    }

    private var guideContent: some View {
        navigationContent
        .environment(profiles)
        .transformEnvironment(\.plozzNavigationContentInset) {
            if ProcessInfo.processInfo.arguments.contains("--multiview-navigation-insets") { $0 = 100 }
        }
        .transformEnvironment(\.plozzTopNavigationContentInsets) {
            if ProcessInfo.processInfo.arguments.contains("--multiview-navigation-insets") {
                $0 = EdgeInsets(top: 160, leading: 100, bottom: 0, trailing: 100)
            }
        }
        .overlay(alignment: .topTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--loading-multiview-fixture") {
                Button("Release pictures") { state.engines.forEach { $0.presentFirstFrame() } }
                    .accessibilityIdentifier("multiview-fixture-release-pictures")
                    .padding(24)
            }
            if isActive && !ProcessInfo.processInfo.arguments.contains("--visual-focus-fixture") {
                HStack {
                    Button("Refresh host") { hostRevision += 1 }
                        .accessibilityIdentifier("live-root-fixture-refresh")
                        .accessibilityValue(String(hostRevision))
                    Button("Leave Live TV") { isActive = false }
                        .accessibilityIdentifier("live-root-fixture-leave")
                }
                .padding()
            }
        }
        .overlay(alignment: .top) {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(verbatim: state.metrics)
                    .font(.caption2)
                    .accessibilityIdentifier("multiview-fixture-metrics")
                    .accessibilityValue(state.engines.first?.motionWidths ?? "")
                Text(hidesNavigation ? "Navigation hidden" : "Navigation visible")
                    .accessibilityIdentifier("multiview-fixture-navigation")
                if ProcessInfo.processInfo.arguments.contains("--motion-fixture") {
                    Text(verbatim: "Picture motion")
                        .accessibilityIdentifier("multiview-fixture-picture-motion")
                        .accessibilityValue(state.engines.map(\.motionFrames).joined(separator: "|"))
                }
            }
            .padding(.top, 16)
            .allowsHitTesting(false)
        }
        .background { MultiviewFocusDiagnostics() }
    }
}

private struct MultiviewFocusDiagnostics: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) {}

    static func dismantleUIView(_ view: Probe, coordinator: ()) {
        view.stop()
    }

    final class Probe: UIView {
        private var timer: Timer?
        private let report = UILabel()
        private let focusHistory = UILabel()
        private var focusEvents: [String] = []

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            report.accessibilityIdentifier = "multiview-fixture-focus-diagnostics"
            report.font = .systemFont(ofSize: 10)
            report.textColor = .white
            report.isUserInteractionEnabled = false
            focusHistory.accessibilityIdentifier = "multiview-fixture-focus-history"
            focusHistory.text = "Focus history"
            focusHistory.font = .systemFont(ofSize: 10)
            focusHistory.textColor = .white
            focusHistory.isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stop()
            guard let window else { return }
            report.frame = CGRect(x: 80, y: window.bounds.height - 32, width: window.bounds.width - 160, height: 20)
            window.addSubview(report)
            if ProcessInfo.processInfo.arguments.contains("--focus-history-fixture") {
                focusHistory.frame = report.frame.offsetBy(dx: 0, dy: -22)
                window.addSubview(focusHistory)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(recordFocus(_:)),
                    name: UIFocusSystem.didUpdateNotification, object: nil)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            sample()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
            report.removeFromSuperview()
            focusHistory.removeFromSuperview()
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func recordFocus(_ notification: Notification) {
            guard let window,
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
                  let next = context.nextFocusedItem,
                  let localFrame = NativeFocusRegion.frame(of: next, in: self) else { return }
            let frame = convert(localFrame, to: window)
            focusEvents.append("\(frame.midX),\(frame.midY),\(frame.width),\(frame.height),\(context.focusHeading.rawValue)")
            if focusEvents.count > 128 { focusEvents.removeFirst() }
            focusHistory.accessibilityValue = focusEvents.joined(separator: ";")
        }

        private func sample() {
            guard let window else { return }
            let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem
            var pieces = [
                "keyWindow=\(window.isKeyWindow)",
                "focused=\(focused.map { String(describing: type(of: $0)) } ?? "nil")"
            ]
            func visitGuides(_ view: UIView) {
                for guide in view.layoutGuides.compactMap({ $0 as? UIFocusGuide }) {
                    pieces.append("returnGuide=\(guide.isEnabled):\(view.convert(guide.layoutFrame, to: window)):targets=\(guide.preferredFocusEnvironments.count)")
                    for target in guide.preferredFocusEnvironments {
                        if let frame = NativeFocusRegion.frame(of: target as? any UIFocusItem, in: self) {
                            pieces.append("returnTarget=\(convert(frame, to: window))")
                        }
                    }
                }
                for child in view.subviews { visitGuides(child) }
            }
            if ProcessInfo.processInfo.arguments.contains("--focus-history-fixture") { visitGuides(window) }
            if let focused {
                pieces.append("itemFrame=\(focused.frame)")
                var windowFrame = (focused as? UIView).map { $0.convert($0.bounds, to: window) }
                var environment = focused.parentFocusEnvironment
                for _ in 0..<20 {
                    guard let current = environment else { break }
                    pieces.append("focusParent=\(type(of: current))")
                    if let view = current as? UIView {
                        pieces.append("parentFrame=\(view.convert(view.bounds, to: window))")
                        if windowFrame == nil {
                            windowFrame = view.convert(focused.frame, to: window)
                        }
                    }
                    environment = current.parentFocusEnvironment
                }
                if let windowFrame {
                    pieces.append("focusWindowFrame=\(NSCoder.string(for: windowFrame))")
                }
            }
            if let view = focused as? UIView {
                pieces.append("focusID=\(view.accessibilityIdentifier ?? "-")")
                pieces.append("focusFrame=\(view.convert(view.bounds, to: window))")
            }
            func visit(_ controller: UIViewController) {
                pieces.append(
                    "controller=\(type(of: controller)):alpha=\(controller.viewIfLoaded?.alpha ?? -1)" +
                    ":interaction=\(controller.viewIfLoaded?.isUserInteractionEnabled ?? false)"
                )
                if let search = controller as? UISearchController {
                    pieces.append("searchActive=\(search.isActive)")
                    var view: UIView? = search.view
                    while let current = view {
                        pieces.append(
                            "ancestor=\(type(of: current)):hidden=\(current.isHidden)" +
                            ":alpha=\(current.alpha):interaction=\(current.isUserInteractionEnabled)" +
                            ":frame=\(current.convert(current.bounds, to: window))"
                        )
                        view = current.superview
                    }
                }
                for child in controller.children { visit(child) }
                if let presented = controller.presentedViewController { visit(presented) }
            }
            if let root = window.rootViewController { visit(root) }
            let description = pieces.joined(separator: " | ")
            if report.accessibilityValue != description {
                report.text = "Native focus diagnostics"
                report.accessibilityValue = description
                NSLog("MultiviewFocusDiagnostics %@", description)
            }
        }
    }
}

private struct LiveTVRootFixtureSettings: LiveTVViewSettingsStoring {
    func load() -> LiveTVViewSettings { .init(autoPreview: false, hasChosenAutoPreview: true) }
    func save(_ settings: LiveTVViewSettings) {}
}

private struct LiveTVRootFixtureLoader: LiveTVSourceLoading {
    func loadPlaylist(from url: URL) async throws -> LiveTVPlaylistImport {
        let channels = MultiviewFixtureCatalog.channels
        return LiveTVPlaylistImport(channels: channels, entryCount: channels.count, skippedEntryCount: 0)
    }

    func loadGuide(
        from url: URL, channels: [LiveTVPrototypeChannel], now: Date
    ) async throws -> LiveTVGuideImport {
        let start = now.addingTimeInterval(-300)
        let end = now.addingTimeInterval(3_600)
        return LiveTVGuideImport(
            programs: channels.map {
                LiveTVPrototypeProgram(
                    id: "final-\($0.id)", channelID: $0.id, title: "Championship final",
                    subtitle: "Live coverage", start: start, end: end
                )
            },
            matchedChannelCount: channels.count, guideChannelCount: channels.count,
            programCount: channels.count, coverageStart: start, coverageEnd: end
        )
    }
}

@MainActor
private final class MultiviewMotionOutput: UIView {
    private var widths: [CGFloat] = []
    private var frames: [[CGFloat]] = []
    private var displayLink: CADisplayLink?
    var motionFrames: String {
        frames.map { $0.map { String(format: "%.3f", Double($0)) }.joined(separator: ",") }
            .joined(separator: ";")
    }

    @MainActor private final class Clock: NSObject {
        weak var output: MultiviewMotionOutput?
        init(_ output: MultiviewMotionOutput) { self.output = output }
        @objc func sample(_ link: CADisplayLink) {
            guard let output else { link.invalidate(); return }
            output.sample()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil, ProcessInfo.processInfo.arguments.contains("--motion-fixture") else { return }
        let link = CADisplayLink(target: Clock(self), selector: #selector(Clock.sample(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    private func sample() {
        guard let window, let presented = layer.presentation() else { return }
        var ancestorLayer: CALayer? = presented
        while let current = ancestorLayer, current.model() !== window.layer {
            ancestorLayer = current.superlayer
        }
        // A detached presentation tree has no window coordinates during native reparenting.
        guard ancestorLayer != nil else { return }
        let frame = presented.convert(presented.bounds, to: window.layer.presentation() ?? window.layer)
        var opacity: CGFloat = 1
        var ancestor: UIView? = self
        while let current = ancestor {
            opacity *= current.isHidden ? 0 : CGFloat(current.layer.presentation()?.opacity ?? Float(current.alpha))
            ancestor = current.superview
        }
        let value = [frame.minX, frame.minY, frame.width, frame.height, opacity]
        guard frames.last != value else { return }
        frames.append(value)
        if frames.count > 1_024 { frames.removeFirst() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard ProcessInfo.processInfo.arguments.contains("--motion-fixture"),
              widths.last != bounds.width else { return }
        widths.append(bounds.width)
        accessibilityValue = widths.map { String(format: "%.2f", Double($0)) }.joined(separator: ",")
    }
}

@MainActor
private final class MultiviewFixtureEngine: LiveChannelEngine {
    let number: Int
    private let output = MultiviewMotionOutput()
    var motionWidths: String { output.accessibilityValue ?? "" }
    var motionFrames: String { output.motionFrames }
    private let label = UILabel()
    var status: VideoEngineStatus = .ready
    var hasPresentedVideoFrame: Bool { liveSnapshot.firstFrameReady }
    private lazy var previewFrame: CVPixelBuffer = {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 24, 14, kCVPixelFormatType_32BGRA, nil, &buffer)
        precondition(result == kCVReturnSuccess && buffer != nil)
        let frame = buffer!
        CVPixelBufferLockBaseAddress(frame, [])
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        for y in 0..<14 {
            for x in 0..<24 {
                let offset = y * stride + x * 4
                bytes[offset] = 220
                bytes[offset + 1] = number == 1 ? 40 : 200
                bytes[offset + 2] = 10
                bytes[offset + 3] = 255
            }
        }
        return frame
    }()
    func previewVideoFrame() -> CVPixelBuffer? {
        ProcessInfo.processInfo.arguments.contains("--audio-glow-fixture") ? previewFrame : nil
    }
    var isPaused = false
    var currentTime: TimeInterval { 0 }
    var duration: TimeInterval { 0 }
    var furthestObservedPosition: TimeInterval { 0 }
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onLiveSourceReset: (@MainActor () -> Void)?
    var supportsConcurrentPlayback: Bool { true }
    var capabilities: PlayerEngineCapabilities { [.videoZoom] }
    var probedSourceFacts: EngineProbedSourceFacts? {
        .init(range: .sdr, videoWidth: 1920, videoHeight: 1080)
    }
    var loads = 0
    var stops = 0
    var audible = false
    var audioActivations = 0
    var liveSnapshot = LiveChannelEngineSnapshot(
        phase: .playing, firstFrameReady: true, position: 100,
        bufferedPosition: 110, seekableRange: 90...110,
        behindLiveSeconds: 0, route: .nativeHLS
    )

    init(number: Int) {
        self.number = number
        if number > 1, ProcessInfo.processInfo.arguments.contains("--loading-multiview-fixture") {
            liveSnapshot.firstFrameReady = false
            liveSnapshot.phase = .loading
        }
        if ProcessInfo.processInfo.arguments.contains("--visual-focus-fixture") {
            audioTracks = [
                MediaTrack(id: 1, kind: .audio, displayTitle: "English", language: "eng"),
                MediaTrack(id: 2, kind: .audio, displayTitle: "French", language: "fra")
            ]
            subtitleTracks = [MediaTrack(id: 3, kind: .subtitle, displayTitle: "English", language: "eng")]
        }
        output.backgroundColor = number == 1 ? .systemBlue : .systemTeal
        output.accessibilityIdentifier = "multiview-fixture-video-\(number)"
        label.textColor = .white
        label.font = .preferredFont(forTextStyle: .headline)
        label.accessibilityIdentifier = "multiview-fixture-player-\(number)"
        label.translatesAutoresizingMaskIntoConstraints = false
        output.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: output.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: output.centerYAnchor)
        ])
    }

    func configureLiveOutput(_ policy: LiveChannelOutputPolicy) {
        if policy.isAudible, !audible { audioActivations += 1 }
        audible = policy.isAudible
        label.accessibilityValue = String(audioActivations)
    }
    func presentFirstFrame() {
        liveSnapshot.firstFrameReady = true
        liveSnapshot.phase = .playing
        onProgress?()
    }
    func loadLive(url: URL, httpHeaders: [String: String]) async {
        loads += 1
        status = .ready
        label.text = "Engine \(number) loads \(loads)"
        onProgress?()
    }
    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        preconditionFailure("The live fixture must not load VOD")
    }
    func play() { isPaused = false; liveSnapshot.phase = .playing }
    func pause() { isPaused = true; liveSnapshot.phase = .paused }
    func stop() { stops += 1; status = .idle }
    func seek(to seconds: TimeInterval) async {}
    func seekToLiveEdge() async {}
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}
    func makeVideoOutputView() -> UIView { output }
}
