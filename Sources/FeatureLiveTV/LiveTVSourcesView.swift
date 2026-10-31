import CoreModels
import CoreUI
import FeatureLiveTVCore
import SwiftUI

public struct LiveTVSourcesView: View {
    public enum Presentation { case page, settingsPane }

    @State private var model: LiveTVSourceManagementModel
    @State private var importedRemovalID: UUID?
    @State private var importedRemovalRequest = UUID()
    @State private var catalogReloadRevision = 0
    @State private var retryingSourceIDs: Set<String> = []
    private let presentation: Presentation
    private let imports: LiveTVPrototypeImportModel?
    private let refresh: (@MainActor () -> Void)?
    private var refreshSource: (@MainActor (String) async throws -> Void)?
    private let serverChoices: [LiveTVServerChoice]
    private let serverProviderResolver: LiveTVServerProviderResolver?
    private let connectServer: (() -> Void)?
    private var connectIPTV: ((LiveTVPlaylistSource?, IPTVCredential.Mode) -> Void)?
    private let sourceFilterID: String?
    private let browseSource: ((String?) -> Void)?
    private let didConfigurePlaylist: () -> Void
    private let createChannel: (() -> Void)?
    private let scanChannels: (() -> Void)?
    private let scanCoordinator: LiveTVChannelScanCoordinator?
    private let didImportPlaylist: (String) -> Void
    private var catalog: LiveTVSourcesCatalog?
    private let refreshAfterMutation: Bool
    private let settingsPreferences: AnyView?
    private let automaticChannels: LiveTVAutomaticChannelsState?
    private let customChannelCount: Int

