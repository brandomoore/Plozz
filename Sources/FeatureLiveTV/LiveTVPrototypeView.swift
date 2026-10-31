import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

#if DEBUG
public enum LiveTVPrototypeEntry {
    public static var isEnabled: Bool { LiveTVPrototypeLaunch.isEnabled() }
}
#endif

public struct LiveTVPrototypePlayback {
    public let paneID: UUID
    public let channel: LiveTVPrototypeChannel
    public let input: LiveChannelInput
    public let authenticatedHTTPResolver: any AuthenticatedHTTPResourceResolving
    public let previousChannel: () -> Void
    public let nextChannel: () -> Void
    public let isFavorite: Bool
    public let canToggleFavorite: Bool
    public let onToggleFavorite: () -> Void
    public let isExpanded: Bool
    public let isPreviewVisible: Bool
    public let expandPreview: () -> Void
    public let previewReflectionHeight: CGFloat
    public let previewTopReflectionHeight: CGFloat
    public let previewLeadingReflectionWidth: CGFloat
    public let previewTrailingReflectionWidth: CGFloat
    public let returnToGuide: () -> Void
    public let playPauseRequest: Int
    public let playbackStarted: () -> Void
    public let reportingID: UUID
    public let playbackUpdate: @MainActor (LiveTVPlaybackUpdate) -> Void
    public let playbackFailed: @MainActor (LiveChannelFailureReport) -> Void
    public let videoAspectRatioChanged: @MainActor (Double?) -> Void
    public let preparingChannelName: String?
    public let isMultiview: Bool
    public let isAudible: Bool
    public let openMultiview: () -> Void
    public let canOpenMultiview: Bool
    public let isPlaybackActive: Bool
    public let isAuthorized: Bool
    public let countsAsWatching: Bool
    public let externalContinuationChanged: @MainActor (Bool) -> Void
    public let restorePlayer: @MainActor () async -> Bool
    public let stopPlayback: @MainActor () -> Void
    public let openLibraryItem: ((LibraryChannelItem) -> Void)?
    /// What the guide says is airing on this channel now.
    public let program: LiveChannelProgramInfo?
    /// What aired before it, for a stream whose rewind window reaches back past its start.
    public let earlierPrograms: [LiveChannelProgramInfo]
    /// What is airing across the lineup, for the player's On Now tab. A closure
    /// so the lineup is only walked when the tab is opened.
    public let onNow: @MainActor () -> [LiveChannelOnNowItem]
    public let tuneChannel: (String) -> Void
    /// The EPG grid for the player's Guide card. Built here because the grid
    /// belongs to the guide; the player only hosts it.
    public let guideOverlay: (LiveChannelGuideEmbedding) -> AnyView
}

private struct PrototypeExternalPlayback: Equatable {
    let paneID: UUID
    let preparedID: UUID
}

private struct PrototypeSearchBookmark {
    let row: LiveTVGuideRowID?
    let guideOffset: TimeInterval
    let timeAnchor: Date
    let timelineOffset: CGFloat
}

private enum PrototypeSearchScope: Hashable {
    case channels, programs
}

