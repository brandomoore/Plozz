import CoreModels
import AVFoundation
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
        if ProcessInfo.processInfo.arguments.contains("--guide-travel") {
            _selection = State(initialValue: .liveTV)
        } else if ProcessInfo.processInfo.arguments.contains("--initial-last-library") {
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
        // Keep the Live TV tab focused until a real Down press, like a deferred startup entry.
        .environment(\.navigationStartupFocusAllowed, !ProcessInfo.processInfo.arguments.contains("--guide-tab-first"))
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
                content: { destination, active in AnyView(page(destination, isActive: active)) },
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
        return AnyView(Label(title(for: destination), systemImage: "square")
            .background {
                if destination == .liveTV, ProcessInfo.processInfo.arguments.contains("--guide-tab-first") {
                    LiveTVTabMarker()
                }
            })
    }

    /// Position native focus on the tab, then leave all subsequent input to the remote.
    private struct LiveTVTabMarker: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            let marker = UIView()
            marker.isUserInteractionEnabled = false
            Task { @MainActor [weak marker] in
                try? await Task.sleep(for: .seconds(1))
                guard let marker, let window = marker.window,
                      let system = UIFocusSystem.focusSystem(for: window),
                      let owner = NavigationRailFocusHostController.containing(marker),
                      let tab = NavigationRowFocusRequester.target(for: marker, in: window),
                      owner.requestFocus(to: tab, using: system) else {
                    print("GUIDE_ARRIVAL no native tab"); return
                }
                print("GUIDE_ARRIVAL native Live TV tab")
            }
            return marker
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private func page(_ destination: NavigationRailDestination, isActive: Bool = true) -> some View {
        NavigationStack {
            if destination == .liveTV, ProcessInfo.processInfo.arguments.contains("--guide-travel") {
                LiveTVCategorySearchFixture(isActive: isActive)
                    .task {
                        guard !ProcessInfo.processInfo.arguments.contains("--guide-remote-arrival") else { return }
                        await GuideTravelProbe().run(tabCount: NavigationDestinationDefaults.topBar(destinations: destinations).count)
                    }
            } else if destination == .settings {
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
        case .upcoming: "Upcoming"
        case .watchlist: "Watchlist"
        case .discover: "Discover"
        case .liveTV: "Live TV"
        case .search: "Search"
        case .music: "Music"
        case .allLibraries: "All Libraries"
        case .settings: "Settings"
        case .library: "Library"
        }
    }

    /// Simulator fallback when testmanager cannot deliver remote events. The
    /// system still has to land on the programme in the requested collection cell.
    @MainActor
    private final class GuideTravelProbe: NSObject {
        private var stamps = [Double]()

        @objc private func tick(_ link: CADisplayLink) { stamps.append(link.timestamp) }

        private func report(_ message: String) {
            FileHandle.standardOutput.write(Data("GUIDE_TRAVEL \(message)\n".utf8))
        }

        private func cpuSeconds() -> Double {
            var resources = rusage()
            precondition(getrusage(RUSAGE_SELF, &resources) == 0)
            return Double(resources.ru_utime.tv_sec + resources.ru_stime.tv_sec)
                + Double(resources.ru_utime.tv_usec + resources.ru_stime.tv_usec) / 1e6
        }

        private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(views) }

        private func program(in cell: UICollectionViewCell) -> (any UIFocusItem)? {
            var containers: [any UIFocusItemContainer] = [cell.contentView]
            var seen = Set<ObjectIdentifier>()
            var first: (item: any UIFocusItem, x: CGFloat)?
            while let container = containers.popLast() {
                guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
                if let view = container as? UIView { containers.append(contentsOf: view.subviews) }
                for item in container.focusItems(in: container.coordinateSpace.convert(cell.bounds, from: cell)) {
                    if let child = item.focusItemContainer { containers.append(child) }
                    guard !(item is UIScrollView), !(item is UICollectionViewCell),
                          let frame = NativeFocusRegion.frame(of: item, in: cell),
                          cell.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)),
                          frame.minX > 80, frame.height > 35, frame.height < 120,
                          first == nil || frame.minX < first!.x else { continue }
                    first = (item, frame.minX)
                }
            }
            return first?.item
        }

        private func target(_ row: Int, in collection: UICollectionView) -> (any UIFocusItem)? {
            let path = IndexPath(item: row, section: 0)
            if let frame = collection.layoutAttributesForItem(at: path)?.frame,
               !collection.bounds.contains(CGPoint(x: frame.midX, y: frame.midY)) {
                collection.scrollToItem(at: path, at: [], animated: false)
                collection.layoutIfNeeded()
            }
            return collection.cellForItem(at: path).flatMap(program)
        }

        private func video(_ layer: CALayer) -> AVPlayerLayer? {
            if let layer = layer as? AVPlayerLayer, layer.isReadyForDisplay, layer.player?.rate == 1 { return layer }
            for child in layer.sublayers ?? [] {
                if let result = video(child) { return result }
            }
            return nil
        }

        func run(tabCount: Int) async {
            do {
                try await Task.sleep(for: .seconds(3))
                guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                    .flatMap(\.windows).first(where: \.isKeyWindow),
                      let system = UIFocusSystem.focusSystem(for: window) else {
                    report("FAIL window"); return
                }
                let all = views(window)
                guard let collection = all.compactMap({ $0 as? UICollectionView }).first(where: {
                    $0.numberOfSections == 1 && $0.numberOfItems(inSection: 0) >= 240
                }), let owner = NavigationRailFocusHostController.containing(collection) else {
                    report("FAIL guide collections=\(all.compactMap { ($0 as? UICollectionView)?.numberOfSections })"); return
                }
                let tabs = all.compactMap { $0 as? NavigationRowFocusRequester.RequestView }.count
                report("setup destinations=\(tabCount) mountedTabMarkers=\(tabs) rows=\(collection.numberOfItems(inSection: 0))")
                guard tabCount >= 21, tabs >= tabCount else {
                    report("FAIL large native tab bar"); return
                }
                if owner.isNavigationFocused { owner.directionalContentEntry?.scheduleDirectionalEntry() }
                try await Task.sleep(for: .seconds(1))
                guard let initial = target(0, in: collection), owner.requestFocus(to: initial, using: system) else {
                    report("FAIL entry visible=\(collection.indexPathsForVisibleItems) focus=\(String(describing: system.focusedItem))"); return
                }
                var layer: AVPlayerLayer?
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(100))
                    layer = video(window.layer)
                    if layer != nil { break }
                }
                guard let layer, let player = layer.player, let item = player.currentItem,
                      let url = (item.asset as? AVURLAsset)?.url, url.isFileURL,
                      url.lastPathComponent == "live-continuity.mp4" else {
                    report("FAIL local video"); return
                }
                let route = Array(1...12) + Array((0..<12).reversed())
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.add(to: .main, forMode: .common)
                defer { link.invalidate() }
                for rep in 0...5 {
                    try await Task.sleep(for: .milliseconds(400))
                    let mediaStart = player.currentTime().seconds
                    let cpuStart = cpuSeconds()
                    let start = CACurrentMediaTime()
                    stamps.removeAll(keepingCapacity: true)
                    var landed = [Int]()
                    var lookupSeconds = 0.0
                    for row in route {
                        let lookupStart = CACurrentMediaTime()
                        let candidate = target(row, in: collection)
                        lookupSeconds += CACurrentMediaTime() - lookupStart
                        guard let next = candidate, owner.requestFocus(to: next, using: system) else {
                            report("FAIL request rep=\(rep) row=\(row) landed=\(landed)"); return
                        }
                        try await Task.sleep(for: .milliseconds(120))
                        guard system.focusedItem === next, let cell = collection.cellForItem(at: .init(item: row, section: 0)),
                              NativeFocusRegion.contains(next, in: cell) else {
                            report("FAIL identity rep=\(rep) row=\(row)"); return
                        }
                        landed.append(row)
                    }
                    let elapsed = CACurrentMediaTime() - start
                    let cpu = cpuSeconds() - cpuStart
                    let advance = player.currentTime().seconds - mediaStart
                    guard layer.isReadyForDisplay, layer.player === player, player.currentItem === item,
                          advance > elapsed * 0.8, stamps.count > 2 else {
                        report("FAIL playback or samples rep=\(rep) media=\(advance) elapsed=\(elapsed) samples=\(stamps.count)"); return
                    }
                    let gaps = zip(stamps, stamps.dropFirst()).map { Int((($1 - $0) * 1_000_000).rounded()) }
                    report("rep=\(rep) elapsed=\(elapsed) cpu=\(cpu) lookup=\(lookupSeconds) media=\(advance) route=\(landed) gapsUs=\(gaps)")
                }
                report("PASS")
            } catch { report("FAIL \(error)") }
        }
    }
}