    /// Inject a retained importer and refresh callback to expose the same catalog
    /// tools in Settings and the Live TV toolbar without constructing another transport.
    public init(
        store: any LiveTVSourcesStoring,
        imports: LiveTVPrototypeImportModel? = nil,
        refresh: (@MainActor () -> Void)? = nil,
        presentation: Presentation = .page,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in },
        settingsPreferences: AnyView? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil,
        customChannelCount: Int = 0
    ) {
        _model = State(initialValue: LiveTVSourceManagementModel(store: store, canMutate: { false }))
        self.presentation = presentation
        self.imports = imports
        self.refresh = refresh
        self.serverChoices = serverChoices
        self.serverProviderResolver = serverProviderResolver
        self.connectServer = connectServer
        sourceFilterID = nil
        browseSource = nil
        self.didConfigurePlaylist = didConfigurePlaylist
        self.createChannel = createChannel
        self.scanChannels = scanChannels
        self.scanCoordinator = scanCoordinator
        self.didImportPlaylist = didImportPlaylist
        catalog = nil
        refreshAfterMutation = refresh != nil
        self.settingsPreferences = settingsPreferences
        self.automaticChannels = automaticChannels
        self.customChannelCount = customChannelCount
    }

    public init(
        store: any LiveTVSourcesStoring,
        catalog: LiveTVSourcesCatalog,
        presentation: Presentation = .page,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in },
        settingsPreferences: AnyView? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil,
        customChannelCount: Int = 0
    ) {
        self.init(
            store: store, imports: catalog.imports, refresh: catalog.requestRefresh,
            presentation: presentation, serverChoices: serverChoices,
            serverProviderResolver: serverProviderResolver, connectServer: connectServer,
            didConfigurePlaylist: didConfigurePlaylist, createChannel: createChannel,
            scanChannels: scanChannels, scanCoordinator: scanCoordinator,
            didImportPlaylist: didImportPlaylist,
            settingsPreferences: settingsPreferences, automaticChannels: automaticChannels,
            customChannelCount: customChannelCount
        )
        self.catalog = catalog
        refreshSource = { await catalog.refresh(sourceID: $0) }
    }

    init(
        model: LiveTVSourceManagementModel,
        imports: LiveTVPrototypeImportModel,
        refresh: @escaping @MainActor () -> Void,
        refreshSource: (@MainActor (String) async throws -> Void)? = nil,
        serverChoices: [LiveTVServerChoice] = [],
        serverProviderResolver: LiveTVServerProviderResolver? = nil,
        connectServer: (() -> Void)? = nil,
        connectIPTV: ((LiveTVPlaylistSource?, IPTVCredential.Mode) -> Void)? = nil,
        sourceFilterID: String? = nil,
        browseSource: ((String?) -> Void)? = nil,
        didConfigurePlaylist: @escaping () -> Void = {},
        createChannel: (() -> Void)? = nil,
        scanChannels: (() -> Void)? = nil,
        scanCoordinator: LiveTVChannelScanCoordinator? = nil,
        didImportPlaylist: @escaping (String) -> Void = { _ in },
        settingsPreferences: AnyView? = nil,
        automaticChannels: LiveTVAutomaticChannelsState? = nil,
        customChannelCount: Int = 0
    ) {
        _model = State(initialValue: model)
        presentation = .page
        self.imports = imports
        self.refresh = refresh
        self.refreshSource = refreshSource
        self.serverChoices = serverChoices
        self.serverProviderResolver = serverProviderResolver
        self.connectServer = connectServer
        self.connectIPTV = connectIPTV
        self.sourceFilterID = sourceFilterID
        self.browseSource = browseSource
        self.didConfigurePlaylist = didConfigurePlaylist
        self.createChannel = createChannel
        self.scanChannels = scanChannels
        self.scanCoordinator = scanCoordinator
        self.didImportPlaylist = didImportPlaylist
        catalog = nil
        refreshAfterMutation = false
        self.settingsPreferences = settingsPreferences
        self.automaticChannels = automaticChannels
        self.customChannelCount = customChannelCount
    }

    public var body: some View {
        LiveTVSourceAccessGate(model: model, unrestrictedContent: settingsPreferences) { canManage in
            let content = LiveTVSourcesContent(
                model: model, imports: catalog?.isPresentationCurrent == false ? nil : imports, refresh: refresh,
                retrySource: sourceRetry, retryingSourceIDs: retryingSourceIDs,
                serverChoices: serverChoices, serverProviderResolver: serverProviderResolver,
                connectServer: connectServer, sourceFilterID: sourceFilterID,
                browseSource: browseSource, didConfigurePlaylist: didConfigurePlaylist,
                commitRemoval: remove,
                createChannel: createChannel,
                scanChannels: scanChannels, scanCoordinator: scanCoordinator,
                didImportPlaylist: didImportPlaylist, connectIPTV: connectIPTV,
                settingsPreferences: settingsPreferences, automaticChannels: automaticChannels,
                customChannelCount: customChannelCount, canManage: canManage
            )
            if presentation == .settingsPane {
                VStack(alignment: .leading, spacing: 24) {
                    catalogStatus
                    content
                }
            } else {
                LiveTVSettingsPage(title: "Sources") {
                    catalogStatus
                    content
                }
            }
        }
        #if os(tvOS)
        .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
        #elseif os(iOS)
        .toggleStyle(SettingsSwitchToggleStyle())
        // The embedded pane is one List row; its child groups cannot clear
        // that row's system background or its extra insets.
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        #endif
        .task(id: catalogReloadRevision) {
            model.reload()
            if model.hasLoaded {
                if catalogReloadRevision == 0 { await catalog?.restore() }
                else { await catalog?.refresh() }
            }
        }
        .onChange(of: model.mutationRevision) { _, _ in
            if refreshAfterMutation { refresh?() }
        }
        .onChange(of: model.configuration, initial: true) { _, _ in recordSourceScreen() }
        .onChange(of: [model.hasLoaded, model.loadIssue != nil]) { _, _ in recordSourceScreen() }
        .onChange(of: catalog?.imports.configuration) { _, _ in
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVSourceApprovalsDidChange)) { notification in
            guard let catalog, notification.object as? String == catalog.profileID else { return }
            catalog.invalidate()
            catalogReloadRevision &+= 1
        }
        .task(id: importedRemovalRequest) {
            guard let importedRemovalID, let imports else { return }
            do {
                try await imports.removeImportedPlaylistFile(id: importedRemovalID)
                guard self.importedRemovalID == importedRemovalID, !Task.isCancelled else { return }
                self.importedRemovalID = nil
            } catch {
                guard self.importedRemovalID == importedRemovalID, !Task.isCancelled else { return }
                model.mutationIssue = .importedFileRemoval
            }
        }
        .alert("Source changes couldn't be saved", isPresented: Binding(
            get: { model.mutationIssue != nil },
            set: { if !$0 { model.mutationIssue = nil } }
        )) {
            if model.mutationIssue == .importedFileRemoval {
                Button("Retry") {
                    model.mutationIssue = nil
                    importedRemovalRequest = UUID()
                }
            }
            Button("OK", role: .cancel) { model.mutationIssue = nil }
        } message: {
            if let issue = model.mutationIssue { Text(issue.message) }
        }
    }

    private func recordSourceScreen() {
        var identities: [LiveTVSourceDiagnostics.Identity: String] = [:]
        identities[.profile] = catalog?.profileID
        LiveTVSourceDiagnostics.shared.record(
            .sourcesScreen, identities: identities,
            counts: [
                .playlists: model.configuration.playlists.count, .servers: model.configuration.servers.count,
                .choices: serverChoices.count
            ],
            flags: [
                .present: model.hasLoaded, .failed: model.loadIssue != nil,
                .hasSnapshot: catalog != nil, .current: catalog?.isPresentationCurrent ?? true
            ]
        )
    }

    private var sourceRetry: (@MainActor (String) async throws -> Void)? {
        guard let refreshSource else { return nil }
        return { sourceID in
            retryingSourceIDs.insert(sourceID)
            defer { retryingSourceIDs.remove(sourceID) }
            try await refreshSource(sourceID)
        }
    }

    private func remove(_ removal: LiveTVSourceRemoval) -> Bool {
        let revision = model.mutationRevision
        switch removal {
        case .playlist(let source):
            model.removePlaylist(source.id)
            if revision != model.mutationRevision, imports != nil, let id = source.importedPlaylistID {
                importedRemovalID = id
                importedRemovalRequest = UUID()
            }
        case .server(let source):
            model.removeServer(source.id)
        }
        return revision != model.mutationRevision
    }

    @ViewBuilder
    private var catalogStatus: some View {
        let issue = catalog?.issue
        let message = issue != nil && issue != .catalog
            ? issue?.message : imports?.unattributedFailure?.userDescription ?? issue?.message
        if let message, model.loadIssue == nil {
            SettingsSectionGroup {
                VStack(alignment: .leading, spacing: 12) {
                    InlineErrorMessage(Text(message))
                    if let refresh {
                        Button("Retry", action: refresh)
                        .plozzActionButton(role: .secondary)
                        .disabled(imports?.isLoading == true || catalog?.isLoading == true)
                        .accessibilityIdentifier("live-tv-page-error-retry")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            .accessibilityIdentifier("live-tv-page-error")
        } else if catalog?.isLoading == true, retryingSourceIDs.isEmpty {
            ProgressView("Loading channels and guide")
        }
    }
}

private enum LiveTVSourceRemoval {
    case playlist(LiveTVPlaylistSource)
    case server(LiveTVServerSource)
}

private struct LiveTVSourcesContent: View {
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let refresh: (@MainActor () -> Void)?
    let retrySource: (@MainActor (String) async throws -> Void)?
    let retryingSourceIDs: Set<String>
    let serverChoices: [LiveTVServerChoice]
    let serverProviderResolver: LiveTVServerProviderResolver?
    let connectServer: (() -> Void)?
    let sourceFilterID: String?
    let browseSource: ((String?) -> Void)?
    let didConfigurePlaylist: () -> Void
    let commitRemoval: (LiveTVSourceRemoval) -> Bool
    let createChannel: (() -> Void)?
    let scanChannels: (() -> Void)?
    let scanCoordinator: LiveTVChannelScanCoordinator?
    let didImportPlaylist: (String) -> Void
    var connectIPTV: ((LiveTVPlaylistSource?, IPTVCredential.Mode) -> Void)? = nil
    let settingsPreferences: AnyView?
    let automaticChannels: LiveTVAutomaticChannelsState?
    let customChannelCount: Int
    let canManage: @MainActor () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let issue = model.loadIssue {
                SettingsSectionGroup {
                    InlineErrorMessage(Text(issue.message))
                    Button {
                        model.reload()
                    } label: {
                        LiveTVSetupActionLabel(title: "Retry", symbol: "arrow.clockwise")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
            } else if !model.hasLoaded {
                ProgressView("Loading sources")
            } else {
                if settingsPreferences != nil {
                    LiveTVSettingsSourceList(sources: configuredSources) { source in
                        sourceRow(source)
                    } setup: {
                        LiveTVSettingsPage(title: "Add TV source") { setupActions }
                    }
                } else {
                    if !model.configuration.playlists.isEmpty || !model.configuration.servers.isEmpty {
                        SettingsSectionGroup("Your sources") { sourceRows }
                    }
                    setupActions
                }
            }
            if let settingsPreferences {
                if let automaticChannels, let createChannel {
                    LiveTVAutomaticChannelsOverview(
                        state: automaticChannels, customChannelCount: customChannelCount,
                        canManage: canManage, manage: createChannel
                    )
                }
                settingsPreferences
            }
            if model.hasLoaded {
                if browseSource != nil || (settingsPreferences == nil && createChannel != nil)
                    || (refresh != nil && !configuredSources.isEmpty)
                    || (scanChannels != nil && !model.configuration.playlists.isEmpty)
                    || (imports?.retainedProgramCount ?? 0) > 0
                {
                    SettingsSectionGroup(settingsPreferences == nil ? nil : "Tools") {
                        if let refresh, !configuredSources.isEmpty {
                            Button(action: refresh) {
                                LiveTVSetupActionLabel(title: "Refresh sources", symbol: "arrow.clockwise")
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            .disabled(imports?.isLoading == true)
                            .accessibilityIdentifier("live-tv-refresh-sources")
                            if imports?.isLoading == true, retryingSourceIDs.isEmpty {
                                ProgressView("Refreshing sources")
                            }
                        }
                        if settingsPreferences == nil, let createChannel {
                            Button(action: createChannel) {
                                SettingsRowLabel(
                                    icon: "sparkles.tv", title: "Plozz channels",
                                    trailing: { LiveTVSourceChevron() }
                                )
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            .accessibilityHint("Manage your automatic lineup and optional custom channels.")
                            .accessibilityIdentifier("live-tv-manage-library-channels")
                        }
                        if let scanChannels, !model.configuration.playlists.isEmpty {
                            Button(action: scanChannels) {
                                SettingsRowLabel(
                                    icon: "checkmark.circle", title: "Check channel availability",
                                    trailing: { LiveTVSourceChevron() }
                                )
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            .accessibilityIdentifier("live-tv-check-channel-availability")
                        }
                        if browseSource != nil {
                            SettingsPageLink {
                                LiveTVSourceFilterList(
                                    configuration: model.configuration,
                                    sourceFilterID: sourceFilterID, browseSource: browseSource
                                )
                            } label: {
                                SettingsRowLabel(
                                    icon: "line.3.horizontal.decrease", title: "Browse channels from",
                                    trailing: {
                                        if let name = selectedSourceName {
                                            Text(name).settingsRowSecondary()
                                        } else {
                                            Text("All sources").settingsRowSecondary()
                                        }
                                    })
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                        if let imports, imports.retainedProgramCount > 0 {
                            SettingsPageLink {
                                LiveTVSettingsPage(title: "Guide coverage") {
                                    LiveTVGuideOverview(imports: imports)
                                }
                            } label: {
                                SettingsRowLabel(
                                    icon: "calendar", title: "Guide coverage",
                                    trailing: {
                                        LiveTVSourceChevron()
                                    })
                            }
                            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        }
                    }
                }
            }
        }
    }

    private var sourceRows: some View {
        ForEach(configuredSources) { source in sourceRow(source) }
    }

    private var configuredSources: [LiveTVConfiguredSourceItem] {
        model.configuration.playlists.map(LiveTVConfiguredSourceItem.playlist)
            + model.configuration.servers.map(LiveTVConfiguredSourceItem.server)
    }

    private func sourceRow(_ source: LiveTVConfiguredSourceItem) -> some View {
        LiveTVConfiguredSourceRow(
            source: source, model: model, imports: imports, refresh: refresh,
            retrySource: retrySource, retryingSourceIDs: retryingSourceIDs,
            didConfigurePlaylist: didConfigurePlaylist, commitRemoval: commitRemoval,
            scanCoordinator: scanCoordinator, connectIPTV: connectIPTV,
            showsKind: settingsPreferences != nil, serverChoices: serverChoices
        )
    }

    private enum LiveTVConfiguredSourceItem: Identifiable {
        case playlist(LiveTVPlaylistSource)
        case server(LiveTVServerSource)

        var id: String {
            switch self {
            case .playlist(let source): "playlist:\(source.id)"
            case .server(let source): "server:\(source.id)"
            }
        }
    }

    private struct LiveTVConfiguredSourceRow: View {
        let source: LiveTVConfiguredSourceItem
        let model: LiveTVSourceManagementModel
        let imports: LiveTVPrototypeImportModel?
        let refresh: (@MainActor () -> Void)?
        let retrySource: (@MainActor (String) async throws -> Void)?
        let retryingSourceIDs: Set<String>
        let didConfigurePlaylist: () -> Void
        let commitRemoval: (LiveTVSourceRemoval) -> Bool
        let scanCoordinator: LiveTVChannelScanCoordinator?
        let connectIPTV: ((LiveTVPlaylistSource?, IPTVCredential.Mode) -> Void)?
        let showsKind: Bool
        let serverChoices: [LiveTVServerChoice]

        var body: some View {
            switch source {
            case .playlist(let source):
                VStack(alignment: .leading, spacing: 12) {
                    SettingsPageLink {
                        LiveTVPlaylistSourceDetails(
                            model: model, imports: imports, sourceID: source.id,
                            didConfigurePlaylist: didConfigurePlaylist, refresh: refresh,
                            scanCoordinator: scanCoordinator,
                            removeSource: { commitRemoval(.playlist($0)) }, connectIPTV: connectIPTV,
                            retrySource: retrySource
                        )
                    } label: {
                        LiveTVPlaylistSourceRow(
                            source: source,
                            status: imports?.playlistSources.first { $0.id == source.id },
                            isRetrying: retryingSourceIDs.contains(source.id), showsKind: showsKind
                        )
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-source-details-\(source.id)")
                    if source.isEnabled, let imports {
                        LiveTVSourceErrors(imports: imports, sourceID: source.id, retry: retrySource)
                    }
                }
                .accessibilityElement(children: .contain)
            case .server(let source):
                VStack(alignment: .leading, spacing: 12) {
                    SettingsPageLink {
                        LiveTVServerSourceDetails(
                            model: model, imports: imports, sourceID: source.id,
                            removeSource: { commitRemoval(.server($0)) }, retrySource: retrySource
                        )
                    } label: {
                        let icon = LiveTVSourceProviderIcon(
                            source: serverChoices.first { $0.id == source.accountID }?.kind
                        )
                        let status = imports?.serverSources.first { $0.id == source.id }
                        SettingsRowLabel(
                            title: Text(verbatim: source.name),
                            contentInsets: liveTVSourceRowInsets,
                            icon: { icon.accessibilityHidden(true) },
                            secondary: {
                                HStack(spacing: 6) {
                                    if showsKind {
                                        if let provider = icon.provider {
                                            Text(verbatim: provider.displayName)
                                        } else {
                                            Text("Media server")
                                        }
                                    }
                                    if !retryingSourceIDs.contains(source.id) {
                                        if showsKind, !source.isEnabled || status != nil {
                                            Text(verbatim: "·")
                                        }
                                        LiveTVServerSourceState(
                                            source: source, status: status, showsFallbackKind: !showsKind
                                        )
                                    }
                                }
                                .font(SettingsRowMetrics.descriptionFont)
                                .settingsRowSecondary()
                            },
                            trailing: { LiveTVSourceChevron() }
                        )
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-source-details-\(source.id)")
                    if source.isEnabled, let imports {
                        LiveTVSourceErrors(imports: imports, sourceID: source.id, retry: retrySource)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private var setupActions: some View {
        SettingsSectionGroup("Add a source") {
            if connectIPTV != nil || providerSetupRouter != nil {
                Button {
                    if let connectIPTV { connectIPTV(nil, .playlist) }
                    else { providerSetupRouter?.connectIPTV() }
                } label: {
                    LiveTVSetupActionLabel(title: "IPTV provider", symbol: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-add-playlist")
            } else {
                SettingsPageLink {
                    LiveTVPlaylistEditor { input in
                        let previousIDs = Set(model.configuration.playlists.map(\.id))
                        try model.savePlaylist(input: input)
                        didConfigurePlaylist()
                        if let added = model.configuration.playlists.first(where: { !previousIDs.contains($0.id) }) {
                            didImportPlaylist(added.id)
                        }
                    }
                } label: {
                    LiveTVSetupActionLabel(
                        title: "IPTV playlist", symbol: "list.bullet.rectangle"
                    )
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-add-playlist")
            }
            #if os(iOS)
            if connectIPTV != nil || providerSetupRouter != nil {
                Button {
                    if let connectIPTV { connectIPTV(nil, .file) }
                    else { providerSetupRouter?.connectIPTV(mode: .file) }
                } label: {
                    LiveTVSetupActionLabel(title: "Playlist file (M3U)", symbol: "doc.badge.plus")
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityIdentifier("live-tv-import-playlist")
            } else if let imports, imports.supportsDurableCatalog {
                SettingsPageLink {
                    LiveTVImportedPlaylistEditor(
                        sources: model, imports: imports, didConfigurePlaylist: didConfigurePlaylist,
                        didImportPlaylist: didImportPlaylist
                    )
                } label: {
                    LiveTVSetupActionLabel(
                        title: "Playlist file (M3U)", symbol: "doc.badge.plus"
                    )
                }
                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                .accessibilityHint("Choose a saved playlist from Files.")
                .accessibilityIdentifier("live-tv-import-playlist")
            }
            #endif
            SettingsPageLink {
                LiveTVServerSetupView(
                    sources: model, choices: serverChoices,
                    resolver: serverProviderResolver, connectServer: connectServer
                )
            } label: {
                LiveTVSetupActionLabel(
                    title: "Media server", symbol: "server.rack"
                )
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .accessibilityIdentifier("live-tv-add-server")
        }
    }

    private var selectedSourceName: String? {
        model.configuration.playlists.first { $0.id == sourceFilterID }?.name
            ?? model.configuration.servers.first { $0.id == sourceFilterID }?.name
    }
}

private struct LiveTVSourceFilterList: View {
    let configuration: LiveTVSourcesConfiguration
    let sourceFilterID: String?
    let browseSource: ((String?) -> Void)?

    var body: some View {
        if let browseSource {
            LiveTVSettingsPage(title: "Browse sources") {
                SettingsSectionGroup {
                    Button {
                        browseSource(nil)
                    } label: {
                        SettingsRowLabel(icon: nil, title: "All sources", trailing: {
                            if sourceFilterID == nil { SettingsSelectionIndicator() }
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityAddTraits(sourceFilterID == nil ? .isSelected : [])
                    ForEach(configuration.playlists.filter(\.isEnabled)) { source in
                        Button {
                            browseSource(source.id)
                        } label: {
                            SettingsRowLabel(icon: nil, title: Text(source.name), trailing: {
                                if sourceFilterID == source.id { SettingsSelectionIndicator() }
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityAddTraits(sourceFilterID == source.id ? .isSelected : [])
                    }
                    ForEach(configuration.servers.filter(\.isEnabled)) { source in
                        Button {
                            browseSource(source.id)
                        } label: {
                            SettingsRowLabel(icon: nil, title: Text(source.name), trailing: {
                                if sourceFilterID == source.id { SettingsSelectionIndicator() }
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityAddTraits(sourceFilterID == source.id ? .isSelected : [])
                    }
                }
            }
        }
    }
}

private struct LiveTVGuideOverview: View {
    let imports: LiveTVPrototypeImportModel

    var body: some View {
        SettingsSectionGroup("Guide coverage") {
            Text("\(imports.matchedChannelCount) channels matched")
            Text("\(imports.retainedProgramCount) cached program listings")
            if let start = imports.coverageStart, let end = imports.coverageEnd {
                Text(start..<end, format: .interval.day().month().hour().minute())
            }
        }
    }
}

private struct LiveTVPlaylistSourceDetails: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let sourceID: String
    let didConfigurePlaylist: () -> Void
    let refresh: (@MainActor () -> Void)?
    let scanCoordinator: LiveTVChannelScanCoordinator?
    let removeSource: (LiveTVPlaylistSource) -> Bool
    var connectIPTV: ((LiveTVPlaylistSource?, IPTVCredential.Mode) -> Void)? = nil
    var retrySource: (@MainActor (String) async throws -> Void)? = nil
    @State private var confirmsRemoval = false
    @SettingsPageDismiss private var dismiss
    @Environment(\.managedProviderSetupRouter) private var providerSetupRouter

    var body: some View {
        if let source = model.configuration.playlists.first(where: { $0.id == sourceID }) {
            LiveTVSettingsPage(title: "Source details", sourceName: source.name) {
                LiveTVSourceMutationMessage(issue: model.mutationIssue)
                if source.isEnabled, let imports {
                    LiveTVSourceErrors(imports: imports, sourceID: source.id, retry: retrySource, grouped: true)
                }
                if source.importedPlaylistID == nil, connectIPTV != nil || providerSetupRouter != nil {
                    SettingsSectionGroup {
                        Button {
                            do {
                                try model.ensureCanMutate()
                                if let connectIPTV { connectIPTV(source, .playlist) }
                                else { providerSetupRouter?.connectIPTV(playlist: source) }
                            } catch { model.mutationIssue = .accessDenied }
                        } label: {
                            LiveTVSetupActionLabel(title: "Connect as IPTV account", symbol: "person.crop.circle.badge.plus")
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    } footer: {
                        Text("Use account setup for large playlists, authentication, movies, and series. Your existing source and preferences are kept; disable this source after connecting to avoid duplicate channels.")
                    }
                }
                SettingsSectionGroup {
                    Toggle(isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setPlaylistEnabled(source.id, enabled: $0) }
                    )) {
                        Label("Use this source", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .accessibilityIdentifier("live-tv-source-enabled-\(source.id)").settingsSearchAnchor("live-source-enabled")
                    LiveTVSourceApprovalControl(
                        source: source, sourceStore: model.sourceStoreForApproval,
                        onChange: {
                            model.reload()
                            refresh?()
                        }
                    )
                }
                SettingsSectionGroup {
                    SettingsPageLink {
                        if source.importedPlaylistID != nil {
                            LiveTVImportedPlaylistEditor(
                                sources: model, imports: imports, original: source,
                                didConfigurePlaylist: didConfigurePlaylist
                            )
                        } else {
                            LiveTVPlaylistSourceEditor(
                                model: model, source: source, didConfigurePlaylist: didConfigurePlaylist
                            )
                        }
                    } label: {
                        SettingsRowLabel(icon: "list.bullet.rectangle", title: "Playlist and guides", trailing: {
                            LiveTVSourceChevron()
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-edit-source-\(source.id)")
                    if let scanCoordinator, scanCoordinator.sourceIDs.contains(source.id) {
                        SettingsPageLink {
                            LiveTVSettingsPage(title: "Check channels") {
                                LiveTVScanSourceSection(
                                    coordinator: scanCoordinator, sourceID: source.id, sourceName: source.name
                                )
                            }
                        } label: {
                            SettingsRowLabel(icon: "checkmark.circle", title: "Check channel availability", trailing: {
                                LiveTVSourceChevron()
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("live-tv-source-scan-\(source.id)")
                    }
                }
                SettingsSectionGroup {
                    SettingsPageLink {
                        LiveTVPlaylistGuideSettings(model: model, imports: imports, sourceID: source.id)
                    } label: {
                        SettingsRowLabel(icon: "calendar", title: "Guide options", trailing: {
                            LiveTVSourceChevron()
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-source-guides-\(source.id)")
                    if let imports {
                        SettingsPageLink {
                            LiveTVSettingsPage(title: "Source details") {
                                if let status = imports.playlistSources.first(where: { $0.id == sourceID }) {
                                    SettingsSectionGroup("Channels") {
                                        Text("\(status.channelCount) channels")
                                        LiveTVPlaylistImportStatus(status: status)
                                    }
                                }
                                ForEach(imports.guideSources.filter { $0.playlistSourceID == sourceID }) { status in
                                    SettingsSectionGroup(verbatim: status.source.name) {
                                        PrototypeSourceAddress(url: status.source.url).font(.caption)
                                        PrototypeGuideSourceStatus(
                                            status: status, enabled: imports.enabledSourceIDs.contains(status.id)
                                        )
                                    }
                                }
                            }
                        } label: {
                            SettingsRowLabel(icon: "info.circle", title: "Source details", trailing: {
                                LiveTVSourceChevron()
                            })
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("live-tv-source-status-\(source.id)")
                    }
                }
                SettingsSectionGroup {
                    Button(role: .destructive) { confirmsRemoval = true } label: {
                        SettingsRowLabel(icon: "trash", title: "Remove source")
                    }
                    .confirmationDialog("Remove this source?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                        Button("Remove source", role: .destructive) {
                            if removeSource(source) { dismiss() }
                        }
                    } message: {
                        Text("Its channels leave the guide. Channel preferences are kept.")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-remove-source-\(source.id)")
                }
            }
        } else {
            ContentUnavailableView("Source removed", systemImage: "list.bullet.rectangle")
        }
    }
}

private struct LiveTVPlaylistGuideSettings: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let sourceID: String

    var body: some View {
        if let source = model.configuration.playlists.first(where: { $0.id == sourceID }) {
            LiveTVSettingsPage(title: "Guide options") {
                LiveTVSourceMutationMessage(issue: model.mutationIssue)
                if let imports {
                    let canReviewMappings = imports.supportsDurableCatalog
                        && (!source.guideURLs.isEmpty || imports.guideSources.contains(where: { $0.playlistSourceID == sourceID }))
                    let reviews = imports.identityReviews[sourceID] ?? []
                    if imports.guideDiscoveryFailures[source.id] != nil || canReviewMappings || !reviews.isEmpty {
                        SettingsSectionGroup {
                            if let failure = imports.guideDiscoveryFailures[source.id] {
                                InlineErrorMessage(Text(failure.userDescription))
                                    .font(.caption)
                            }
                            if canReviewMappings {
                                SettingsPageLink {
                                    LiveTVGuideMappingView(
                                        imports: imports, sourceID: sourceID, authorize: model.ensureCanMutate
                                    )
                                } label: {
                                    SettingsRowLabel(icon: "link", title: "Correct guide mapping", trailing: {
                                        LiveTVSourceChevron()
                                    })
                                }
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                                .accessibilityIdentifier("live-tv-guide-mapping-\(sourceID)")
                            }
                            if !reviews.isEmpty {
                                SettingsPageLink {
                                    LiveTVIdentityReviewView(
                                        imports: imports, sourceID: sourceID, authorize: model.ensureCanMutate
                                    )
                                } label: {
                                    SettingsRowLabel(
                                        icon: "person.crop.rectangle.badge.questionmark", title: "Review channel identities",
                                        trailing: { Text(reviews.count, format: .number).settingsRowSecondary() }
                                    )
                                }
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                            }
                        }
                    }
                }
                SettingsSectionGroup("Guide refresh") {
                    LiveTVGuideDaysPicker(
                        title: "Keep previous days", symbol: "clock.arrow.circlepath",
                        options: Array(0...7), selection: Binding(
                            get: { source.guideLookbackDays },
                            set: { model.setGuidePolicy(sourceID, lookbackDays: $0) }
                        ), identifier: "live-tv-guide-lookback"
                    )
                    .settingsSearchAnchor("guide-lookback")
                    LiveTVGuideDaysPicker(
                        title: "Look ahead", symbol: "calendar",
                        options: [1, 3, 7, 14, 28], selection: Binding(
                            get: { source.guideLookaheadDays },
                            set: { model.setGuidePolicy(sourceID, lookaheadDays: $0) }
                        ), identifier: "live-tv-guide-lookahead"
                    )
                    .settingsSearchAnchor("guide-lookahead")
                } footer: {
                    Text("Keeps the listings provided within this range. A guide may supply fewer days.")
                }
            }
        }
    }
}

private struct LiveTVGuideDaysPicker: View {
    let title: LocalizedStringResource
    let symbol: String
    let options: [Int]
    @Binding var selection: Int
    let identifier: String

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 24) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
            Spacer(minLength: 16)
            Menu {
                Picker(selection: $selection) {
                    ForEach(options, id: \.self) { value in
                        Text("\(value) days").tag(value)
                    }
                } label: {
                    Text(title)
                }
            } label: {
                Text("\(selection) days")
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(identifier)
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            Label { Text(title) } icon: { Image(systemName: symbol) }
            SettingsOptionPicker(options: options, selection: $selection) { value in "\(value) days" }
        }
        #endif
    }
}

private struct LiveTVPlaylistImportStatus: View {
    let status: LiveTVPlaylistSourceStatus

    var body: some View {
        if status.phase == .loading {
            ProgressView("Loading channels")
        } else if status.phase == .idle {
            Text("Ready to load")
        }
        if let failure = status.failure {
            InlineErrorMessage(Text(failure.userDescription))
            if status.lastRefresh != nil { Text("Keeping previously loaded channels") }
        }
        if status.lastRefresh != nil {
            if status.skippedEntryCount > 0 {
                Text("\(status.skippedEntryCount) unsupported or duplicate entries skipped")
            }
        }
        if let date = status.lastRefresh {
            Text("Last refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                .font(.caption)
        }
    }
}

private struct LiveTVServerSourceDetails: View {
    let model: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let sourceID: String
    let removeSource: (LiveTVServerSource) -> Bool
    var retrySource: (@MainActor (String) async throws -> Void)? = nil
    @State private var confirmsRemoval = false
    @SettingsPageDismiss private var dismiss

    var body: some View {
        if let source = model.configuration.servers.first(where: { $0.id == sourceID }) {
            LiveTVSettingsPage(title: "Source details", sourceName: source.name) {
                LiveTVSourceMutationMessage(issue: model.mutationIssue)
                if source.isEnabled, let imports {
                    LiveTVSourceErrors(imports: imports, sourceID: source.id, retry: retrySource, grouped: true)
                }
                SettingsSectionGroup {
                    Toggle(isOn: Binding(
                        get: { source.isEnabled },
                        set: { model.setServerEnabled(source.id, enabled: $0) }
                    )) {
                        Label("Use this source", systemImage: "server.rack")
                    }
                    .accessibilityIdentifier("live-tv-source-enabled-\(source.id)").settingsSearchAnchor("live-source-enabled")
                    SettingsPageLink {
                        LiveTVServerSourceRename(model: model, source: source)
                    } label: {
                        SettingsRowLabel(icon: "pencil", title: "Rename source", trailing: {
                            LiveTVSourceChevron()
                        })
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                }
                if let status = imports?.serverSources.first(where: { $0.id == sourceID }) {
                    SettingsSectionGroup("Live TV status") {
                        LiveTVServerSourceSummary(source: source, status: status)
                        Text("\(status.channelCount) channels")
                        Text("\(status.programCount) loaded program listings")
                        if let date = status.lastGuideRefresh {
                            Text("Guide refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                                .font(.caption)
                        }
                    }
                }
                SettingsSectionGroup {
                    Button(role: .destructive) { confirmsRemoval = true } label: {
                        SettingsRowLabel(icon: "trash", title: "Remove source")
                    }
                    .confirmationDialog("Remove this source?", isPresented: $confirmsRemoval, titleVisibility: .visible) {
                        Button("Remove source", role: .destructive) {
                            if removeSource(source) { dismiss() }
                        }
                    } message: {
                        Text("The server account stays connected.")
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityIdentifier("live-tv-remove-source-\(source.id)")
                }
            }
        } else {
            ContentUnavailableView("Source removed", systemImage: "server.rack")
        }
    }
}

private struct LiveTVSourceMutationMessage: View {
    let issue: LiveTVSourceManagementModel.Issue?

    var body: some View {
        if let issue {
            InlineErrorMessage(Text(issue.message))
            .font(.callout)
            .accessibilityIdentifier("live-tv-source-mutation-error")
        }
    }
}

private struct LiveTVSourceErrors: View {
    let imports: LiveTVPrototypeImportModel
    let sourceID: String
    let retry: (@MainActor (String) async throws -> Void)?
    var grouped = false
    @State private var retryRequested = false
    @State private var retryFailed = false

    private var playlist: LiveTVPlaylistSourceStatus? {
        imports.playlistSources.first { $0.id == sourceID }
    }
    private var server: LiveTVServerSourceStatus? {
        imports.serverSources.first { $0.id == sourceID }
    }
    private var failedGuides: [LiveTVGuideSourceStatus] {
        imports.guideSources.filter {
            $0.playlistSourceID == sourceID && imports.enabledSourceIDs.contains($0.id) && $0.failure != nil
        }
    }
    private var hasFailures: Bool {
        playlist?.failure != nil || server?.failure != nil || server?.guideFailure != nil
            || !failedGuides.isEmpty || imports.guideDiscoveryFailures[sourceID] != nil
    }

    var body: some View {
        Group {
            if hasFailures || retryRequested || retryFailed {
                if grouped { SettingsSectionGroup { messages } }
                else { messages }
            }
        }
        .task(id: retryRequested) {
            guard retryRequested, let retry else { return }
            retryFailed = false
            defer { retryRequested = false }
            let feedbackDeadline = ContinuousClock.now.advanced(by: .milliseconds(400))
            do {
                try await retry(sourceID)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                retryFailed = true
            }
            // Keep even an immediate refusal visible as an attempted refresh.
            try? await Task.sleep(until: feedbackDeadline, clock: .continuous)
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 12) {
            if retryFailed {
                InlineErrorMessage(Text(LiveTVSourcesCatalog.Issue.catalog.message))
            }
            if let failure = playlist?.failure {
                InlineErrorMessage(Text(failure.userDescription))
            }
            if let failure = server?.failure {
                InlineErrorMessage(Text(failure.userDescription))
            }
            if let failure = server?.guideFailure, failure != server?.failure {
                InlineErrorMessage(Text(failure.userDescription))
            }
            ForEach(failedGuides) { guide in
                if let failure = guide.failure {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: guide.source.name).font(.caption)
                        InlineErrorMessage(Text(failure.userDescription))
                    }
                }
            }
            if let failure = imports.guideDiscoveryFailures[sourceID] {
                InlineErrorMessage(Text(failure.userDescription))
            }
            if retry != nil {
                if retryRequested {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text("Loading channels and guide")
                    }
                    .font(.callout)
                    .settingsRowSecondary()
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("live-tv-source-retry-progress-\(sourceID)")
                } else {
                    Button("Retry") { retryRequested = true }
                        .plozzActionButton(role: .secondary)
                        .disabled(imports.isLoading)
                        .accessibilityIdentifier("live-tv-source-retry-\(sourceID)")
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live-tv-source-errors-\(sourceID)")
    }
}

private struct LiveTVSourceChevron: View {
    var body: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .settingsRowSecondary()
            .accessibilityHidden(true)
    }
}

private struct LiveTVPlaylistSourceState: View {
    let source: LiveTVPlaylistSource
    let status: LiveTVPlaylistSourceStatus?
    var showsFallbackKind = true

    var body: some View {
        if !source.isEnabled {
            Text("Disabled")
        } else if let status {
            switch status.phase {
            case .idle: Text("Ready to load")
            case .loading: ProgressView("Loading channels")
            case .loaded: Text("\(status.channelCount) channels")
            case .failed: Label("Refresh failed", systemImage: "exclamationmark.triangle")
            }
        } else if showsFallbackKind, source.importedPlaylistID != nil {
            Text("Imported file")
        } else if showsFallbackKind {
            Text("IPTV playlist")
        }
    }
}

private struct LiveTVServerSourceState: View {
    let source: LiveTVServerSource
    let status: LiveTVServerSourceStatus?
    var showsFallbackKind = true

    var body: some View {
        if !source.isEnabled {
            Text("Disabled")
        } else if let status {
            if status.failure != nil {
                Label("Refresh failed", systemImage: "exclamationmark.triangle")
            } else if status.phase == .loading {
                ProgressView("Loading channels")
            } else if status.phase == .idle {
                Text("Ready to load")
            } else {
                Text("\(status.channelCount) channels")
            }
        } else if showsFallbackKind {
            Text("Media server")
        }
    }
}

private struct LiveTVServerSourceRename: View {
    let model: LiveTVSourceManagementModel
    @State private var original: LiveTVServerSource
    @State private var name: String
    @State private var failure: LiveTVSourceManagementModel.Issue?
    @SettingsPageDismiss private var dismiss

    init(model: LiveTVSourceManagementModel, source: LiveTVServerSource) {
        self.model = model
        _original = State(initialValue: source)
        _name = State(initialValue: source.name)
    }

    var body: some View {
        LiveTVSettingsPage(title: "Rename source") {
            SettingsSectionGroup {
                TextField("Source name", text: $name)
                if let failure { Text(failure.message) }
                HStack {
                    Button("Save name") {
                        do {
                            try model.renameServer(original, name: name)
                            dismiss()
                        } catch LiveTVSourceManagementModel.MutationError.changedSource {
                            failure = .changedSource
                        } catch LiveTVSourceManagementModel.MutationError.accessDenied {
                            failure = .accessDenied
                        } catch {
                            failure = .save
                        }
                    }
                    .plozzActionButton()
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 512)
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

private struct LiveTVPlaylistSourceEditor: View {
    let model: LiveTVSourceManagementModel
    @State private var source: LiveTVPlaylistSource
    let didConfigurePlaylist: () -> Void

    init(
        model: LiveTVSourceManagementModel,
        source: LiveTVPlaylistSource,
        didConfigurePlaylist: @escaping () -> Void
    ) {
        self.model = model
        _source = State(initialValue: source)
        self.didConfigurePlaylist = didConfigurePlaylist
    }

    var body: some View {
        LiveTVPlaylistEditor(
            name: source.name, playlistURL: source.playlistURL, guideURLs: source.guideURLs,
            isEditing: true
        ) { input in
            try model.savePlaylist(input: input, replacing: source)
            didConfigurePlaylist()
        }
    }
}

private struct LiveTVServerSourceSummary: View {
    let source: LiveTVServerSource
    let status: LiveTVServerSourceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(source.name).font(.headline)
            if !source.isEnabled {
                Text("Disabled").font(.caption)
            } else if let status {
                if status.failure != nil {
                    Label("Refresh failed", systemImage: "exclamationmark.triangle").font(.caption)
                } else if let availability = status.availability {
                    LiveTVServerAvailabilitySummary(availability: availability)
                } else if status.phase == .loading {
                    ProgressView("Loading channels")
                } else {
                    Text("Ready to load").font(.caption)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private var liveTVSourceRowInsets: EdgeInsets {
    #if os(tvOS)
    let horizontal = SettingsRowMetrics.horizontalPadding
    #else
    let horizontal: CGFloat = 0
    #endif
    return .init(top: 8, leading: horizontal, bottom: 8, trailing: horizontal)
}

private struct LiveTVPlaylistSourceRow: View {
    let source: LiveTVPlaylistSource
    let status: LiveTVPlaylistSourceStatus?
    let isRetrying: Bool
    var showsKind = false

    private var sourceKind: LocalizedStringResource {
        source.importedPlaylistID == nil ? "IPTV provider" : "Playlist file (M3U)"
    }

    var body: some View {
        SettingsRowLabel(
            title: Text(verbatim: source.name),
            contentInsets: liveTVSourceRowInsets,
            icon: {
                #if os(tvOS)
                ProviderSiteIcon(url: source.playlistURL, size: 40) {
                    Image(systemName: source.importedPlaylistID == nil ? "antenna.radiowaves.left.and.right" : "doc")
                        .font(.body)
                        .settingsRowIcon()
                }
                #else
                Image(systemName: source.importedPlaylistID == nil ? "list.bullet.rectangle" : "doc")
                    .font(.system(size: 22))
                    .settingsRowIcon()
                    .frame(width: SettingsRowMetrics.iconColumnWidth, height: SettingsRowMetrics.iconColumnWidth)
                #endif
            },
            secondary: {
                HStack(spacing: 6) {
                    if showsKind {
                        Text(sourceKind)
                    }
                    if !isRetrying {
                        if showsKind, !source.isEnabled || status != nil {
                            Text(verbatim: "·")
                        }
                        LiveTVPlaylistSourceState(source: source, status: status, showsFallbackKind: !showsKind)
                    }
                }
                .font(SettingsRowMetrics.descriptionFont)
                .settingsRowSecondary()
            },
            trailing: { LiveTVSourceChevron() }
        )
    }
}
