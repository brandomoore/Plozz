import CoreModels
import CoreSecureStore
import CoreUI
import Foundation
import FeatureLiveTVCore
import FeatureSettings
import Observation
import SwiftUI
@testable import FeatureLiveTV

struct SourceOnboardingFixture: View {
    private enum Destination: Hashable { case sources, settings }
    @State private var path: [Destination] = []
    @State private var profiles = ProfilesModel(store: SourceSmokeProfiles())
    @State private var sources = SourceSmokeStore()
    @State private var automatic = AutomaticChannelsFixtureModel()
    @State private var automaticLoadIssue: LibraryChannelError?
    private let usesTypedNavigation = ProcessInfo.processInfo.arguments.contains("--typed-sources")
    private let usesSettings = ProcessInfo.processInfo.arguments.contains("--source-settings")
    private let usesTypedSettings = ProcessInfo.processInfo.arguments.contains("--typed-settings")
    private let usesAutomaticChannels = ProcessInfo.processInfo.arguments.contains("--automatic-channels")

    var body: some View {
        NavigationStack(path: $path) {
            if ProcessInfo.processInfo.arguments.contains("--setup-cards") {
                SetupCardsFixture()
            } else if usesSettings && !usesTypedSettings {
                settings
            } else if usesTypedSettings {
                List {
                    NavigationLink("Live TV", value: Destination.settings)
                        .accessibilityIdentifier("fixture-live-tv-settings")
                }
                .navigationDestination(for: Destination.self) { _ in settings }
            } else if usesTypedNavigation {
                List {
                    NavigationLink("Sources", value: Destination.sources)
                        .accessibilityIdentifier("fixture-sources")
                }
                .navigationTitle("Source navigation fixture")
                .navigationDestination(for: Destination.self) { _ in
                    SourceSmokeSourcesPane(
                        sources: sources, presentation: .page,
                        automatic: usesAutomaticChannels ? automatic : nil)
                }
            } else {
                LiveTVPrototypeView(
                    sourceStore: sources, profileID: profiles.activeProfileID,
                    preferencesNamespace: profiles.activeNamespace,
                    libraryService: usesAutomaticChannels ? automatic.service : nil,
                    libraryHistory: usesAutomaticChannels ? automatic.history : nil,
                    automaticChannels: usesAutomaticChannels ? automatic.presentation : nil,
                    prepareLibraryChannels: {},
                    sourceApprovalContext: { [profiles] in LiveTVSourceApprovalContext(profiles: profiles) }
                ) { _ in
                    Text("Unexpected playback")
                        .accessibilityIdentifier("fixture-unexpected-playback")
                }
            }

        }
        .environment(profiles)
        .environment(\.themePalette, ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
        .environment(\.colorScheme, ProcessInfo.processInfo.arguments.contains("--light") ? .light : .dark)
        .task {
            guard usesAutomaticChannels else { return }
            do { try await automatic.service.load() }
            catch { automaticLoadIssue = (error as? LibraryChannelError) ?? .storageFailed }
        }
        .overlay(alignment: .topTrailing) {
            if usesAutomaticChannels {
                VStack {
                    Text(verbatim: "Enabled \(automatic.enabled) changes \(automatic.changes) retries \(automatic.retries)")
                        .accessibilityIdentifier("fixture-automatic-metrics")
                    if let automaticLoadIssue {
                        Text(automaticLoadIssue.message).accessibilityIdentifier("fixture-automatic-load-error")
                    }
                }
                .font(.caption2)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                Text(verbatim: "Sources \(sources.sourceCount) writes \(sources.writeCount) requests \(SourceSmokeNetworkBlocker.requestCount)")
                    .font(.caption2)
                    .accessibilityIdentifier("fixture-source-metrics")
                    .allowsHitTesting(false)
            }
        }
    }

    private var settings: some View {
        LiveTVSettingsView(
            store: SourceSmokeViewSettings(),
            preferencesStore: SourceSmokePreferences()
        ) {
            AnyView(SourceSmokeSourcesPane(
                sources: sources, presentation: .settingsPane,
                automatic: usesAutomaticChannels ? automatic : nil))
        }
    }
}

private struct SourceSmokeSourcesPane: View {
    let sources: SourceSmokeStore
    let presentation: LiveTVSourcesView.Presentation
    let automatic: AutomaticChannelsFixtureModel?
    @State private var managesChannels = false
    @State private var catalog: SourceSmokeCatalog?

