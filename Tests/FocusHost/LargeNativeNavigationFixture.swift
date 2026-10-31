import CoreModels
import CoreUI
import FeatureHome
import FeatureHomeCore
import FeatureProfiles
import SwiftUI
import UIKit
@testable import AppShell

struct LargeNativeNavigationFixture: View {
    @State private var selection = NavigationRailDestination.home
    @SceneStorage("large-navigation.selection") private var storedSelection = "home"
    @State private var showsProfilePicker = false
    @State private var transitions = NativeNavigationTransitionJournal()
    @State private var chrome = NavigationChromeModel()
    @State private var showsDetail = false

    private let libraries: [AggregatedLibrary]
    private let destinations: [NavigationRailDestination]
    private let profile = Profile(id: "navigation-viewer", name: "Alex", colorIndex: 2)
    private var isSidebar: Bool { ProcessInfo.processInfo.arguments.contains("--native-vertical-navigation") }
    private var realLibraries: Bool { ProcessInfo.processInfo.arguments.contains("--real-library-pages") }
    private var tracesTransitions: Bool { ProcessInfo.processInfo.arguments.contains("--trace-tab-transitions") }
    private var selectionBinding: Binding<NavigationRailDestination> {
        if ProcessInfo.processInfo.arguments.contains("--scene-stored-navigation") {
            Binding(
                get: { NavigationRailDestination(storageValue: storedSelection) ?? .home },
                set: { storedSelection = $0.storageValue }
            )
        } else {
            $selection
        }
    }

    init() {
        if ProcessInfo.processInfo.arguments.contains("--initial-last-library") {
            _selection = State(initialValue: .library("plex:20"))
        }
        let longNames = ProcessInfo.processInfo.arguments.contains("--long-library-names")
        libraries = (1...20).map { index in
            AggregatedLibrary(
                accountID: "plex", accountName: "Plex", serverName: "Plex",
                providerKind: .plex,
                library: MediaLibrary(
                    id: "\(index)",
                    title: longNames ? "Library \(index) - Movies and Television Collection" : "Library \(index)",
                    kind: .movie
                )
            )
        }
        destinations = NavigationRailPlan.destinations(
            visibleLibraries: libraries, layout: .init(),
            availableKeys: NavigationDestinationDefaults.sidebar(visibleLibraries: libraries, hasMusic: true)
        )
    }