public struct LiveTVPrototypeView<PlayerContent: View>: View {
    @State private var model: LiveTVPrototypeModel
    @State private var preview: LiveTVPreviewController
    @State private var imports: LiveTVPrototypeImportModel
    @State private var playback: LiveTVPlaybackCoordinator
    @State private var playbackResolvers: LiveTVPlaybackResolverContext
    @State private var sourceAuthority: LiveTVPlaybackSourceAuthority
    @State private var appliedSourceAuthorizationID: String?
    @State private var multiview: LiveTVMultiviewCoordinator
    @State private var enrollment = LiveTVServerEnrollmentCoordinator()
    @State private var sources: LiveTVSourceManagementModel?
    @State private var sourceApplicationFailed = false
    @State private var reloadRequest = 0
    @State private var pendingServerRefresh = false
    @State private var sheet: PrototypeSheet?
    @State private var needsPreviewChoice = false
    @State private var selectedChannelID: String?
    @State private var selectedRowID: LiveTVGuideRowID?
    @State private var isSearching = false
    @State private var searchScope: PrototypeSearchScope = .channels
    @State private var searchFocusRequest = 0
    @State private var searchOrigin: PrototypeSearchBookmark?
    @State private var pendingSearchCategory: String?
    @State private var showsCategoryDirectory: Bool
    @State private var startsWithCategories: Bool
    @State private var categoryDirectoryReturnID: String?
    @State private var topRequest = 0
    @State private var nowRequest = 0
    @State private var channelSequence = LiveTVChannelSequence(channels: [])
    @State private var controlsActive = false
    @State private var toolbarControlsBottom: CGFloat?
    @State private var categoryFocusRequest = 0
    @State private var sidebarRestoresCategoryFocus = false
    @State private var guideHasFocus = false
    @State private var toolbarFocusRequest = 0
    @State private var focusedProgram: LiveTVPrototypeProgram?
    @State private var loadedRequest: Int?
    @State private var guideOffset: TimeInterval = 0
    @State private var timelineOffset: CGFloat = 0
    @State private var timeAnchor = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1_800) * 1_800)
    @State private var pendingTuneID: String?
    @State private var pendingServerConnection = false
    @State private var pendingIPTVConnection = false
    @State private var pendingIPTVPlaylist: LiveTVPlaylistSource?
    @State private var pendingIPTVMode: IPTVCredential.Mode = .playlist
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter
    @State private var externalPlayback: PrototypeExternalPlayback?
    @State private var multiviewSelection: LiveTVMultiviewSelection?
    @State private var multiviewEditingInsets: EdgeInsets?
    @State private var pendingMultiviewFavorite: LiveTVMultiviewFavorite?
    @State private var multiviewFavoriteIssue: LocalizedStringResource?
    @State private var managesLibraryChannels = false
    @State private var libraryGuideIssue: LibraryChannelError?
    @State private var libraryNavigationIssue: LibraryChannelError?
    @State private var pendingLibraryNavigation: LibraryChannelItem?
    @State private var portableIdentityHold: LiveTVPlaybackIdentityHold
    @State private var pendingPortableReload = false
    @State private var scanBinding: LiveTVScanCatalogBinding
    @State private var showsScanSources = false
    @State private var pendingScanOfferSourceID: String?
    /// Settings › Live TV › Preview after watching.
    @State private var previewAfterWatching = true
    @Environment(\.themePalette) private var palette
    @Environment(\.plozzNavigationContentInset) private var navigationInset
    @Environment(\.plozzTopNavigationContentInsets) private var topNavigationInsets
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    private let isActive: Bool
    private let profileID: String
    private let allowsPlayback: Bool
    private let playbackUnavailableReason: LocalizedStringResource?
    private let restoreDestination: @MainActor () async -> Bool
    private let usesNativeFullscreen: Bool
    private let viewSettingsStore: (any LiveTVViewSettingsStoring)?
    private let sourceStore: (any LiveTVSourcesStoring)?
    private let enrollmentSuppression: LiveTVServerEnrollmentSuppressionStore
    private let libraryService: LibraryChannelService?
    private let libraryHistory: LibraryChannelHistorySettings?
    private let libraryIssue: LibraryChannelError?
    private let automaticChannels: LiveTVAutomaticChannelsState?
    private let reloadLibrary: (() -> Void)?
    private let prepareLibraryChannels: (@MainActor () async throws -> Void)?
    private let libraryIsAuthorized: @MainActor @Sendable () -> Bool
    private let didConfigurePlaylist: () -> Void
    private let serverProviderResolver: LiveTVServerProviderResolver
    private let authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
    private let serverChoices: [LiveTVServerChoice]
    private let serverAuthorizationID: String
    private let isProfileAuthorized: @MainActor @Sendable () -> Bool
    private let homeModel: HomeLiveTVModel?
    private let homeAuthorizationID: String?
    private let connectServer: (() -> Void)?
    private let onExpandedChange: (Bool) -> Void
    private let onOpenTitle: ((MediaItem) -> Void)?
    /// The host's profile action shares the native mobile browse toolbar.
    private let topBarAccessory: AnyView?
    private let player: (LiveTVPrototypePlayback) -> PlayerContent

    public init(
        isActive: Bool = true,
        usesNativeFullscreen: Bool = false,
        preferencesStore: (any LiveTVPreferencesStoring)? = nil,
        viewSettingsStore: (any LiveTVViewSettingsStoring)? = nil,
        sourceStore: (any LiveTVSourcesStoring)? = nil,
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? = nil,
        isProfileAuthorized: @escaping @MainActor @Sendable () -> Bool = { true },
        serverChoices: [LiveTVServerChoice] = [],
        serverAuthorizationID: String = "",
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        onExpandedChange: @escaping (Bool) -> Void = { _ in },
        allowsPlayback: Bool = true,
        playbackUnavailableReason: LocalizedStringResource? = nil,
        restoreDestination: @escaping @MainActor () async -> Bool = { false },
        catalogCache: LiveTVIndexedCache? = nil,
        sourceLoader: (any LiveTVSourceLoading)? = nil,
        importModel: LiveTVPrototypeImportModel? = nil,
        profileID: String = ProfileStore.defaultProfileID,
        preferencesNamespace: String?,
        libraryService: LibraryChannelService? = nil,
        libraryHistory: LibraryChannelHistorySettings? = nil,
        libraryIssue: LibraryChannelError? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil,
        reloadLibrary: (() -> Void)? = nil,
        prepareLibraryChannels: (@MainActor () async throws -> Void)? = nil,
        libraryIsAuthorized: @escaping @MainActor @Sendable () -> Bool = { true },
        sourceApprovalContext: @escaping @MainActor @Sendable () -> LiveTVSourceApprovalContext? = { nil },
        homeModel: HomeLiveTVModel? = nil,
        homeAuthorizationID: String? = nil,
        onOpenTitle: ((MediaItem) -> Void)? = nil,
        topBarAccessory: AnyView? = nil,
        @ViewBuilder player: @escaping (LiveTVPrototypePlayback) -> PlayerContent
    ) {
        self.isActive = isActive
        self.profileID = profileID
        _portableIdentityHold = State(initialValue: LiveTVPlaybackIdentityHold(profileID: profileID))
        self.allowsPlayback = allowsPlayback
        self.playbackUnavailableReason = playbackUnavailableReason
        self.restoreDestination = restoreDestination
        self.usesNativeFullscreen = usesNativeFullscreen
        self.viewSettingsStore = viewSettingsStore
        let initialViewSettings = viewSettingsStore?.load()
        let startsWithCategories = initialViewSettings?.startsWithCategories ?? LiveTVViewSettings().startsWithCategories
        _startsWithCategories = State(initialValue: startsWithCategories)
        _showsCategoryDirectory = State(initialValue: startsWithCategories)
        self.sourceStore = sourceStore
        self.enrollmentSuppression = LiveTVServerEnrollmentSuppressionStore(
            profileID: profileID, namespace: preferencesNamespace
        )
        self.libraryService = libraryService
        self.libraryHistory = libraryHistory
        self.libraryIssue = libraryIssue
        self.automaticChannels = automaticChannels
        self.reloadLibrary = reloadLibrary
        self.prepareLibraryChannels = prepareLibraryChannels
        self.libraryIsAuthorized = libraryIsAuthorized
        let sourceAuthority = LiveTVPlaybackSourceAuthority(
            profileID: profileID,
            approvals: LiveTVSourceApprovalStore(profileID: profileID, namespace: preferencesNamespace),
            sourceStore: sourceStore, context: sourceApprovalContext
        )
        _sourceAuthority = State(initialValue: sourceAuthority)
        let resolver: LiveTVServerProviderResolver = serverProviderResolver ?? { _ in nil }
        self.serverProviderResolver = resolver
        self.authenticatedHTTPResolver = authenticatedHTTPResolver
        let resolverContext = LiveTVPlaybackResolverContext(
            serverProviderResolver: resolver, authenticatedHTTPResolver: authenticatedHTTPResolver
        )
        _playbackResolvers = State(initialValue: resolverContext)
        let currentResolver: LiveTVServerProviderResolver = { resolverContext.provider(for: $0) }
        self.isProfileAuthorized = isProfileAuthorized
        self.homeModel = homeModel
        self.homeAuthorizationID = homeAuthorizationID
        self.serverChoices = serverChoices
        self.serverAuthorizationID = serverAuthorizationID
        self.connectServer = connectServer
        self.didConfigurePlaylist = didConfigurePlaylist
        let sources = sourceStore.map {
            LiveTVSourceManagementModel(store: $0, canMutate: { false })
        }
        _sources = State(initialValue: sources)
        let imports = importModel ?? LiveTVPrototypeImportModel(
            configuration: .empty, loader: sourceLoader ?? LiveTVSourceLoader(),
            serverProviderResolver: currentResolver, cache: catalogCache
        )
        _imports = State(initialValue: imports)
        self.onExpandedChange = onExpandedChange
        self.onOpenTitle = onOpenTitle
        self.topBarAccessory = topBarAccessory
        self.player = player
        #if DEBUG
        let isLargeCatalog = ProcessInfo.processInfo.arguments.contains("--live-tv-5000")
        #else
        let isLargeCatalog = false
        #endif
        let model = LiveTVPrototypeModel(
            now: Date(), scenario: .noGuide,
            isLargeCatalog: isLargeCatalog,
            channels: [], preferencesStore: preferencesStore
        )
        _model = State(initialValue: model)
        if startsWithCategories { model.category = nil }
        let scanBinding = LiveTVScanCatalogBinding(
            profileID: profileID, model: model,
            coordinator: LiveTVChannelScanCoordinator(store: LiveTVChannelHealthStore(
                namespace: profileID
            )),
            authorization: sourceAuthority.authorization
        )
        _scanBinding = State(initialValue: scanBinding)
        #if os(tvOS)
        _needsPreviewChoice = State(initialValue: initialViewSettings?.hasChosenAutoPreview == false)
        let preview = LiveTVPreviewController(
            model: model, followsFocus: initialViewSettings?.allowsAutomaticPreview ?? true
        )
        #else
        let preview = LiveTVPreviewController(model: model, followsFocus: false)
        #endif
        _preview = State(initialValue: preview)
        let libraryResolver: @MainActor @Sendable (
            LiveTVPrototypeChannel
        ) throws -> LiveTVLibraryChannelReference? = { [weak libraryService] channel in
            guard let libraryService, channel.source == .plozz, libraryIsAuthorized(),
                  let definition = libraryService.definitions.first(where: {
                      $0.catalogID == channel.id && $0.isEnabled
                  }) else { return nil }
            let context = try libraryService.playbackCandidate(catalogID: channel.id)
            guard let schedule = context.eligibleSchedule() else {
                throw LibraryChannelError.snapshotUnavailable
            }
            let slot = try schedule.slot(at: Date())
            guard libraryService.isAuthorized(slot.item), context.channelID == definition.id,
                  let authorizationID = context.eligibilityID else {
                throw LiveTVPlaybackPreparationError.authorizationChanged
            }
            return LiveTVLibraryChannelReference(channelID: context.channelID, authorizationID: authorizationID)
        }
        let preparation = LiveTVPlaybackPreparation(
            serverProviderResolver: currentResolver, authenticatedHTTPResolver: resolverContext,
            libraryChannelResolver: libraryResolver
        )
        let authorizes: @MainActor @Sendable (
            LiveTVPrototypeChannel, LiveTVServerChannelReference?
        ) -> Bool = { channel, reference in
            isProfileAuthorized() && (sources?.hasLoaded ?? true)
                && (channel.source != .plozz || libraryIsAuthorized())
                && sourceAuthority.allows(channel, configuration: sources?.configuration ?? imports.configuration)
                && LiveTVPlaybackCatalogAuthorization.allows(
                    channel, reference: reference, model: model, imports: imports,
                    configuration: sources?.configuration ?? imports.configuration,
                    libraryService: libraryService
                )
        }
        _playback = State(initialValue: LiveTVPlaybackCoordinator(
            model: model, preview: preview,
            preparation: preparation,
            reference: { imports.serverChannelReferences[$0] },
            isAuthorized: authorizes,
            isGuideOnly: { channelID in
                guard let reference = imports.serverChannelReferences[channelID] else { return false }
                return imports.serverSources.first(where: { $0.id == reference.sourceID })?
                    .availability?.status == .unsupportedPlaybackMode
            }
        ))
        _multiview = State(initialValue: LiveTVMultiviewCoordinator(
            primary: preparation,
            makePreparation: {
                LiveTVPlaybackPreparation(
                    serverProviderResolver: currentResolver,
                    authenticatedHTTPResolver: resolverContext,
                    libraryChannelResolver: libraryResolver
                )
            },
            reference: { imports.serverChannelReferences[$0] },
            authorizes: authorizes,
            recordWatched: { _ = model.recordWatched($0) }
        ))
    }

    public var body: some View {
        lifecycleContent
    }

    private var playerAndGuideSurface: some View {
        GeometryReader { geometry in
            let layout = PrototypePreviewLayout(
                size: geometry.size, safeAreaInsets: geometry.safeAreaInsets,
                navigationInset: navigationInset, nativeNavigation: usesNativeFullscreen,
                topNavigationInsets: topNavigationInsets,
                largeText: typeSize.isAccessibilitySize,
                isSearching: isSearching, showsCategories: showsCategoryDirectory,
                showsVideoPreview: playback.preparation.current != nil || playback.pendingWatchChannelID != nil,
                toolbarControlsBottom: toolbarControlsBottom.map { $0 - geometry.frame(in: .global).minY }
            )
            let expanded = multiviewSelection == nil && (preview.isExpanded || multiview.isEnabled)
            #if os(iOS)
            let playerTransition: Animation? = reduceMotion ? nil : .smooth(duration: 0.35)
            #else
            let playerTransition: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.32)
            #endif
            ZStack(alignment: .topLeading) {
                #if !os(tvOS)
                AppBackground(palette: palette)
                #endif

                // Stable pane IDs retain renderers through single/multiple layouts and promotion.
                ForEach(multiview.panes) { pane in
                    if let prepared = pane.preparation.current {
                        let videoFrame = showingMultiview
                            ? LiveTVMultiviewGeometry.frame(
                                for: pane.id, panes: multiview.panes.map(\.id),
                                primary: multiview.primaryPaneID, layout: multiview.layout,
                                corner: multiview.corner, insetSize: multiview.insetSize,
                                expanded: multiview.expandedPaneID, size: layout.bounds.size,
                                isEditing: multiview.isEditingLayout,
                                aspectRatio: pane.videoAspectRatio.map { CGFloat($0) },
                                editingInsets: multiviewEditingInsets
                            )
                            .offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY)
                            : (expanded ? layout.bounds : layout.videoFrame)
                        let reflectionHeight = !expanded && !showingMultiview && !reduceTransparency
                            ? layout.videoReflectionHeight : 0
                        let topReflectionHeight = reflectionHeight > 0 ? layout.videoTopReflectionHeight : 0
                        let leadingReflectionWidth = reflectionHeight > 0 ? layout.videoLeadingReflectionWidth : 0
                        let trailingReflectionWidth = reflectionHeight > 0 ? layout.videoTrailingReflectionWidth : 0
                        player(playbackInput(for: pane, prepared: prepared, reflectionHeight: reflectionHeight,
                                             topReflectionHeight: topReflectionHeight,
                                             leadingReflectionWidth: leadingReflectionWidth,
                                             trailingReflectionWidth: trailingReflectionWidth,
                                             isPreviewVisible: !expanded && layout.heroHeight > 0))
                    .environment(\.playbackReflectionColorScheme, palette.isLight ? .light : .dark)
                    .environment(\.themePalette, ThemePalette.dark)
                    .environment(\.colorScheme, .dark)
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .clipShape(PrototypeVideoClip(
                        reflectionHeight: reflectionHeight,
                        topReflectionHeight: topReflectionHeight,
                        leftReflectionWidth: layoutDirection == .rightToLeft ? trailingReflectionWidth : leadingReflectionWidth,
                        rightReflectionWidth: layoutDirection == .rightToLeft ? leadingReflectionWidth : trailingReflectionWidth,
                        cornerRadius: showingMultiview && multiview.isEditingLayout ? 10 : 0))
                    .overlay {
                        #if os(tvOS)
                        LinearGradient(
                            stops: [
                                .init(color: palette.backgroundBase, location: 0),
                                .init(color: .clear, location: 0.28),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .opacity(expanded || layout.compact ? 0 : 1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        #endif
                    }
                    .position(
                        x: !showingMultiview && layoutDirection == .rightToLeft
                            ? geometry.size.width - videoFrame.midX : videoFrame.midX,
                        y: videoFrame.midY
                    )
                    #if os(iOS)
                    .animation(playerTransition, value: videoFrame)
                    #else
                    .animation(playerTransition, value: preview.isExpanded)
                    #endif
                    #if os(iOS)
                    .zIndex(showingMultiview
                        ? (pane.id != multiview.primaryPaneID ? 1 : 0) : (expanded ? 1 : 0))
                    #else
                    .zIndex(showingMultiview && pane.id != multiview.primaryPaneID ? 1 : 0)
                    #endif
                    .opacity(multiviewSelection != nil
                        ? (pane.id == multiview.audiblePaneID ? 1 : 0)
                        : (multiview.expandedPaneID == nil || multiview.expandedPaneID == pane.id ? 1 : 0))
                    .allowsHitTesting(!multiview.isEnabled)
                    .accessibilityHidden(multiview.isEnabled)
                    #if os(iOS)
                    .opacity(expanded || layout.heroHeight > 0 ? 1 : 0)
                    .allowsHitTesting(expanded || layout.heroHeight > 0)
                    .accessibilityHidden(!expanded && layout.heroHeight == 0)
                    #endif
                    }
                }

                #if os(tvOS)
                PrototypePreviewScrim(layout: layout, reduceTransparency: reduceTransparency)
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(
                        x: layoutDirection == .rightToLeft
                            ? geometry.size.width - layout.bounds.midX : layout.bounds.midX,
                        y: layout.bounds.midY
                    )
                    .opacity(expanded || model.channels.isEmpty ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: preview.isExpanded)
                #endif

                guideContent(layout, canvasWidth: geometry.size.width)
                #if os(tvOS)
                .focusSection()
                #endif
                .frame(width: geometry.size.width, height: geometry.size.height)
                #if os(iOS)
                .contentShape(PrototypeGuideHitRegion(
                    top: layout.heroHeight > 0 ? max(0, layout.videoFrame.maxY) : 0,
                    sidebarWidth: layout.sidebarWidth > 0 ? max(0, layout.videoFrame.minX) : 0,
                    sidebarOnTrailing: layoutDirection == .rightToLeft))
                #endif
                .opacity(expanded ? 0 : 1)
                #if os(iOS)
                .offset(y: expanded && !reduceMotion ? 24 : 0)
                #else
                .offset(y: expanded && !reduceMotion ? geometry.size.height * 0.55 : 0)
                #endif
                .disabled(expanded || !isActive || showsPreviewIntroduction)
                .allowsHitTesting(!expanded && isActive && !showsPreviewIntroduction)
                .accessibilityHidden(expanded || !isActive || showsPreviewIntroduction)
                .animation(playerTransition, value: preview.isExpanded)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSearching)
                if showingMultiview {
                    LiveTVMultiviewOverlay(
                        coordinator: multiview,
                        safeAreaInsets: geometry.safeAreaInsets,
                        editingInsets: multiviewEditingInsets,
                        onEditingInsetsChange: { multiviewEditingInsets = $0 },
                        exit: { leaveMultiview() },
                        returnToGuide: { leaveMultiview(); leavePlaybackForGuide() },
                        addChannel: { beginMultiviewSelection(.add) },
                        replaceChannel: { beginMultiviewSelection(.replace($0)) },
                        isFavorite: model.favoriteMultiviews.contains(where: multiview.matches),
                        toggleFavorite: toggleMultiviewFavorite
                    )
                    .frame(width: layout.bounds.width, height: layout.bounds.height)
                    .position(x: layout.bounds.midX, y: layout.bounds.midY)
                    .zIndex(2)
                }
            }
            #if os(tvOS)
            .settingsPageBackground()
            #elseif os(iOS)
            .background(PrototypeToolbarBottomReader {
                if !expanded, $0 > 0 { toolbarControlsBottom = $0 }
            })
            .toolbar {
                PrototypeTouchBrowseToolbar(
                    model: model, isSearching: isSearching,
                    showsDirectory: usesCategoryDirectory(layout),
                    hasSidebar: layout.sidebarWidth > 0,
                    isDisabled: blocksBrowseControls || !isActive || expanded,
                    showGuide: { showCategory(nil) }, showCategories: showCategories,
                    search: { if isSearching { closeSearch() } else { openSearch() } },
                    filters: { sheet = .filters },
                    multiviews: multiviewSelection == nil ? { sheet = .multiviewFavorites } : nil,
                    cancelSelection: multiviewSelection == nil ? nil : finishMultiviewSelection,
                    accessory: topBarAccessory
                )
            }
            .navigationTitle(
                usesCategoryDirectory(layout) || layout.sidebarWidth > 0 ? Text("Live TV") : Text(verbatim: "")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(expanded ? .hidden : .visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
        }
        .environment(\.themePalette, palette)
        .tint(palette.accent)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .overlay(alignment: .topTrailing) {
            if let id = playback.pendingWatchChannelID, !preview.isExpanded || playback.preparation.current == nil {
                PrototypeWatchPreparationStatus(
                    channelName: model.channel(id: id)?.name ?? "",
                    cancel: playback.cancelWatch
                )
            }
        }
        .overlay(alignment: .bottomLeading) {
            if isActive, !allowsPlayback, !model.channels.isEmpty, let playbackUnavailableReason {
                Label {
                    Text(playbackUnavailableReason)
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .font(.callout)
                .padding()
                .background(palette.backgroundBase, in: RoundedRectangle(cornerRadius: 12))
                .padding()
                .allowsHitTesting(false)
            }
        }
        #if os(tvOS)
        .onPlayPauseCommand {
            if isActive && !showsPreviewIntroduction && (!preview.isExpanded || multiview.isEnabled) {
                multiview.requestPlayPause()
            }
        }
        #endif
    }

    private func playbackInput(
        for pane: LiveTVMultiviewPane, prepared: LiveTVPreparedStream, reflectionHeight: CGFloat = 0,
        topReflectionHeight: CGFloat = 0, leadingReflectionWidth: CGFloat = 0,
        trailingReflectionWidth: CGFloat = 0, isPreviewVisible: Bool = false
    ) -> LiveTVPrototypePlayback {
        let presentationID = playback.presentationID
        return LiveTVPrototypePlayback(
            paneID: pane.id,
            channel: prepared.channel, input: prepared.input,
            authenticatedHTTPResolver: playbackResolvers,
            previousChannel: { changeChannel(by: -1) },
            nextChannel: { changeChannel(by: 1) },
            isFavorite: model.favoriteIDs.contains(prepared.channel.id),
            canToggleFavorite: model.preferencesIssue != .loadFailed,
            onToggleFavorite: { model.toggleFavoriteWithFeedback(prepared.channel.id) },
            isExpanded: preview.isExpanded && !multiview.isEnabled,
            isPreviewVisible: isPreviewVisible && !multiview.isEnabled,
            expandPreview: {
                guard activity.acceptsInteraction, !multiview.isEnabled else { return }
                playback.expandPreview(presentationID: presentationID, preparedID: prepared.id)
            },
            previewReflectionHeight: reflectionHeight,
            previewTopReflectionHeight: topReflectionHeight,
            previewLeadingReflectionWidth: leadingReflectionWidth,
            previewTrailingReflectionWidth: trailingReflectionWidth,
            returnToGuide: {
                guard playback.ownsPlayerPresentation(presentationID) else { return }
                leavePlaybackForGuide()
            },
            playPauseRequest: pane.playPauseRequest,
            playbackStarted: {
                if multiview.isEnabled {
                    multiview.confirmWatching(pane.id, preparedID: prepared.id)
                } else {
                    playback.confirmWatching(prepared.id)
                }
            },
            reportingID: prepared.id,
            playbackUpdate: { multiview.report($0, paneID: pane.id, preparedID: prepared.id) },
            playbackFailed: { report in
                if multiview.isEnabled {
                    multiview.playbackFailed(pane.id, preparedID: prepared.id, report: report)
                } else {
                    playback.playbackFailed(prepared.id, report: report)
                }
            },
            videoAspectRatioChanged: {
                multiview.updateVideoAspectRatio($0, paneID: pane.id, preparedID: prepared.id)
            },
            preparingChannelName: pane.preparation.preparingChannelID.flatMap {
                model.channel(id: $0)?.name
            },
            isMultiview: multiview.isEnabled,
            isAudible: pane.id == multiview.audiblePaneID,
            openMultiview: {
                guard !hasAuthorizedExternalPlayback, activity.acceptsInteraction,
                      multiview.begin() else { return }
                updatePlaybackAvailability()
            },
            canOpenMultiview: !multiview.isEnabled && !hasAuthorizedExternalPlayback,
            isPlaybackActive: activity.isPlaybackActive,
            isAuthorized: !sourceApplicationFailed
                && authorizesPlayback(prepared),
            countsAsWatching: countsAsWatching(paneID: pane.id),
            externalContinuationChanged: {
                updateExternalPlayback($0, paneID: pane.id, preparedID: prepared.id)
            },
            restorePlayer: { await restorePlayer(paneID: pane.id, preparedID: prepared.id) },
            stopPlayback: { stopPlayer(paneID: pane.id, preparedID: prepared.id) },
            openLibraryItem: onOpenTitle == nil ? nil : openLibraryItem,
            program: model.currentProgram(for: prepared.channel.id)?.playerInfo,
            earlierPrograms: model.earlierPrograms(for: prepared.channel.id).map(\.playerInfo),
            onNow: { onNowItems(around: prepared.channel.id) },
            tuneChannel: { tune($0) },
            guideOverlay: { embedding in
                AnyView(LiveTVPlayerGuideOverlay(
                    model: model, imports: imports, playingChannelID: prepared.channel.id,
                    libraryCatalog: libraryCatalogRevision, loadLibraryGuide: publishLibraryGuide,
                    embedding: embedding, tune: { tune($0) }
                ))
            }
        )
    }

    /// The order the viewer tuned from, falling back to the guide's own.
    private var tuningLineup: [LiveTVPrototypeChannel] {
        let visible = model.visibleChannels
        let visibleIDs = Set(visible.map(\.id))
        let sequenced = channelSequence.channelIDs.filter(visibleIDs.contains).compactMap { model.channel(id: $0) }
        return sequenced.isEmpty ? visible : sequenced
    }

    /// The channels after `channelID` in the order the viewer tuned from, with
    /// what each is airing. The playing channel leads the row.
    private func onNowItems(around channelID: String) -> [LiveChannelOnNowItem] {
        let lineup = tuningLineup
        let ordered: [LiveTVPrototypeChannel]
        if let index = lineup.firstIndex(where: { $0.id == channelID }) {
            ordered = Array(lineup[index...] + lineup[..<index])
        } else {
            ordered = (model.channel(id: channelID).map { [$0] } ?? []) + lineup
        }
        return ordered.prefix(Self.onNowLimit).map { channel in
            channel.playerItem(program: model.currentProgram(for: channel.id)?.playerInfo)
        }
    }

    private static var onNowLimit: Int { 20 }

    private func stopPlayer(paneID: UUID, preparedID: UUID) {
        guard let pane = multiview.panes.first(where: { $0.id == paneID }),
              pane.preparation.current?.id == preparedID else { return }
        if externalPlayback == PrototypeExternalPlayback(paneID: paneID, preparedID: preparedID) {
            externalPlayback = nil
        }
        if multiview.isEnabled, multiview.panes.count > 1 {
            multiview.remove(paneID)
            if multiview.panes.count == 1 { leaveMultiview() }
        } else {
            playback.stop()
            multiview.stop()
        }
        updatePlaybackAvailability()
    }

    private func openLibraryItem(_ item: LibraryChannelItem) {
        guard let onOpenTitle else { return }
        guard isActive, isProfileAuthorized(), libraryIsAuthorized(),
              libraryService?.isAuthorized(item) == true else {
            libraryNavigationIssue = .authorizationChanged
            return
        }
        pendingTuneID = nil
        externalPlayback = nil
        multiviewSelection = nil
        preview.stop()
        multiview.stop()
        playback.stop()
        onExpandedChange(false)
        onOpenTitle(item.navigationSubject)
    }

    private func countsAsWatching(paneID: UUID) -> Bool {
        let isExternal = hasAuthorizedExternalPlayback && externalPlayback?.paneID == paneID
        let visible = sheet == nil && multiviewSelection == nil && (multiview.isEnabled
            ? multiview.expandedPaneID == nil || multiview.expandedPaneID == paneID
            : preview.isExpanded || !isSearching)
        return activity.countsAsWatching(
            isUserRequested: isExternal || multiview.isEnabled || preview.isExpanded || preview.isHoldingWatchedChannel,
            isPictureVisible: visible, isExternallyPresented: isExternal
        )
    }

    private func leaveMultiview() {
        multiviewSelection = nil
        if let retained = multiview.exit() { playback.adoptPreparation(retained) }
        playback.setInteractionActive(activity.acceptsInteraction)
        updatePreviewAvailability()
    }

    private var sheetContent: some View {
        playerAndGuideSurface
        .modifier(PrototypeSheetPresentation(selection: $sheet, onDismiss: {
            if let item = pendingLibraryNavigation {
                pendingLibraryNavigation = nil
                openLibraryItem(item)
            } else if let favorite = pendingMultiviewFavorite {
                pendingMultiviewFavorite = nil
                restoreMultiviewFavorite(favorite)
            } else if pendingIPTVConnection {
                pendingIPTVConnection = false
                providerSetupRouter?.connectIPTV(playlist: pendingIPTVPlaylist, mode: pendingIPTVMode)
                pendingIPTVPlaylist = nil
            } else if pendingServerConnection {
                pendingServerConnection = false
                connectServer?()
            } else if let id = pendingTuneID {
                pendingTuneID = nil
                tune(id)
            }
        }) { destination in
            PrototypeSheetContent(
                model: model, imports: imports, destination: destination,
                reload: requestCatalogRefresh,
                showGuide: {
                    model.guideOnly = true
                    topRequest += 1
                },
                guideOffset: Binding(
                    get: { guideOffset },
                    set: { guideOffset = $0; timelineOffset = 0 }
                ),
                goToNow: { nowRequest += 1 },
                guideStart: timeAnchor.addingTimeInterval(guideOffset),
                tune: { pendingTuneID = $0 },
                openMultiview: { pendingMultiviewFavorite = $0; sheet = nil },
                channelActionTitle: multiviewSelection?.title,
                sourceManagement: sources == nil ? nil : { AnyView(sourceSetupDestination($0)) },
                openLibraryItem: onOpenTitle == nil ? nil : {
                    pendingLibraryNavigation = $0
                    sheet = nil
                },
                canMutate: { isActive && isProfileAuthorized() }
            )
            .environment(\.themePalette, palette)
            .tint(palette.accent)
        })
    }

    private var previewIntroductionContent: some View {
        sheetContent.modifier(LiveTVPreviewIntroductionPresentation(
            isPresented: showsPreviewIntroduction,
            choose: choosePreviews,
            onDismiss: {
                guard isActive, isProfileAuthorized() else { return }
                applyViewSettings()
                updatePreviewAvailability()
                focusInitialChannelIfNeeded()
            }
        ))
    }

    private var presentedContent: some View {
        previewIntroductionContent.alert("Couldn't open title", isPresented: Binding(
            get: { libraryNavigationIssue != nil },
            set: { if !$0 { libraryNavigationIssue = nil } }
        ), presenting: libraryNavigationIssue) { _ in
            Button("OK", role: .cancel) { libraryNavigationIssue = nil }
        } message: { issue in
            Text(issue.message)
        }
        .alert("Multiview", isPresented: Binding(
            get: { isActive && (multiviewFavoriteIssue != nil || (!multiview.isEnabled && multiview.issue != nil)) },
            set: {
                if !$0 {
                    multiviewFavoriteIssue = nil
                    if !multiview.isEnabled { multiview.dismissIssue() }
                }
            }
        )) {
            Button("OK", role: .cancel) {
                multiviewFavoriteIssue = nil
                if !multiview.isEnabled { multiview.dismissIssue() }
            }
        } message: {
            if let issue = multiviewFavoriteIssue ?? multiview.issue { Text(issue) }
        }
        .alert("Can't play this channel", isPresented: Binding(
            get: { isActive && playback.watchFailure != nil },
            set: { if !$0 { playback.dismissFailure() } }
        ), presenting: playback.watchFailure) { failure in
            if let report = failure.playbackFailure {
                Button("Details") { sheet = .diagnostics(.playback(report)) }
            }
            if failure.currentToStop != nil {
                Button("Stop current channel and retry", role: .destructive) {
                    playback.stopCurrentAndRetry(failure)
                }
            }
            Button("OK", role: .cancel) { playback.dismissFailure() }
        } message: { failure in
            Text(failure.message)
        }
        .alert("Live TV preferences unavailable", isPresented: Binding(
            get: { isActive && sheet == nil && model.preferencesIssue != nil },
            set: { if !$0 { model.dismissPreferencesIssue() } }
        )) {
            Button("Retry") { model.retryPreferences() }
            Button("Not now", role: .cancel) { model.dismissPreferencesIssue() }
        } message: {
            if model.preferencesIssue == .loadFailed {
                Text("Your Favorites, recently watched channels, and hidden channels could not be loaded. Retry before making changes. Your saved preferences have not been replaced.")
            } else {
                Text("The change to your Favorites, recently watched channels, or hidden channels could not be saved. Retry to keep it across sessions.")
            }
        }
    }

    private var loadingContent: some View {
        presentedContent
        .onChange(of: isInitialCatalogLoading, initial: true) { _, loading in
            recordSourceDiagnostics(.guideState)
            HandoffDiagnostics.emit("LIVE_TV event=guideLoading loading=\(loading) channels=\(model.channels.count)")
        }
        .onChange(of: model.channels.count) { _, _ in recordSourceDiagnostics(.guideState) }
        .onChange(of: sheet != nil) { _, _ in recordSourceDiagnostics(.sheetChanged) }
        .task(id: isActive && isProfileAuthorized() ? reloadRequest : -1) {
            await reloadCatalog()
        }
        .task(id: preview.pendingRequest) {
            await preparePendingPreview()
        }
        .task(id: playback.preparation.current?.channel.id) {
            // The guide warms only what is on and ahead; the player's timeline
            // also splits a live rewind window at what already aired.
            guard let channelID = playback.preparation.current?.channel.id else { return }
            await imports.reloadServerGuides(
                channelIDs: [channelID],
                from: model.now.addingTimeInterval(-LiveTVPrototypeImportModel.guideLookback),
                to: model.now, into: model
            )
        }
        .task(id: isActive) {
            while isActive && !Task.isCancelled {
                model.synchronizeClock()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func preparePendingPreview() async {
        guard let request = preview.pendingRequest else { return }
        do {
            try await Task.sleep(for: LiveTVPreviewController.settlingDelay)
        } catch is CancellationError {
            return
        } catch {
            assertionFailure("Unexpected preview timer failure: \(error)")
            return
        }
        guard !Task.isCancelled, !needsPreviewChoice, homeModel?.pendingRequest == nil else { return }
        if await playback.preparePreview(request) {
            let elapsed = request.focusedAt.duration(to: ContinuousClock.now).components
            let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
            HandoffDiagnostics.emit(
                "LIVE_TV event=previewCommit settleMs=\(String(format: "%.0f", milliseconds))"
            )
        }
    }

    private var homeObservedContent: some View {
        loadingContent
        .onChange(of: model.catalogRevision) { _, _ in publishHomeSnapshot() }
        .onChange(of: model.recentChannelIDs) { _, _ in publishHomeSnapshot() }
        .onChange(of: model.favoriteOrder) { _, _ in publishHomeSnapshot() }
        .onChange(of: model.hiddenChannels) { _, _ in publishHomeSnapshot() }
        .onChange(of: model.preferencesIssue) { _, _ in publishHomeSnapshot() }
        .onChange(of: homeModel?.pendingRequest, initial: true) { _, _ in
            updatePreviewAvailability()
            handleHomeSelection()
        }
        .onChange(of: loadedRequest) { _, _ in
            publishHomeSnapshot()
            handleHomeSelection()
        }
        .onChange(of: needsPreviewChoice) { _, _ in handleHomeSelection() }
    }

    private var portableStateObservedContent: some View {
        homeObservedContent
        .onChange(of: scanBinding.coordinator.scanHiddenChannelIDs) { _, _ in
            scanBinding.synchronizeVisibility()
        }
        .onChange(of: holdsPlaybackIdentity, initial: true) { _, holding in
            portableIdentityHold.update(holding)
            if !holding, pendingPortableReload {
                pendingPortableReload = false
                loadedRequest = nil
                reloadRequest &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply)) { notification in
            guard notification.object as? String == profileID else { return }
            model.reloadPreferences()
            refreshSourceAuthority()
            if holdsPlaybackIdentity {
                pendingPortableReload = true
            } else {
                loadedRequest = nil
                reloadRequest &+= 1
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange)
                .receive(on: DispatchQueue.main)
        ) { notification in
            guard notification.object as? String == profileID else { return }
            refreshSourceAuthority()
        }
        .onChange(of: libraryCatalogRevision, initial: true) { _, revision in
            guard let revision else { return }
            publishLibraryGuide(
                channelIDs: Set(revision.channels.prefix(PrototypeGuideWindowRequest.rowLimit).map(\.id)),
                range: DateInterval(start: timeAnchor, duration: 6 * 3_600)
            )
        }
    }

    private var playerStateObservedContent: some View {
        portableStateObservedContent
        .onChange(of: playback.preparation.current?.id) { _, _ in
            playback.synchronizePlayerState()
            updatePlaybackAvailability()
        }
        .onChange(of: playback.preparation.isPreparing) { _, _ in
            playback.synchronizePlayerState()
        }
        .onChange(of: playback.canAutoPreview) { _, _ in
            updatePreviewAvailability()
        }
        .onChange(of: playback.acceptedWatchID) { _, _ in
            handleWatchAcceptance()
        }
        .onChange(of: model.channels) { _, _ in
            playback.validateAuthorization()
            multiview.validateAuthorization()
            updatePlaybackAvailability()
        }
        .onChange(of: imports.serverChannelReferences) { _, _ in
            playback.validateAuthorization()
            multiview.validateAuthorization()
            updatePlaybackAvailability()
        }
    }

    private var playbackObservedContent: some View {
        playerStateObservedContent
        .onChange(of: sources?.mutationRevision) { _, _ in
            guard applySourceConfiguration() else { return }
            loadedRequest = nil
            reloadRequest &+= 1
        }
        .onChange(of: sourceAuthority.contextIdentity) { _, _ in
            scanBinding.deactivate()
            refreshSourceAuthority()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange)) { _ in
            scanBinding.deactivate()
            refreshSourceAuthority()
        }
        .onChange(of: serverAuthorizationID) { _, _ in
            recordSourceDiagnostics(.authorityChanged)
            enrollment.invalidate()
            playbackResolvers.update(
                serverProviderResolver: serverProviderResolver,
                authenticatedHTTPResolver: authenticatedHTTPResolver
            )
            playback.validateAuthorization()
            multiview.validateAuthorization()
            do {
                try imports.setServerProviderResolver(
                    { [playbackResolvers] in playbackResolvers.provider(for: $0) }, into: model
                )
                playback.validateAuthorization()
                sourceApplicationFailed = false
                loadedRequest = nil
                reloadRequest &+= 1
            } catch {
                sourceApplicationFailed = true
                playback.stop()
                multiview.stop()
            }
            updatePlaybackAvailability()
        }
    }

    private var browsingObservedContent: some View {
        playbackObservedContent
        .onChange(of: selectedChannelID) { _, id in playback.focus(id) }
        .onChange(of: model.sort) { _, _ in persistViewFilters() }
        .onChange(of: model.favoritesOnly) { _, _ in persistViewFilters() }
        .onChange(of: model.guideOnly) { _, _ in persistViewFilters() }
        .onChange(of: controlsActive) { _, active in
            updatePreviewAvailability()
        }
        .onChange(of: guideHasFocus) { _, focused in
            updatePreviewAvailability()
        }
        .onChange(of: sheet?.id) { _, _ in
            if sheet != nil { playback.cancelWatch() }
            else {
                managesLibraryChannels = false
                showsScanSources = false
            }
            updatePreviewAvailability()
            focusInitialChannelIfNeeded()
            handleHomeSelection()
        }
        .onChange(of: model.guideChannels.first?.id, initial: true) { _, _ in
            focusInitialChannelIfNeeded()
        }
    }

    private var lifecycleContent: some View {
        browsingObservedContent
        .onChange(of: scenePhase, initial: true) { _, _ in
            recordSourceDiagnostics(.guideState)
            updatePlaybackAvailability()
            handleHomeSelection()
        }
        .onChange(of: isProfileAuthorized(), initial: true) { _, authorized in
            if !authorized {
                enrollment.invalidate()
                loadedRequest = nil
            }
            updatePlaybackAvailability()
        }
        .onChange(of: allowsPlayback, initial: true) { _, _ in
            updatePlaybackAvailability()
            handleHomeSelection()
        }
        .onChange(of: isActive, initial: true) { wasActive, active in
            recordSourceDiagnostics(.guideState)
            if !active {
                if wasActive { homeModel?.cancelRequest() }
                enrollment.invalidate()
                loadedRequest = nil
                pendingServerConnection = false
                pendingIPTVConnection = false
                pendingIPTVPlaylist = nil
                pendingTuneID = nil
                pendingMultiviewFavorite = nil
                sheet = nil
                if !hasAuthorizedExternalPlayback {
                    leaveMultiview()
                    multiview.setActive(false)
                    playback.stop()
                }
            }
            if active {
                model.reloadPreferences()
                applyViewSettings()
            }
            updatePlaybackAvailability()
            if active { playback.focus(selectedChannelID) }
            focusInitialChannelIfNeeded()
            handleHomeSelection()
        }
        .onChange(of: hidesAppNavigation, initial: true) { _, hidesChrome in
            onExpandedChange(hidesChrome)
        }
        .onAppear(perform: updatePlaybackAvailability)
        .onDisappear(perform: handleDisappearance)
    }

    private func handleDisappearance() {
        let preservesFullscreen = isActive && isProfileAuthorized() && usesNativeFullscreen && preview.isExpanded
        guard !preservesFullscreen, !hasAuthorizedExternalPlayback else { return }
        enrollment.invalidate()
        leaveMultiview()
        multiview.setActive(false)
        playback.setActive(false)
        scanBinding.deactivate()
        portableIdentityHold.update(false)
        onExpandedChange(false)
    }

    private var holdsPlaybackIdentity: Bool {
        multiview.panes.contains { $0.preparation.current != nil || $0.preparation.isPreparing }
            || playback.pendingWatchChannelID != nil
    }

    @ViewBuilder
    private func guideContent(_ layout: PrototypePreviewLayout, canvasWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let sources, (!sources.hasLoaded && sources.loadIssue != nil) || sourceApplicationFailed {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVSourceLoadState(
                        issue: sources.loadIssue,
                        applicationFailed: sourceApplicationFailed,
                        retry: requestCatalogRefresh
                    )
                }
            } else if isInitialCatalogLoading || sources?.hasLoaded == false {
                catalogGuideContent(layout, canvasWidth: canvasWidth)
            } else if model.channels.isEmpty, let automaticChannels,
                      automaticChannels.needsEmptyState, canManageLibraryChannels,
                      !enrollment.statuses.contains(where: { $0.failure != nil }),
                      automaticChannels.isWorking || !isInitialCatalogLoading {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVAutomaticChannelsEmptyView(state: automaticChannels) {
                        managesLibraryChannels = true
                        sheet = .sources
                    }
                }
            } else if model.channels.isEmpty,
                      isInitialCatalogLoading || libraryIssue != nil || libraryGuideIssue != nil {
                catalogGuideContent(layout, canvasWidth: canvasWidth)
            } else if model.channels.isEmpty, blockedPlaylistCount > 0 {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    ContentUnavailableView {
                        Label("Source approval needed", systemImage: "lock")
                    } description: {
                        Text("Ask a parent to approve your IPTV sources. One approval covers every channel in a source.")
                    } actions: {
                        Button("Manage sources") { sheet = .sources }
                    }
                }
            } else if let sources,
                      model.channels.isEmpty,
                      sources.configuration.playlists.isEmpty && sources.configuration.servers.isEmpty {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    LiveTVSetupWelcome(
                        addPlaylist: {
                            if providerSetupRouter != nil { requestIPTVConnection() }
                            else { sheet = .addPlaylist }
                        },
                        useServer: { sheet = .serverSetup },
                        issue: sources.mutationIssue?.message,
                        serverStatuses: enrollment.statuses.filter { $0.phase != .idle },
                        retryServers: requestCatalogRefresh,
                        createChannel: canManageLibraryChannels ? {
                            managesLibraryChannels = true
                            sheet = .sources
                        } : nil,
                        automaticChannels: automaticChannels
                    )
                }
            } else if let sources,
                      model.channels.isEmpty,
                      !sources.configuration.playlists.contains(where: \.isEnabled),
                      !sources.configuration.servers.contains(where: \.isEnabled) {
                PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                    ContentUnavailableView {
                        Label("Your sources are paused", systemImage: "pause.circle")
                    } description: {
                        Text("Enable a source to bring its channels back to the guide.")
                    } actions: {
                        Button("Manage sources") { sheet = .sources }
                    }
                }
            } else {
                catalogGuideContent(layout, canvasWidth: canvasWidth)
            }
        }
    }

    @ViewBuilder
    private func catalogGuideContent(_ layout: PrototypePreviewLayout, canvasWidth: CGFloat) -> some View {
        #if os(tvOS)
        if isSearching {
            PrototypeGuidePlacement(frame: layout.bounds, canvasWidth: canvasWidth) {
                PrototypeNativeSearch(
                    query: $model.query, restoresGuideFocus: preview.isRestoringGuideFocus,
                    isPresented: isActive && isGuidePresented && sheet == nil,
                    close: closeSearch, editing: { controlsActive = true }
                ) { dismissSearch in
                    VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                        if let multiviewSelection {
                            LiveTVMultiviewGuideSelectionHeader(
                                selection: multiviewSelection, cancel: finishMultiviewSelection)
                        }
                        searchScopePicker
                        if searchScope == .channels {
                            PrototypeSearchSummary(channelCount: model.visibleChannels.count, category: model.category)
                        }
                        searchResults(closeSearch: dismissSearch)
                    }
                    .ignoresSafeArea(.container, edges: [.bottom, .trailing])
                    .environment(\.themePalette, palette)
                    .environment(\.plozzReduceTransparency, reduceTransparency)
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.layoutDirection, layoutDirection)
                    .environment(\.locale, locale)
                }
            }
            .transition(.opacity)
        } else {
            PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
                browsingContent(layout)
            }
            .transition(.opacity)
        }
        #else
        PrototypeGuidePlacement(frame: layout.contentFrame, canvasWidth: canvasWidth) {
            browsingContent(layout)
        }
        #endif
    }

    @ViewBuilder
    private func sourceSetupDestination(_ destination: PrototypeSheet) -> some View {
        if let sources {
            switch destination {
            case .addPlaylist:
                LiveTVSourceAccessGate(model: sources) { _ in
                    LiveTVPlaylistEditor { input in
                        let previous = Set(sources.configuration.playlists.map(\.id))
                        try sources.savePlaylist(input: input)
                        pendingScanOfferSourceID = sources.configuration.playlists.last {
                            !previous.contains($0.id)
                        }?.id
                        didConfigurePlaylist()
                    }
                }
            case .serverSetup:
                LiveTVSourceAccessGate(model: sources) { _ in
                    LiveTVServerSetupView(
                        sources: sources, choices: serverChoices,
                        resolver: serverProviderResolver,
                        connectServer: connectServer == nil ? nil : requestServerConnection
                    )
                }
            default:
                LiveTVSourcesView(
                    model: sources, imports: imports, refresh: requestCatalogRefresh,
                    refreshSource: { try await imports.reloadSource($0, into: model) },
                    serverChoices: serverChoices, serverProviderResolver: serverProviderResolver,
                    connectServer: connectServer == nil ? nil : requestServerConnection,
                    connectIPTV: providerSetupRouter == nil ? nil : requestIPTVConnection,
                    sourceFilterID: model.configuredSourceID,
                    browseSource: { sourceID in
                        model.source = nil
                        model.configuredSourceID = sourceID
                        topRequest &+= 1
                        sheet = nil
                    },
                    didConfigurePlaylist: didConfigurePlaylist,
                    createChannel: canManageLibraryChannels ? { managesLibraryChannels = true } : nil,
                    scanChannels: { showsScanSources = true },
                    scanCoordinator: scanBinding.coordinator,
                    didImportPlaylist: { pendingScanOfferSourceID = $0 }
                )
                .navigationDestination(isPresented: $managesLibraryChannels) {
                    if let libraryService, let libraryHistory {
                        LibraryChannelManagementView(
                            service: libraryService, history: libraryHistory,
                            prepareLibraries: prepareLibraryChannels, automaticChannels: automaticChannels)
                    }
                }
                .navigationDestination(isPresented: $showsScanSources) {
                    LiveTVSourceAccessGate(model: sources) { _ in
                        if scanBinding.issue != nil {
                            LiveTVSettingsPage(title: "Check channels") {
                                SettingsSectionGroup {
                                    Text("Channel checks are unavailable. Your channel preferences are unchanged.")
                                    Button("Retry", action: scanBinding.retry)
                                        .buttonStyle(PrototypeButtonStyle())
                                }
                            }
                        } else {
                            LiveTVScanSourcesView(
                                coordinator: scanBinding.coordinator,
                                sourceNames: Dictionary(uniqueKeysWithValues: imports.configuration.playlists.map {
                                    ($0.id, $0.name)
                                })
                            )
                        }
                    }
                }
            }

        }
    }

    private func requestServerConnection() {
        pendingTuneID = nil
        pendingServerConnection = true
        sheet = nil
    }

    private func requestIPTVConnection(
        _ playlist: LiveTVPlaylistSource? = nil, mode: IPTVCredential.Mode = .playlist
    ) {
        if sheet != nil {
            pendingIPTVConnection = true
            pendingIPTVPlaylist = playlist
            pendingIPTVMode = mode
            sheet = nil
        } else {
            providerSetupRouter?.connectIPTV(playlist: playlist, mode: mode)
        }
    }

    private var libraryCatalogRevision: PrototypeLibraryCatalogRevision? {
        libraryService.map { PrototypeLibraryCatalogRevision(service: $0, isAuthorized: libraryIsAuthorized()) }
    }

    private var canManageLibraryChannels: Bool {
        libraryService != nil && libraryHistory != nil
    }

    private var isInitialCatalogLoading: Bool {
        guard model.channels.isEmpty else { return false }
        // An empty saved source list is not final while enrollment or library
        // hydration/publication can still supply channels.
        if loadedRequest != reloadRequest || imports.catalogPhase == .loading
            || automaticChannels?.isWorking == true {
            return true
        }
        guard libraryIssue == nil, libraryGuideIssue == nil,
              let catalog = libraryCatalogRevision else { return false }
        return !catalog.isLoaded || !catalog.channels.isEmpty
    }

    private func publishLibraryGuide(channelIDs: Set<String>, range: DateInterval) {
        guard let libraryService else { return }
        installCatalogHooks()
        do {
            let channels = libraryIsAuthorized() ? libraryService.channels : []
            let allowed = Set(channels.map(\.id))
            let programs = allowed.isEmpty ? [] : try libraryService.programmes(
                channelIDs: channelIDs.intersection(allowed), from: range.start, to: range.end
            )
            try imports.setGeneratedCatalog(channels: channels, programs: programs, into: model)
            libraryGuideIssue = nil
        } catch {
            libraryGuideIssue = (error as? LibraryChannelError) ?? .storageFailed
            do {
                try imports.setGeneratedCatalog(channels: [], programs: [], into: model)
            } catch {
                sourceApplicationFailed = true
                playback.stop()
                multiview.stop()
                HandoffDiagnostics.emit("LIVE_TV event=libraryCatalogRetirementFailed")
            }
        }
        playback.validateAuthorization()
        multiview.validateAuthorization()
        updatePlaybackAvailability()
    }

    private func requestCatalogRefresh() {
        pendingServerRefresh = true
        reloadRequest &+= 1
    }

    private func publishHomeSnapshot() {
        guard let homeModel, let homeAuthorizationID, homeModel.profileID == profileID,
              isProfileAuthorized(), !sourceApplicationFailed,
              loadedRequest == reloadRequest,
              let configuration = sources?.configuration,
              let authorization = try? sourceAuthority.authorization(configuration: configuration),
              authorization.identity == appliedSourceAuthorizationID else { return }
        homeModel.publish(HomeLiveTVCatalogProjection.snapshot(
            model: model, imports: imports, profileID: profileID, authorization: authorization,
            serverAuthorizationID: homeAuthorizationID, serverProvider: serverProviderResolver
        ))
    }

    private func handleHomeSelection() {
        guard let homeModel, let request = homeModel.pendingRequest, isActive else { return }
        guard isProfileAuthorized(), request.route.profileID == profileID else {
            homeModel.cancelRequest()
            return
        }
        guard loadedRequest == reloadRequest, !sourceApplicationFailed,
              scenePhase == .active, activity.acceptsInteraction, !needsPreviewChoice,
              sheet == nil, allowsPlayback else { return }
        guard let homeAuthorizationID, let configuration = sources?.configuration,
              let authorization = try? sourceAuthority.authorization(configuration: configuration),
              authorization.identity == appliedSourceAuthorizationID,
              HomeLiveTVCatalogProjection.accepts(
                request.route, model: model, imports: imports, profileID: profileID,
                authorization: authorization, serverAuthorizationID: homeAuthorizationID,
                serverProvider: serverProviderResolver
              ) else {
            _ = homeModel.consume(request)
            return
        }
        guard homeModel.consume(request) else { return }
        // Reuse the coordinator's explicit watch path, including mobile network
        // policy, source approval, lease ownership and watched-only recents.
        tune(request.route.channelID)
    }

    private func reloadCatalog() async {
        recordSourceDiagnostics(.guideReload)
        defer { recordSourceDiagnostics(.guideReloaded) }
        guard isActive, isProfileAuthorized(), loadedRequest != reloadRequest else { return }
        installCatalogHooks()
        let request = reloadRequest
        if let sources {
            sources.reload()
            guard sources.hasLoaded, applySourceConfiguration() else {
                playback.validateAuthorization()
                return
            }
        }
        async let enrolled = enrollAuthorizedServers()
        await imports.reload(into: model, forceServerRefresh: pendingServerRefresh)
        let added = await enrolled
        guard !Task.isCancelled, request == reloadRequest, isProfileAuthorized() else { return }
        if !added.isEmpty, let sources {
            sources.reload()
            guard sources.hasLoaded, applySourceConfiguration() else { return }
            await imports.reloadServers(into: model, forceRefresh: false)
        }
        if !Task.isCancelled, request == reloadRequest {
            loadedRequest = request
            pendingServerRefresh = false
        }
    }

    private func enrollAuthorizedServers() async -> [String] {
        guard let sourceStore, sources?.hasLoaded == true, isProfileAuthorized(),
              !serverChoices.isEmpty else { return [] }
        return await enrollment.refresh(
            choices: serverChoices, resolver: serverProviderResolver,
            store: sourceStore,
            suppressedAccountIDs: { try enrollmentSuppression.suppressedAccountIDs() },
            isAuthorized: isProfileAuthorized, diagnosticProfileID: profileID
        )
    }

    private func recordSourceDiagnostics(_ event: LiveTVSourceDiagnostics.Event) {
        LiveTVSourceDiagnostics.shared.record(
            event, identities: [.profile: profileID],
            counts: [
                .channels: model.channels.count, .playlists: sources?.configuration.playlists.count ?? 0,
                .servers: sources?.configuration.servers.count ?? 0, .choices: serverChoices.count
            ],
            flags: [
                .active: isActive, .authorized: isProfileAuthorized(), .loading: isInitialCatalogLoading,
                .failed: sourceApplicationFailed, .present: sources?.hasLoaded == true,
                .current: loadedRequest == reloadRequest, .cancelled: Task.isCancelled,
                .sheet: sheet != nil, .sceneActive: scenePhase == .active
            ]
        )
    }

    @discardableResult
    private func applySourceConfiguration() -> Bool {
        guard let sources, sources.hasLoaded else { return false }
        do {
            let authorization = try sourceAuthority.authorization(configuration: sources.configuration)
            try imports.applyConfiguration(authorization.filtering(sources.configuration), into: model)
            appliedSourceAuthorizationID = authorization.identity
            playback.validateAuthorization()
            multiview.validateAuthorization()
            sourceApplicationFailed = false
            updatePlaybackAvailability()
            return true
        } catch {
            sourceApplicationFailed = true
            externalPlayback = nil
            multiview.setActive(false)
            playback.stop()
            updatePlaybackAvailability()
            return false
        }
    }

    private func refreshSourceAuthority() {
        guard let sources else { return }
        let previousConfiguration = sources.configuration
        sources.reload()
        guard sources.hasLoaded else {
            sourceApplicationFailed = true
            updatePlaybackAvailability()
            return
        }
        let previous = appliedSourceAuthorizationID
        guard applySourceConfiguration() else { return }
        if previous != appliedSourceAuthorizationID || previousConfiguration != sources.configuration {
            loadedRequest = nil
            reloadRequest &+= 1
        }
    }

    private func browseToolbar(_ layout: PrototypePreviewLayout) -> some View {
        PrototypeBrowseToolbar(
            model: model, active: $controlsActive,
            focusRequest: toolbarFocusRequest,
            compact: layout.contentFrame.width < 650,
            isSearching: isSearching,
            search: { if isSearching { closeSearch() } else { openSearch() } },
            filters: { sheet = .filters },
            multiviews: multiviewSelection == nil ? { sheet = .multiviewFavorites } : nil
        )
        .modifier(LiveTVMultiviewGuideExit(
            cancel: multiviewSelection == nil ? nil : finishMultiviewSelection))
        .disabled(blocksBrowseControls)
    }

    private func usesCategoryDirectory(_ layout: PrototypePreviewLayout) -> Bool {
        #if os(iOS)
        showsCategoryDirectory && layout.availableSidebarWidth == 0
        #else
        false
        #endif
    }

    private func browsingContent(_ layout: PrototypePreviewLayout) -> some View {
        PrototypeBrowseLayout(
            layout: layout, extendsGuideToEdges: !usesCategoryDirectory(layout) && !isSearching
        ) {
            browsingHeader(layout)
        } sidebar: {
            browsingSidebar
        } guide: {
            VStack(spacing: PrototypeLayout.toolbarGuideGap) {
                #if os(tvOS)
                if layout.availableSidebarWidth == 0 {
                    browseToolbar(layout)
                }
                #endif
                if usesCategoryDirectory(layout) && model.query.isEmpty {
                    if isInitialCatalogLoading || model.categoryChannelCount(nil) == 0 {
                        guideBrowser(closeSearch: closeSearch)
                    } else {
                        PrototypeCategoryDirectory(
                            categories: model.browsingCategories, totalCount: model.categoryChannelCount(nil),
                            returnCategory: categoryDirectoryReturnID, select: { showCategory($0) }
                        )
                    }
                } else if isSearching || usesCategoryDirectory(layout) {
                    searchScopePicker
                        #if os(iOS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                    searchResults(closeSearch: closeSearch)
                } else {
                    guideBrowser(
                        closeSearch: closeSearch,
                        leadingExit: layout.availableSidebarWidth > 0 ? revealCategories : nil
                    )
                    .disabled(usesNativeFullscreen && controlsActive)
                }
            }
        }
    }

    @ViewBuilder
    private var browsingSidebar: some View {
        Group {
            if isInitialCatalogLoading {
                PrototypeLoadingSidebar()
            } else {
                PrototypeBrowseSidebar(
                    model: model, active: $controlsActive,
                    focusRequest: toolbarFocusRequest, isSearching: isSearching,
                    categoryFocusRequest: categoryFocusRequest,
                    restoresCategoryFocus: sidebarRestoresCategoryFocus,
                    search: { if isSearching { closeSearch() } else { openSearch() } },
                    enterGuide: enterGuide,
                    selectCategory: { showCategory($0, enteringGuide: false) },
                    multiviews: multiviewSelection == nil ? { sheet = .multiviewFavorites } : nil,
                    manageChannels: { sheet = .organization }
                )
                .modifier(LiveTVMultiviewGuideExit(
                    cancel: multiviewSelection == nil ? nil : finishMultiviewSelection))
            }
        }
        .disabled(blocksBrowseControls)
        #if os(tvOS)
        .disabled(!controlsActive && !model.guideChannels.isEmpty)
        #endif
    }

    @ViewBuilder
    private func browsingHeader(_ layout: PrototypePreviewLayout) -> some View {
        #if os(iOS)
        if isSearching || usesCategoryDirectory(layout) {
            PrototypeSearchHeader(
                query: $model.query, channelCount: model.visibleChannels.count,
                category: model.category, focusRequest: searchFocusRequest,
                browse: enterGuide, close: {
                    if isSearching { closeSearch() } else { model.query = "" }
                },
                focusChanged: { if $0 { controlsActive = true } },
                showsSummary: !model.query.isEmpty
            )
            .disabled(blocksBrowseControls)
        } else {
            Color.clear
                .frame(height: layout.heroHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        #else
        ZStack(alignment: .bottomLeading) {
            PrototypePreviewHero(
                channel: heroChannel, program: heroProgram, layout: layout,
                watch: { if let id = heroChannel?.id { tune(id) } },
                watchTitle: multiviewSelection?.title,
                isLoading: isInitialCatalogLoading
            )
            .opacity(isSearching ? 0 : 1)
            .allowsHitTesting(!isSearching)
            .accessibilityHidden(isSearching)
        }
        .frame(height: layout.heroHeight, alignment: layout.heroAlignment)
        #endif
        if let multiviewSelection {
            LiveTVMultiviewGuideSelectionHeader(
                selection: multiviewSelection, cancel: finishMultiviewSelection)
        }
        if heroIsGuideOnly && !isSearching {
            Text("Guide only · This server's Live TV playback mode isn't supported yet.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        if blockedPlaylistCount > 0 && !isSearching {
            Text("Some IPTV sources need parental approval in Sources.")
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
        if let issue = libraryGuideIssue ?? libraryIssue, !isSearching {
            HStack {
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                if let reloadLibrary {
                    Button("Retry Plozz channels", action: reloadLibrary)
                        .buttonStyle(PrototypeButtonStyle())
                }
            }
            if let pendingScanOfferSourceID, !isSearching {
                LiveTVScanImportOffer(
                    coordinator: scanBinding.coordinator, sourceID: pendingScanOfferSourceID,
                    skip: { self.pendingScanOfferSourceID = nil }
                )
            }
        }
    }

    private func guideBrowser(
        closeSearch: @escaping () -> Void, leadingExit: (() -> Void)? = nil
    ) -> some View {
        PrototypeBrowser(
            model: model, imports: imports,
            selectedID: $selectedChannelID, selectedRowID: $selectedRowID,
            railActive: $controlsActive, focusedProgram: $focusedProgram, hasFocus: $guideHasFocus,
            topRequest: topRequest, nowRequest: nowRequest, guideOffset: $guideOffset,
            timeAnchor: $timeAnchor, timelineOffset: $timelineOffset,
            restoreFocusRequest: preview.focusRestoreRequest,
            isPresented: isActive && isGuidePresented && sheet == nil,
            isRestoringFocus: preview.isRestoringGuideFocus,
            restoresPlaybackFocus: preview.restoresPlaybackFocus, watchOrigin: preview.watchOrigin,
            focusRestored: {
                preview.completeGuideFocusRestore($0, focusedChannelID: selectedChannelID)
            },
            tune: { tune($0.channelID, origin: $0) },
            details: { sheet = .program($0) }, openControls: openSearch,
            openSources: { sheet = .sources }, openGuideTime: { sheet = .guideTime },
            openToolbar: usesNativeFullscreen && !isSearching && playback.pendingWatchChannelID == nil ? nil : {
                if playback.pendingWatchChannelID != nil {
                    playback.cancelWatch()
                    return
                }
                guard !preview.isRestoringGuideFocus else { return }
                if isSearching {
                    closeSearch()
                    return
                }
                controlsActive = true
                sidebarRestoresCategoryFocus = false
                toolbarFocusRequest &+= 1
            },
            isLoading: isInitialCatalogLoading,
            loadFailed: imports.catalogPhase == .failed || libraryIssue != nil || libraryGuideIssue != nil,
            reload: { reloadLibrary?(); requestCatalogRefresh() },
            openChannelManagement: { sheet = .organization },
            hideChannel: hideChannel,
            selectionAction: multiviewSelection?.title,
            selectedChannelIDs: multiviewSelection == nil ? [] : Set(multiview.panes.compactMap { $0.channel?.id }),
            libraryCatalog: libraryCatalogRevision,
            loadLibraryGuide: publishLibraryGuide,
            openLibraryItem: onOpenTitle == nil ? nil : openLibraryItem,
            leadingExit: leadingExit,
            previewChannel: previewChannelSelection
        )
    }

    private var previewChannelSelection: ((LiveTVGuideRowID) -> Void)? {
        #if os(iOS)
        { row in
            if isSearching { closeSearch() }
            tune(row.channelID, origin: row, expandsPlayer: false)
        }
        #else
        nil
        #endif
    }

    private func revealCategories() {
        guard activity.acceptsInteraction, !isSearching, !preview.isRestoringGuideFocus,
              sheet == nil, !needsPreviewChoice else { return }
        sidebarRestoresCategoryFocus = true
        controlsActive = true
        categoryFocusRequest &+= 1
    }

    private var searchScopePicker: some View {
        Picker("Search in", selection: $searchScope) {
            Text("Channels").tag(PrototypeSearchScope.channels)
            Text("Programs").tag(PrototypeSearchScope.programs)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 640, alignment: .leading)
        .accessibilityIdentifier("live-tv-search-scope")
        .onChange(of: searchScope) { _, _ in
            focusedProgram = nil
            playback.focus(nil)
        }
    }

    @ViewBuilder
    private func searchResults(closeSearch: @escaping () -> Void) -> some View {
        if searchScope == .channels {
            VStack(alignment: .leading, spacing: PrototypeLayout.smallGap) {
                if !model.matchingCategories.isEmpty {
                    PrototypeCategorySearchResults(categories: model.matchingCategoryResults) { category in
                        guard model.matchingCategories.contains(category) else { return }
                        #if os(iOS)
                        showCategory(category)
                        #else
                        pendingSearchCategory = category
                        closeSearch()
                        #endif
                    }
                }
                guideBrowser(closeSearch: closeSearch)
            }
        } else if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label("Search programs", systemImage: "magnifyingglass")
            } description: {
                Text("Search for a program in your available guide.")
            }
        } else {
            ScrollView {
                LiveTVProgramSearchView(
                    imports: imports, model: model, query: model.query,
                    watch: { tune($0.id) },
                    showDetails: { sheet = .program($0) }
                )
                .padding(PrototypeLayout.sectionGap)
            }
            .accessibilityIdentifier("live-tv-program-search-results")
        }
    }

    private var hidesAppNavigation: Bool {
        if showingMultiview { return isActive }
        #if os(tvOS)
        return preview.suppressesNavigation(isActive: isActive, isSearching: isSearching)
        #else
        return preview.suppressesNavigation(isActive: isActive)
        #endif
    }

    private var showingMultiview: Bool { multiview.isEnabled && multiviewSelection == nil }
    private var isGuidePresented: Bool { !showingMultiview && !preview.isExpanded }

    private func beginMultiviewSelection(_ selection: LiveTVMultiviewSelection) {
        guard activity.acceptsInteraction, multiview.isEnabled else { return }
        multiviewSelection = selection
        returnToGuide()
        if !preview.isRestoringGuideFocus { enterGuide() }
    }

    private func finishMultiviewSelection() {
        preview.completeGuideFocusRestore(preview.focusRestoreRequest, focusedChannelID: selectedChannelID)
        controlsActive = false
        multiviewSelection = nil
    }

    private func toggleMultiviewFavorite() {
        if let favorite = model.favoriteMultiviews.first(where: multiview.matches) {
            if model.removeMultiviewFavorite(favorite.id) { TouchFeedback.shared.emit(.confirmation) }
        } else if let favorite = multiview.favoriteSnapshot() {
            if model.saveMultiviewFavorite(favorite) { TouchFeedback.shared.emit(.confirmation) }
        } else {
            multiviewFavoriteIssue = "Wait for the channels to load before saving this Multiview."
        }
    }

    private func restoreMultiviewFavorite(_ favorite: LiveTVMultiviewFavorite) {
        guard activity.acceptsInteraction else { return }
        guard multiview.restore(favorite, from: model.channels),
              let first = favorite.channelIDs.first else { return }
        updatePlaybackAvailability()
        preview.watch(first)
    }

    private var blocksBrowseControls: Bool {
        #if os(tvOS)
        if !preview.hasRequestedInitialGuideFocus,
           model.guideChannels.first != nil || imports.catalogPhase == .idle || imports.catalogPhase == .loading {
            return true
        }
        #endif
        return preview.isRestoringGuideFocus
    }

    private func focusInitialChannelIfNeeded() {
        #if os(tvOS)
        if startsWithCategories && preview.requestInitialCategoryFocus(
            isActive: isActive, hasOverlay: isSearching || sheet != nil || needsPreviewChoice
        ) {
            controlsActive = true
            sidebarRestoresCategoryFocus = true
            categoryFocusRequest &+= 1
            return
        }
        guard let row = preview.requestInitialGuideFocus(
            isActive: isActive, hasOverlay: isSearching || sheet != nil || needsPreviewChoice
        ) else { return }
        selectedRowID = row
        selectedChannelID = row.channelID
        focusedProgram = nil
        controlsActive = false
        #endif
    }

    private var heroChannel: LiveTVPrototypeChannel? {
        (selectedChannelID ?? model.playingChannelID).flatMap { model.channel(id: $0) }
            ?? model.visibleChannels.first
    }

    private var blockedPlaylistCount: Int {
        guard let sources, sources.hasLoaded, !sourceApplicationFailed else { return 0 }
        let enabled = Set(sources.configuration.playlists.filter(\.isEnabled).map(\.id))
        return enabled.subtracting(imports.configuration.playlists.map(\.id)).count
    }

    private var heroProgram: LiveTVPrototypeProgram? {
        if let focusedProgram, focusedProgram.channelID == heroChannel?.id { return focusedProgram }
        return heroChannel.flatMap { model.currentProgram(for: $0.id) }
    }

    private var heroIsGuideOnly: Bool {
        guard let channel = heroChannel, let reference = imports.serverChannelReferences[channel.id] else {
            return false
        }
        return imports.serverSources.first(where: { $0.id == reference.sourceID })?
            .availability?.status == .unsupportedPlaybackMode
    }

    private func updatePreviewAvailability() {
        #if os(tvOS)
        let canFollowFocus = guideHasFocus
        #else
        let canFollowFocus = true
        #endif
        preview.setBrowsingActive(
            activity.acceptsInteraction && playback.canAutoPreview
                && sheet == nil && !needsPreviewChoice && !controlsActive && canFollowFocus && !multiview.isEnabled
                && homeModel?.pendingRequest == nil
        )
    }

    private func updatePlaybackAvailability() {
        if externalPlayback != nil && !hasAuthorizedExternalPlayback { externalPlayback = nil }
        let active = activity.isPlaybackActive
        scanBinding.setActive(
            isActive && scenePhase == .active && isProfileAuthorized()
                && !sourceApplicationFailed && allowsPlayback && (sources?.hasLoaded ?? true)
        )
        if !active && multiview.isEnabled { leaveMultiview() }
        multiview.setActive(active)
        playback.setActive(active)
        playback.setInteractionActive(activity.acceptsInteraction && !multiview.isEnabled)
        updatePreviewAvailability()
        if activity.acceptsInteraction { playback.focus(selectedChannelID) }
    }

    private func installCatalogHooks() {
        imports.beforeCatalogPublication = { [weak scanBinding] configuration, channels in
            scanBinding?.updateCatalog(configuration, channels: channels)
        }
        imports.beforeSourceRefresh = { [weak scanBinding] in scanBinding?.invalidate($0) }
        imports.generatedProgramLoader = { [weak libraryService, libraryIsAuthorized] channelIDs, range in
            guard let libraryService, libraryIsAuthorized() else {
                throw LibraryChannelError.authorizationChanged
            }
            return try libraryService.programmes(
                channelIDs: channelIDs, from: range.start, to: range.end
            )
        }
    }

    private func authorizesPlayback(_ prepared: LiveTVPreparedStream) -> Bool {
        // Parent updates can discard new init candidates; use the installed State owners.
        let channel = prepared.channel
        guard isProfileAuthorized(), sources?.hasLoaded ?? true,
              channel.source != .plozz || libraryIsAuthorized(),
              sourceAuthority.allows(channel, configuration: sources?.configuration ?? imports.configuration),
              LiveTVPlaybackCatalogAuthorization.allows(
                channel, reference: prepared.serverReference, model: model, imports: imports,
                configuration: sources?.configuration ?? imports.configuration,
                libraryService: libraryService
              ) else { return false }
        if case .libraryChannel(let id, let authorizationID) = prepared.input {
            return prepared.authorizationID == authorizationID
                && libraryService?.playbackEligibilityID(channelID: id) == authorizationID
        }
        return true
    }

    private var activity: LiveTVPlaybackActivity {
        LiveTVPlaybackActivity(
            isDestinationActive: isActive, isSceneActive: scenePhase == .active,
            isInBackground: scenePhase == .background,
            isAuthorized: isProfileAuthorized() && !sourceApplicationFailed && (sources?.hasLoaded ?? true),
            allowsPlayback: allowsPlayback,
            hasAuthorizedExternalPresentation: hasAuthorizedExternalPlayback
        )
    }

    private var hasAuthorizedExternalPlayback: Bool {
        guard allowsPlayback, !sourceApplicationFailed, !multiview.isEnabled, multiview.panes.count == 1,
              let externalPlayback,
              let pane = multiview.panes.first(where: { $0.id == externalPlayback.paneID }),
              let prepared = pane.preparation.current, prepared.id == externalPlayback.preparedID else {
            return false
        }
        return authorizesPlayback(prepared)
    }

    private func updateExternalPlayback(_ continuing: Bool, paneID: UUID, preparedID: UUID) {
        let identity = PrototypeExternalPlayback(paneID: paneID, preparedID: preparedID)
        if !continuing {
            if externalPlayback == identity { externalPlayback = nil }
            updatePlaybackAvailability()
            return
        }
        guard allowsPlayback, !sourceApplicationFailed, !multiview.isEnabled,
              let pane = multiview.panes.first(where: { $0.id == paneID }),
              let prepared = pane.preparation.current, prepared.id == preparedID,
              authorizesPlayback(prepared) else { return }
        externalPlayback = identity
        updatePlaybackAvailability()
    }

    private func restorePlayer(paneID: UUID, preparedID: UUID) async -> Bool {
        guard allowsPlayback, !sourceApplicationFailed,
              let pane = multiview.panes.first(where: { $0.id == paneID }),
              let prepared = pane.preparation.current, prepared.id == preparedID,
              authorizesPlayback(prepared) else { return false }
        if !isActive, !(await restoreDestination()) { return false }
        guard pane.preparation.current?.id == preparedID, allowsPlayback, !sourceApplicationFailed,
              authorizesPlayback(prepared) else { return false }
        preview.watch(prepared.channel.id)
        return true
    }

    /// Leaving fullscreen for the guide. Without Preview after watching the
    /// channel stops rather than carrying on behind the guide, and auto-preview
    /// leaves it alone until focus moves to another channel.
    private func leavePlaybackForGuide() {
        let leaving = playback.preparation.current?.channel.id
        returnToGuide()
        guard !previewAfterWatching, !multiview.isEnabled, !hasAuthorizedExternalPlayback else { return }
        playback.stop(suppressingPreviewOf: leaving)
        multiview.stop()
        updatePlaybackAvailability()
    }

    private func returnToGuide() {
        playback.cancelWatch()
        model.synchronizeClock()
        controlsActive = false
        #if os(tvOS)
        preview.returnToGuide()
        #else
        preview.returnToGuide(restoresFocus: false)
        #endif
    }

    private func openSearch() {
        playback.cancelWatch()
        guard !isSearching else {
            searchFocusRequest &+= 1
            return
        }
        #if os(tvOS)
        // Exclude both native and custom shell navigation before UIKit presents
        // its keyboard and claims focus.
        onExpandedChange(true)
        #endif
        searchOrigin = PrototypeSearchBookmark(
            row: selectedRowID, guideOffset: guideOffset, timeAnchor: timeAnchor, timelineOffset: timelineOffset
        )
        guideOffset = 0
        timelineOffset = 0
        timeAnchor = Date(timeIntervalSince1970: floor(model.now.timeIntervalSince1970 / 1_800) * 1_800)
        #if os(tvOS)
        selectedRowID = model.guideChannels.first?.id
        selectedChannelID = selectedRowID?.channelID
        focusedProgram = nil
        #endif
        controlsActive = true
        isSearching = true
        searchFocusRequest &+= 1
    }

    private func closeSearch() {
        playback.cancelWatch()
        guard isSearching else { return }
        let selectedCategory = pendingSearchCategory.flatMap {
            model.matchingCategories.contains($0) ? $0 : nil
        }
        pendingSearchCategory = nil
        if let selectedCategory {
            showCategory(selectedCategory)
            return
        }
        model.query = ""
        if let bookmark = searchOrigin {
            guideOffset = bookmark.guideOffset
            timeAnchor = bookmark.timeAnchor
            timelineOffset = bookmark.timelineOffset
            if let origin = bookmark.row, let row = model.guideRow(for: origin.channelID, preferring: origin.section) {
                selectedRowID = row
                selectedChannelID = row.channelID
            }
        }
        searchOrigin = nil
        enterGuide()
        isSearching = false
    }

    private func showCategory(_ category: String?, enteringGuide: Bool = true) {
        playback.cancelWatch()
        model.query = ""
        model.category = category
        categoryDirectoryReturnID = category
        showsCategoryDirectory = false
        isSearching = false
        searchOrigin = nil
        guideOffset = 0
        timelineOffset = 0
        selectedRowID = model.guideChannels.first?.id
        selectedChannelID = selectedRowID?.channelID
        focusedProgram = nil
        topRequest &+= 1
        if enteringGuide { enterGuide() }
    }

    private func showCategories() {
        playback.cancelWatch()
        model.query = ""
        model.category = nil
        isSearching = false
        showsCategoryDirectory = true
        searchFocusRequest = 0
        controlsActive = true
    }

    private func enterGuide() {
        controlsActive = false
        guard isActive else { return }
        #if os(tvOS)
        preview.requestBrowsingFocus()
        #endif
    }

    private func hideChannel(_ channel: LiveTVPrototypeChannel, from row: LiveTVGuideRowID) {
        let replacement = LiveTVGuideFocusTarget.rowAfterHiding(row, in: model.guideChannels)
        guard model.hideChannel(channel) else { return }
        selectedRowID = replacement
        selectedChannelID = replacement?.channelID
        focusedProgram = nil
        if replacement != nil {
            enterGuide()
        } else {
            controlsActive = true
            if !multiview.isEnabled && preview.followsFocus && !preview.isHoldingWatchedChannel { playback.stop() }
            toolbarFocusRequest &+= 1
        }
    }

    private func applyViewSettings() {
        guard let settings = viewSettingsStore?.load() else { return }
        if startsWithCategories != settings.startsWithCategories {
            startsWithCategories = settings.startsWithCategories
            showsCategoryDirectory = settings.startsWithCategories
            if settings.startsWithCategories { model.category = nil }
        }
        model.sort = settings.sortByName ? .name : .channelNumber
        model.favoritesOnly = settings.favoritesOnly
        model.guideOnly = settings.guideOnly
        model.showsRecentChannels = settings.showsRecentChannels
        previewAfterWatching = settings.previewAfterWatching
        preview.setKeepWatchingWhileBrowsing(settings.keepWatchingWhileBrowsing)
        #if os(tvOS)
        needsPreviewChoice = !settings.hasChosenAutoPreview
        preview.setFollowsFocus(settings.allowsAutomaticPreview)
        #endif
    }

    private var showsPreviewIntroduction: Bool {
        #if os(tvOS)
        needsPreviewChoice && isActive && scenePhase == .active && isProfileAuthorized()
            && !sourceApplicationFailed && (sources?.hasLoaded ?? true)
            && !model.channels.isEmpty && sheet == nil && !preview.isExpanded && !multiview.isEnabled
        #else
        false
        #endif
    }

    private func choosePreviews(_ enabled: Bool) {
        guard isActive, scenePhase == .active, isProfileAuthorized(),
              needsPreviewChoice, let viewSettingsStore else { return }
        var settings = viewSettingsStore.load()
        settings.chooseAutoPreview(enabled)
        viewSettingsStore.save(settings)
        needsPreviewChoice = false
    }

    private func persistViewFilters() {
        guard let viewSettingsStore else { return }
        let current = viewSettingsStore.load()
        var settings = current
        settings.sortByName = model.sort == .name
        settings.favoritesOnly = model.favoritesOnly
        settings.guideOnly = model.guideOnly
        if settings != current { viewSettingsStore.save(settings) }
    }

    private func tune(_ id: String, origin: LiveTVGuideRowID? = nil, expandsPlayer: Bool = true) {
        guard activity.acceptsInteraction else {
            let phase = scenePhase == .active ? "active" : scenePhase == .background ? "background" : "inactive"
            HandoffDiagnostics.emit(
                "LIVE_TV event=watchIgnored reason=interactionInactive"
                    + " destination=\(isActive) scene=\(phase) authorized=\(isProfileAuthorized())"
                    + " sourcesReady=\(sources?.hasLoaded ?? true) sourcesFailed=\(sourceApplicationFailed)"
                    + " playbackAllowed=\(allowsPlayback) coordinatorActive=\(playback.isActive)"
                    + " coordinatorInteractive=\(playback.isInteractionActive)"
            )
            return
        }
        showsCategoryDirectory = false
        if let selection = multiviewSelection {
            guard let channel = model.channel(id: id) else {
                multiviewFavoriteIssue = "This channel is no longer available."
                return
            }
            selection.apply(channel, to: multiview)
            finishMultiviewSelection()
            return
        }
        if !preview.isExpanded {
            let channels: [LiveTVPrototypeChannel]
            if isSearching && searchScope == .programs {
                let allowed = model.programmeSearchChannelIDs
                channels = model.unhiddenCatalogChannels.filter { allowed.contains($0.id) }
            } else {
                channels = model.guideChannels.map(\.channel)
            }
            channelSequence = LiveTVChannelSequence(channels: channels)
        }
        let selectedOrigin = !preview.isExpanded && selectedRowID?.channelID == id ? selectedRowID : nil
        playback.watch(id, origin: origin ?? selectedOrigin, expandsPlayer: expandsPlayer)
    }

    private func handleWatchAcceptance() {
        guard isActive, let current = playback.preparation.current else { return }
        if preview.isWatchingInline {
            selectedChannelID = current.channel.id
            if selectedRowID?.channelID != current.channel.id { selectedRowID = preview.watchOrigin }
            return
        }
        guard preview.isExpanded else { return }
        #if os(tvOS)
        onExpandedChange(true)
        #endif
        selectedChannelID = current.channel.id
        selectedRowID = preview.watchOrigin
        focusedProgram = nil
        controlsActive = false
    }

    private func changeChannel(by offset: Int) {
        guard let id = channelSequence.neighbor(
            of: playback.pendingWatchChannelID ?? playback.preparation.current?.channel.id,
            offset: offset, visibleChannels: model.visibleChannels
        ) else { return }
        #if os(iOS)
        tune(id, expandsPlayer: preview.isExpanded)
        #else
        tune(id)
        #endif
    }
}

private struct PrototypeWatchPreparationStatus: View {
    let channelName: String
    let cancel: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack {
            ProgressView()
            Text("Opening \(channelName)")
            Button("Cancel", role: .cancel, action: cancel)
        }
        .padding()
        .background(palette.backgroundBase, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

struct PrototypeImportStatus: View {
    let imports: LiveTVPrototypeImportModel
    let listedChannels: Int

    var body: some View {
        if imports.playlistPhase == .loading || imports.playlistPhase == .idle {
            Label("Loading playlist", systemImage: "arrow.down.circle")
        } else if imports.playlistPhase == .failed {
            Label("Playlist update failed · Open Sources", systemImage: "wifi.exclamationmark")
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                if imports.enabledSourceIDs.isEmpty {
                    Text("Guide sources off · Channels ready")
                } else {
                    switch imports.guidePhase {
                    case .idle:
                        Label("Guide not loaded · Open Sources", systemImage: "calendar")
                    case .loading:
                        Text("Loading guides · \(imports.completedSourceCount) of \(imports.enabledSourceIDs.count) sources")
                        Text("\(listedChannels) channels with listings so far")
                    case .failed:
                        Label("Guide update failed · Channels ready", systemImage: "wifi.exclamationmark")
                    case .loaded:
                        if let end = imports.coverageEnd, end < Date() {
                            Label("Guide listings are out of date", systemImage: "clock.badge.exclamationmark")
                        } else {
                            Text("Guide listings for \(listedChannels) channels")
                        }
                    }
                    if imports.failedSourceCount > 0 {
                        Text("\(imports.failedSourceCount) guide sources unavailable · Open Sources")
                    }
                }
            }
        }
    }
}