    init(
        sources: SourceSmokeStore, presentation: LiveTVSourcesView.Presentation,
        automatic: AutomaticChannelsFixtureModel?
    ) {
        self.sources = sources
        self.presentation = presentation
        self.automatic = automatic
        _catalog = State(initialValue: ProcessInfo.processInfo.arguments.contains("--catalog-sources")
            ? SourceSmokeCatalog(configuration: try! sources.load()) : nil)
    }

    var body: some View {
        Group {
            #if os(iOS)
            if presentation == .settingsPane {
                SettingsPageScroll { sourceContent }
                    .navigationTitle("Sources")
            } else {
                sourceContent
            }
            #else
            sourceContent
            #endif
        }
        .navigationDestination(isPresented: $managesChannels) {
            if let automatic {
                LibraryChannelManagementView(
                    service: automatic.service, history: automatic.history,
                    prepareLibraries: {}, automaticChannels: automatic.presentation)
            }
        }
    }

    private var sourceContent: some View {
        LiveTVSourcesView(
            store: sources, imports: catalog?.imports, presentation: presentation,
            createChannel: automatic == nil ? nil : { managesChannels = true },
            scanCoordinator: catalog?.scans
        )
    }
}

@MainActor
private final class SourceSmokeCatalog {
    let imports: LiveTVPrototypeImportModel
    let scans = LiveTVChannelScanCoordinator(store: SourceSmokeHealthStore())

    init(configuration: LiveTVSourcesConfiguration) {
        let cache = LiveTVIndexedCache(
            url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite"),
            namespace: "source-smoke", authorizationScope: "fixture", secureStore: InMemorySecureStore())
        imports = LiveTVPrototypeImportModel(configuration: configuration, cache: cache)
        try! scans.bind(profileID: "source-smoke", sources: configuration.playlists.map {
            try LiveTVChannelScanSource(id: $0.id, generation: "fixture", targets: [])
        })
    }
}

private final class SourceSmokeHealthStore: LiveTVChannelHealthStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LiveTVChannelHealthRecord] = []
    func load() throws -> [LiveTVChannelHealthRecord] { lock.withLock { records } }
    func save(_ records: [LiveTVChannelHealthRecord]) throws { lock.withLock { self.records = records } }
}

@MainActor
@Observable
private final class AutomaticChannelsFixtureModel {
    var enabled = ProcessInfo.processInfo.arguments.contains("--automatic-enabled")
    var isWorking = ProcessInfo.processInfo.arguments.contains("--automatic-working")
    var issue: LibraryChannelError? = ProcessInfo.processInfo.arguments.contains("--automatic-failure")
        ? .sourceUnavailable : nil
    var changes = 0
    var retries = 0
    let preparation: LibraryChannelPreparationProgress = {
        let value = LibraryChannelPreparationProgress()
        value.begin(at: Date().addingTimeInterval(-70))
        value.receive(.init(
            stage: .readingLibrary, serverName: "Fixture Jellyfin", libraryName: "TV Shows",
            kind: .episode, scannedItemCount: 1_250, completedItems: 750, totalItems: 2_400),
            at: Date().addingTimeInterval(-20))
        return value
    }()
    let service = LibraryChannelService(
        profileID: "source-smoke", store: SourceSmokeDefinitions(),
        snapshotStore: LibraryChannelSnapshotStore(databaseURL: nil))
    let history = LibraryChannelHistorySettings(
        defaults: UserDefaults(suiteName: "AutomaticChannelsFixture.\(UUID().uuidString)")!)

    var presentation: LiveTVAutomaticChannelsState {
        LiveTVAutomaticChannelsState(
            enabled: enabled, isWorking: isWorking, issue: issue,
            channelCount: 0, skippedItemCount: 0,
            setEnabled: { [self] value in
                enabled = value
                isWorking = false
                issue = nil
                changes += 1
            },
            retry: { [self] in retries += 1 },
            preparation: ProcessInfo.processInfo.arguments.contains("--automatic-progress") ? preparation : nil
        )
    }
}