    var body: some View {
        Group {
            if showsProfilePicker {
                ProfilePickerView(
                    profiles: [profile, Profile(id: "other-viewer", name: "Sam", colorIndex: 4)],
                    activeProfileID: profile.id, onSelect: { _ in showsProfilePicker = false },
                    onCancel: { showsProfilePicker = false },
                    onOpenSettings: { selectionBinding.wrappedValue = .settings; showsProfilePicker = false }
                )
                .onExitCommand { showsProfilePicker = false }
            } else {
                shell
            }
        }
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .environment(\.plozzNavigationStyle, isSidebar ? .sidebar : .tabBar)
        .environment(\.plozzCardFocusStyle,
                     ProcessInfo.processInfo.arguments.contains("--swiftui-library-grid") ? .outlined : .system)
        .environment(\.plozzReduceTransparency,
                     ProcessInfo.processInfo.arguments.contains("--opaque-controls"))
        .overlay(alignment: .bottom) {
            if tracesTransitions {
                NativeNavigationTransitionStatus(journal: transitions)
                    .frame(height: 30)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var shell: some View {
        if isSidebar {
            sidebar
        } else {
            TopBarNavigation(
                destinations: NavigationDestinationDefaults.topBar(destinations: destinations),
                selection: selectionBinding,
                preventsAccidentalExit: true,
                content: { destination, _ in AnyView(page(destination)) },
                label: label,
                profile: profile,
                onOpenProfileSwitcher: { showsProfilePicker = true },
                chrome: chrome
            )
        }
    }

    private var sidebar: some View {
        TabView(selection: selectionBinding) {
            Tab("Alex", systemImage: "person.crop.circle", value: NavigationRailDestination.library("profile")) {
                Color.clear.onAppear { showsProfilePicker = true }
            }
            ForEach(destinations, id: \.storageValue) { destination in
                Tab(value: destination) {
                    AnyView(page(destination).tvNavigationExitProtectionContent())
                } label: {
                    label(destination)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tvNavigationExitProtection(isEnabled: true)
    }

    private func label(_ destination: NavigationRailDestination) -> AnyView {
        if case let .library(key) = destination,
           let library = libraries.first(where: { $0.key == key }) {
            return AnyView(MainTabView.navigationLibraryLabel(
                .init(key: key, library: library), usesCompactSidebarText: isSidebar
            ))
        }
        return AnyView(Label(title(for: destination), systemImage: "square"))
    }

    private func page(_ destination: NavigationRailDestination) -> some View {
        NavigationStack {
            if destination == .settings {
                VStack {
                    Text("Settings").accessibilityIdentifier("large-navigation-settings")
                    Button("Back") { selectionBinding.wrappedValue = .home }
                }
            } else if realLibraries, destination == .allLibraries || libraries.contains(where: { .library($0.key) == destination }) {
                LibraryBrowseView(
                    viewModel: LibraryBrowseViewModel(
                        provider: NavigationFixtureProvider(), containerID: destination.storageValue,
                        containerKind: .movie, defaults: UserDefaults(suiteName: "NavigationFixture.\(UUID())")!,
                        sourceAccountID: "plex",
                        initialContentMode: ProcessInfo.processInfo.arguments.contains("--recommended-library-pages")
                            ? .recommended : .titles
                    ),
                    title: Text(verbatim: title(for: destination)),
                    isNavigationRoot: true,
                    onSelect: { _ in }
                )
            } else {
                Button("Page content") {
                    if ProcessInfo.processInfo.arguments.contains("--navigation-detail-pages") {
                        showsDetail = true
                    }
                }
                    .accessibilityIdentifier("large-navigation-content")
                    .accessibilityValue(Text(verbatim: destination.storageValue))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Color.clear
                .frame(width: 0, height: 0)
                .navigationDestination(isPresented: $showsDetail) {
                    Button("Detail") { showsDetail = false }
                        .accessibilityIdentifier("large-navigation-detail")
                }
        }
        .reportsNavigationDepth(showsDetail ? 1 : 0, to: chrome)
        .overlay(alignment: .bottom) {
            if selectionBinding.wrappedValue == destination {
                Text(verbatim: destination.storageValue)
                    .accessibilityIdentifier("large-navigation-selection")
            }
        }
        .background {
            if tracesTransitions {
                NativeNavigationTransitionProbe(destination: destination.storageValue, journal: transitions)
                    .frame(width: 0, height: 0)
            }
        }
    }

    @MainActor
    private final class NativeNavigationTransitionJournal {
        private var events: [String] = []
        weak var label: UILabel?

        func record(_ event: String) {
            events.append(event)
            if events.count > 256 { events.removeFirst(events.count - 256) }
            label?.text = events.joined(separator: "\n")
        }

        func attach(_ label: UILabel) {
            self.label = label
            label.text = events.joined(separator: "\n")
        }
    }

    private struct NativeNavigationTransitionStatus: UIViewRepresentable {
        let journal: NativeNavigationTransitionJournal

        func makeUIView(context: Context) -> UILabel {
            let label = UILabel()
            label.accessibilityIdentifier = "native-tab-transition-journal"
            label.font = .systemFont(ofSize: 10)
            journal.attach(label)
            return label
        }

        func updateUIView(_ view: UILabel, context: Context) {}
    }

    private struct NativeNavigationTransitionProbe: UIViewControllerRepresentable {
        let destination: String
        let journal: NativeNavigationTransitionJournal

        func makeUIViewController(context: Context) -> Controller {
            Controller(destination: destination, journal: journal)
        }

        func updateUIViewController(_ controller: Controller, context: Context) {}

        final class Controller: UIViewController {
            let destination: String
            let journal: NativeNavigationTransitionJournal

            init(destination: String, journal: NativeNavigationTransitionJournal) {
                self.destination = destination
                self.journal = journal
                super.init(nibName: nil, bundle: nil)
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

            override func viewWillAppear(_ animated: Bool) {
                super.viewWillAppear(animated)
                journal.record("\(destination):willAppear")
            }

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                journal.record("\(destination):didAppear")
            }

            override func viewWillDisappear(_ animated: Bool) {
                super.viewWillDisappear(animated)
                journal.record("\(destination):willDisappear")
            }

            override func viewDidDisappear(_ animated: Bool) {
                super.viewDidDisappear(animated)
                journal.record("\(destination):didDisappear")
            }
        }
    }

    private struct NavigationFixtureProvider: MediaProvider {
        let kind = ProviderKind.plex
        let session = UserSession(
            server: MediaServer(id: "plex", name: "Plex", baseURL: URL(string: "https://fixture.invalid")!,
                                provider: .plex),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )

        func libraries() async throws -> [MediaLibrary] { [] }
        func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
        func continueWatching(limit: Int, inLibraries libraryIDs: [String]?) async throws -> [MediaItem] {
            guard let libraryID = libraryIDs?.first else { return try await continueWatching(limit: limit) }
            return (0..<min(limit, 20)).map {
                MediaItem(id: "continue-\($0)", title: "Continue \($0)", kind: .movie).taggingLibrary(libraryID)
            }
        }
        func latest(limit: Int) async throws -> [MediaItem] { [] }
        func item(id: String) async throws -> MediaItem { throw AppError.notFound }
        func children(of itemID: String) async throws -> [MediaItem] { [] }
        func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
            try await Task.sleep(for: .milliseconds(200))
            return .init(
                items: (0..<20).map { MediaItem(id: "\($0)", title: "Movie \($0)", kind: .movie) },
                startIndex: 0, totalCount: 20
            )
        }
        func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
        func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
        func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
        func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
    }

    private func title(for destination: NavigationRailDestination) -> String {
        switch destination {
        case .home: "Home"
        case .watchlist: "Watchlist"
        case .liveTV: "Live TV"
        case .search: "Search"
        case .music: "Music"
        case .allLibraries: "All Libraries"
        case .settings: "Settings"
        case .library: "Library"
        }
    }
}