private final class SourceSmokeDefinitions: LibraryChannelDefinitionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var definitions: [LibraryChannelDefinition] = []
    func load() throws -> [LibraryChannelDefinition] { lock.withLock { definitions } }
    func save(_ value: [LibraryChannelDefinition]) throws { lock.withLock { definitions = value } }
}

private struct SetupCardsFixture: View {
    @State private var selectedAction = "none"
    private let arguments = ProcessInfo.processInfo.arguments

    var body: some View {
        LiveTVSetupWelcome(
            addPlaylist: { selectedAction = "playlist" },
            useServer: { selectedAction = "server" },
            createChannel: { selectedAction = "library" }
        )
        .frame(width: arguments.contains("--setup-compact") ? 720 : nil)
        .environment(\.layoutDirection, arguments.contains("--rtl") ? .rightToLeft : .leftToRight)
        .environment(\.themePalette, arguments.contains("--light") ? .light : .dark)
        .environment(\.colorScheme, arguments.contains("--light") ? .light : .dark)
        .dynamicTypeSize(arguments.contains("--setup-accessibility") ? .accessibility3 : .large)
        .overlay(alignment: .bottomTrailing) {
            Text(verbatim: selectedAction)
                .accessibilityIdentifier("fixture-setup-action")
                .allowsHitTesting(false)
        }
    }
}

struct SourceSmokeProfiles: ProfilePersisting {
    private let profile = Profile(id: "source-smoke", name: "Source smoke")
    func loadProfiles() -> [Profile] { [profile] }
    func saveProfiles(_ profiles: [Profile]) {}
    func activeProfileID() -> String? { profile.id }
    func setActiveProfileID(_ id: String?) {}
    func lastUsedDates() -> [String: Date] { [:] }
    func markProfileUsed(_ profileID: String, at date: Date) {}
    func activeAccountIDs(forProfile profileID: String) -> [String]? { [] }
    func setActiveAccountIDs(_ ids: [String], forProfile profileID: String) {}
    func migrateLegacyIfNeeded(defaultName: String, defaultActiveAccountIDs: [String]) -> [Profile] { [profile] }
}

final class SourceSmokeStore: LiveTVSourcesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration = LiveTVSourcesConfiguration.empty
    private var writes = 0

    init(configuration: LiveTVSourcesConfiguration? = nil) {
        if let configuration {
            self.configuration = configuration
        } else if ProcessInfo.processInfo.arguments.contains("--configured-sources") {
            self.configuration = LiveTVSourcesConfiguration(playlists: [
                LiveTVPlaylistSource(
                    id: "fixture", name: "Fixture IPTV",
                    playlistURL: URL(string: "https://example.invalid/fixture.m3u")!,
                    guideURLs: ProcessInfo.processInfo.arguments.contains("--source-guides")
                        ? [URL(string: "https://example.invalid/guide.xml")!] : []
                )
            ])
        }
    }

    var sourceCount: Int { lock.withLock { configuration.playlists.count + configuration.servers.count } }
    var writeCount: Int { lock.withLock { writes } }
    func load() throws -> LiveTVSourcesConfiguration { lock.withLock { configuration } }
    func save(_ value: LiveTVSourcesConfiguration) throws {
        if ProcessInfo.processInfo.arguments.contains("--source-save-fails") {
            throw LiveTVSourcesStoreError.saveFailed
        }
        try value.validate()
        lock.withLock {
            configuration = value
            writes += 1
        }
    }
}

private struct SourceSmokeViewSettings: LiveTVViewSettingsStoring {
    func load() -> LiveTVViewSettings { .init() }
    func save(_ settings: LiveTVViewSettings) {}
}

struct SourceSmokePreferences: LiveTVPreferencesStoring {
    func load() throws -> LiveTVPreferences { .empty }
    func save(_ preferences: LiveTVPreferences) throws {}
}

final class SourceSmokeNetworkBlocker: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests = 0
    static var requestCount: Int { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme?.lowercased() ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
    }

    override func stopLoading() {}
}
