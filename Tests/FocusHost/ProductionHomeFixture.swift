import CoreModels
import CoreUI
import AVFoundation
import notify
@testable import FeatureHome
import FeatureHomeCore
import FeatureSearch
import MetadataKit
import Observation
import SwiftUI
import UIKit
@testable import AppShell

@MainActor
@Observable
fileprivate final class HeldHomeArtworkState {
    static let shared = HeldHomeArtworkState()
    var started = 0
    var completed = 0
}

private actor HeldHomeArtworkLoader: ArtworkNetworkFileLoading {
    func loadArtwork(_ reference: NetworkArtworkReference, maximumBytes: Int) async throws -> Data {
        await MainActor.run { HeldHomeArtworkState.shared.started += 1 }
        try await Task.sleep(for: .seconds(300))
        await MainActor.run { HeldHomeArtworkState.shared.completed += 1 }
        return Data()
    }
}

struct ProductionHomeFixture: View {
    @State private var fixture: ProductionHomeState?
    @State private var path: [MediaItem] = []
    @State private var libraryPath = NavigationPath()
    @State private var selection = NavigationRailDestination.home
    @State private var profile = Profile(name: "Viewer")
    @State private var expectedNativeDestination: NavigationRailDestination?
    @State private var prematureNativeHomeFocusCount = 0
    @State private var nativeSidebarFocus = NavigationDestinationFocusHandoff()
    @State private var nativeFocusHistory: [String] = []

    private var isPinned: Bool { ProcessInfo.processInfo.arguments.contains("--pinned-home") }
    /// `--focus-style=<name>` picks a card focus style; native system focus otherwise.
    private static var focusStyle: CardFocusStyle {
        ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--focus-style=") }
            .flatMap { CardFocusStyle(rawValue: String($0.dropFirst("--focus-style=".count))) } ?? .system
    }
    private var isNativeSidebar: Bool {
        ProcessInfo.processInfo.arguments.contains("--native-sidebar-home")
    }

    var body: some View {
        Group {
            if let fixture {
                Group {
                    if isPinned {
                        NavigationRailShell(
                            profile: profile, entries: [], destinations: [.home, .watchlist, .search, .settings],
                            selection: $selection, onOpenProfileSwitcher: {},
                            chrome: fixture.chrome,
                            content: Group {
                                if selection == .watchlist {
                                    NavigationStack {
                                        WatchlistBrowseView(
                                            viewModel: fixture.model, visibility: fixture.visibility.visibility,
                                            onSelect: { _ in }
                                        )
                                    }
                                } else {
                                    ProductionHomeContent(fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: true)
                                }
                            },
                            contentDestination: selection
                        )
                    } else if isNativeSidebar {
                        TabView(selection: Binding(
                            get: { selection },
                            set: { destination in
                                if destination != selection { nativeSidebarFocus.begin(destination) }
                                selection = destination
                            }
                        )) {
                            Tab("Home", systemImage: "house", value: NavigationRailDestination.home) {
                                AnyView(NativeSidebarFocusDestination(
                                    destination: .home, selection: selection, handoff: nativeSidebarFocus,
                                    content: ProductionHomeContent(
                                    fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: false,
                                    isActive: selection == .home
                                )
                                .background {
                                    // Native tabs can share a hosting ancestor. Keep the
                                    // measured hero region disjoint from Settings' target.
                                    GeometryReader { geometry in
                                        NativeFocusRegionObserver {
                                            if expectedNativeDestination == .settings {
                                                prematureNativeHomeFocusCount += 1
                                            }
                                        }
                                        .frame(height: geometry.size.height / 2)
                                        .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                })
                                .tvNavigationExitProtectionContent())
                            }
                            Tab("Settings", systemImage: "gearshape", value: NavigationRailDestination.settings) {
                                AnyView(NativeSidebarFocusDestination(
                                    destination: .settings, selection: selection, handoff: nativeSidebarFocus,
                                    content: Button("Native settings content") {}
                                    .accessibilityIdentifier("native-production-settings")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                ).tvNavigationExitProtectionContent())
                            }
                        }
                        .tabViewStyle(.sidebarAdaptable)
                        .tvNavigationExitProtection(isEnabled: true)
                        .onPlayPauseCommand {
                            expectedNativeDestination = .settings
                            prematureNativeHomeFocusCount = 0
                        }
                        .overlay(alignment: .bottomTrailing) {
                            VStack {
                                Text(expectedNativeDestination?.storageValue ?? "idle")
                                    .accessibilityIdentifier("native-production-armed")
                                Text("\(prematureNativeHomeFocusCount)")
                                    .accessibilityIdentifier("native-production-premature-focus")
                            }
                            .allowsHitTesting(false)
                        }
                    } else if ProcessInfo.processInfo.arguments.contains("--top-bar-home") {
                        TopBarNavigation(
                            destinations: [.home, .watchlist, .search],
                            selection: $selection, preventsAccidentalExit: true,
                            content: { destination, active in
                                if destination == .home {
                                    AnyView(ProductionHomeContent(
                                        fixture: fixture, path: $path, libraryPath: $libraryPath,
                                        isPinned: false, isActive: active
                                    ))
                                } else if ProcessInfo.processInfo.arguments.contains("--real-root-pages") {
                                    AnyView(NavigationStack {
                                        if destination == .watchlist {
                                            WatchlistBrowseView(
                                                viewModel: fixture.model, visibility: fixture.visibility.visibility,
                                                onSelect: { _ in }
                                            )
                                        } else {
                                            SearchView(viewModel: fixture.search, onSelect: { _ in })
                                        }
                                    })
                                } else {
                                    AnyView(Button("Fixture destination") {})
                                }
                            },
                            label: { destination in
                                switch destination {
                                case .home: AnyView(Label("Home", systemImage: "house"))
                                case .watchlist: AnyView(Label("Watchlist", systemImage: "bookmark"))
                                default: AnyView(Label("Search", systemImage: "magnifyingglass"))
                                }
                            },
                            profile: profile, onOpenProfileSwitcher: {},
                            chrome: fixture.chrome
                        )
                    } else {
                        ProductionHomeContent(fixture: fixture, path: $path, libraryPath: $libraryPath, isPinned: false)
                    }
                }
                .environment(\.openWatchlist, { selection = .watchlist })
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--top-bar-entry-probe") else { return }
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
                    await Self.probeTopBarEntry()
                }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--hero-showcase-navigation-probe"),
                          isPinned || ProcessInfo.processInfo.arguments.contains("--top-bar-home") else { return }
                    do {
                        try await Task.sleep(for: .seconds(3))
                        selection = .settings
                        try await Task.sleep(for: .seconds(2))
                        selection = .home
                        try await Task.sleep(for: .seconds(3))
                        await Self.probeHeroShowcaseFocus()
                    } catch {
                        print("HERO_STAGE_PROBE navigation cancelled: \(error)")
                    }
                }
                .task {
                    guard ProcessInfo.processInfo.arguments.contains("--watchlist-entry-probe"),
                          isPinned || ProcessInfo.processInfo.arguments.contains("--top-bar-home") else { return }
                    do {
                        try await Task.sleep(for: .seconds(3))
                        selection = .watchlist
                        try await Task.sleep(for: .seconds(3))
                        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                            .flatMap(\.windows).first(where: \.isKeyWindow)
                        let focused = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                        var views: [UIView] = window.map { [$0] } ?? []
                        var enteredGrid = false
                        while let view = views.popLast() {
                            if let region = view as? NavigationEntryFocusRegionView,
                               region.preference == .content, let focused, let window,
                               let frame = NavigationRowFocusRequester.frame(of: focused, relativeTo: window) {
                                enteredGrid = enteredGrid || view.convert(view.bounds, to: window).contains(CGPoint(x: frame.midX, y: frame.midY))
                            }
                            views.append(contentsOf: view.subviews)
                        }
                        print("WATCHLIST_ENTRY_PROBE selected=\(selection.storageValue) focusedType=\(focused.map { String(describing: type(of: $0)) } ?? "nil") enteredGrid=\(enteredGrid)")
                        try await Task.sleep(for: .seconds(1))
                        selection = .home
                        try await Task.sleep(for: .seconds(3))
                        let returned = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem }
                        let returnFrame = returned.flatMap { item in
                            window.flatMap { NavigationRowFocusRequester.frame(of: item, relativeTo: $0) }
                        }
                        let returnedVisible = window.map { $0.bounds.intersects(returnFrame ?? .null) } ?? false
                        print("WATCHLIST_ENTRY_PROBE complete enteredGrid=\(enteredGrid) returnedVisible=\(returnedVisible)")
                    } catch {
                        print("WATCHLIST_ENTRY_PROBE failed: \(error)")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    VStack {
                        Text("Production Home ready")
                        if ProcessInfo.processInfo.arguments.contains("--partial-home-failure") {
                            Text(verbatim: fixture.resumePublication.isWaiting ? "waiting" : "ready")
                                .accessibilityIdentifier("home-resume-publication")
                            Text(verbatim: nativeFocusHistory.joined(separator: "|"))
                                .accessibilityIdentifier("home-native-focus-history")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
                            Text(verbatim: "\(HeldHomeArtworkState.shared.started)")
                                .accessibilityIdentifier("home-held-artwork-started")
                            Text(verbatim: "\(HeldHomeArtworkState.shared.completed)")
                                .accessibilityIdentifier("home-held-artwork-completed")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--library-detail-sequence") {
                            Text(verbatim: "\(libraryPath.count)")
                                .accessibilityIdentifier("detail-sequence-route-depth")
                            Text(verbatim: "\(fixture.detailDepth.depth)")
                                .accessibilityIdentifier("detail-sequence-page-depth")
                            Text(verbatim: fixture.trailer.currentItemID ?? "none")
                                .accessibilityIdentifier("detail-sequence-trailer-owner")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
                            Text(verbatim: fixture.model.loadingRows.contains(.continueWatching) ? "pending" : "ready")
                                .accessibilityIdentifier("home-fixture-resume-state")
                            Text(verbatim: fixture.model.loadingRows.contains(.recentlyAdded) ? "pending" : "ready")
                                .accessibilityIdentifier("home-fixture-latest-state")
                        }
                        if ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture") {
                            Text(verbatim: fixture.discoveryLoad.isReady ? "ready" : "pending")
                                .accessibilityIdentifier("home-fixture-discover-state")
                        }
                    }
                    .font(.caption2)
                    .allowsHitTesting(false)
                }
            } else {
                ProgressView("Preparing local Home data")
            }
        }
        .environment(\.plozzCardFocusStyle, Self.focusStyle)
        .environment(\.gradientBackgroundsEnabled, !ProcessInfo.processInfo.arguments.contains("--gradient-off"))
        .environment(\.themePalette, ProcessInfo.processInfo.arguments.contains("--gradient-black") ? .pureBlack : .dark)
        .environment(\.plozzCardStyle, ProcessInfo.processInfo.arguments.contains("--framed-cards") ? .framed : .borderless)
        .onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { notification in
            if ProcessInfo.processInfo.arguments.contains("--return-focus-trace"),
               let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext {
                let previous = (context.previouslyFocusedItem as? NSObject)?.accessibilityLabel ?? "none"
                let next = (context.nextFocusedItem as? NSObject)?.accessibilityLabel ?? "none"
                HandoffDiagnostics.emit("fixture FOCUS previous=\(previous) next=\(next) heading=\(context.focusHeading.rawValue) at=\(CACurrentMediaTime())")
            }
            guard ProcessInfo.processInfo.arguments.contains("--partial-home-failure"),
                  let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext,
                  let item = context.nextFocusedItem as? NSObject,
                  let label = item.accessibilityLabel else { return }
            nativeFocusHistory.append(label)
        }
        .task {
            guard fixture == nil else { return }
            fixture = await ProductionHomeState.load()
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--hero-showcase-focus-probe")
                || ProcessInfo.processInfo.arguments.contains("--hero-showcase-geometry-probe") else { return }
            do {
                try await Task.sleep(for: .seconds(3))
                await Self.probeHeroShowcaseFocus()
            } catch {
                print("HERO_STAGE_PROBE cancelled: \(error)")
            }
        }
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--home-hitch-positive-control") else { return }
            for _ in 0..<200 {
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch is CancellationError { return }
                catch { preconditionFailure("Unexpected fixture control delay failure: \(error)") }
                Self.blockForHitchControl()
            }
        }
    }

    @MainActor
    private static func probeTopBarEntry() async {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow),
              let system = UIFocusSystem.focusSystem(for: window) else {
            print("TOP_BAR_ENTRY complete passed=false missingWindow")
            return
        }
        var controllers = window.rootViewController.map { [$0] } ?? []
        var owner: NavigationRailFocusHostController?
        var stage: HeroShowcaseStage.Controller?
        while let controller = controllers.popLast() {
            if let found = controller as? NavigationRailFocusHostController { owner = found }
            if let found = controller as? HeroShowcaseStage.Controller { stage = found }
            controllers.append(contentsOf: controller.children)
        }
        guard let stage, let owner, let target = system.focusedItem else {
            print("TOP_BAR_ENTRY complete passed=false missingHeroOrNavigation"); return
        }
        var views = [window as UIView]
        var entry: TopBarEntryProbe.Marker?
        var down: TopBarDownPressRecognizer?
        while let view = views.popLast() {
            if let found = view as? TopBarEntryProbe.Marker { entry = found }
            if let found = view.gestureRecognizers?.compactMap({ $0 as? TopBarDownPressRecognizer }).first { down = found }
            views.append(contentsOf: view.subviews)
        }
        guard let entry, let enter = entry.enter, let down else {
            print("TOP_BAR_ENTRY complete passed=false missingAction"); return
        }
        guard let directionalEntry = owner.directionalContentEntry,
              let directionalAction = directionalEntry.onDirectionalEntry else {
            print("TOP_BAR_ENTRY complete passed=false missingDirectionalEntry"); return
        }
        var directionalCalls = 0
        directionalEntry.onDirectionalEntry = { directionalCalls += 1 }
        for heading: UIFocusHeading in [.left, .right, .up, []] {
            guard owner.allowsFocusUpdate(heading: heading) else {
                print("TOP_BAR_ENTRY complete passed=false blockedOtherDirection"); return
            }
        }
        do { try await Task.sleep(for: .milliseconds(50)) }
        catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
        guard directionalCalls == 0 else {
            print("TOP_BAR_ENTRY complete passed=false otherDirectionEntered"); return
        }
        for _ in 0..<3 { _ = owner.allowsFocusUpdate(heading: .down) }
        do { try await Task.sleep(for: .milliseconds(50)) }
        catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
        guard directionalCalls == 1 else {
            print("TOP_BAR_ENTRY complete passed=false duplicateDirectionalEntry"); return
        }
        _ = owner.allowsFocusUpdate(heading: .down)
        directionalEntry.onDirectionalEntry = nil
        do { try await Task.sleep(for: .milliseconds(50)) }
        catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
        guard directionalCalls == 1, owner.directionalContentEntry == nil,
              system.focusedItem === target else {
            print("TOP_BAR_ENTRY complete passed=false staleDirectionalEntry"); return
        }
        directionalEntry.onDirectionalEntry = directionalAction
        print("TOP_BAR_ENTRY directionalPolicy passed=true")
        for cycle in 0..<6 {
            let input = ["directional-focus", "native-press", "entry-action"][cycle % 3]
            guard owner.requestFocus(to: target, using: system) else {
                print("TOP_BAR_ENTRY complete passed=false navigationFocus")
                return
            }
            do { try await Task.sleep(for: .milliseconds(500)) }
            catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
            let started = CACurrentMediaTime()
            if input == "directional-focus" {
                guard !owner.allowsFocusUpdate(heading: .down) else {
                    print("TOP_BAR_ENTRY complete passed=false unownedDirectionalEntry"); return
                }
            } else if input == "native-press" {
                guard down.canEnter() else { print("TOP_BAR_ENTRY complete passed=false rejectedDown"); return }
                let press = HeroBoundaryProbePress(.downArrow)
                down.pressesBegan([press], with: UIPressesEvent())
                down.pressesEnded([press], with: UIPressesEvent())
            } else {
                enter()
            }
            while !stage.contains(system.focusedItem, in: stage.hero),
                  CACurrentMediaTime() - started < 5 {
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { print("TOP_BAR_ENTRY cancelled: \(error)"); return }
            }
            let elapsed = (CACurrentMediaTime() - started) * 1000
            let focused = stage.contains(system.focusedItem, in: stage.hero)
            print("TOP_BAR_ENTRY cycle=\(cycle) input=\(input) elapsedMS=\(elapsed) heroFocus=\(focused)")
            guard focused, elapsed < 200, !down.canEnter() else {
                print("TOP_BAR_ENTRY complete passed=false focusOrLatency"); return
            }
        }
        print("TOP_BAR_ENTRY complete passed=true")
    }

    @MainActor
    private static func blockForHitchControl() {
        Thread.sleep(forTimeInterval: 0.12)
    }

    @MainActor
    private static func probeHeroShowcaseFocus() async {
        let geometryOnly = ProcessInfo.processInfo.arguments.contains("--hero-showcase-geometry-probe")
        print("HERO_STAGE_PROBE mode=\(geometryOnly ? "geometry-only" : "native-focus")")
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var controllers = window?.rootViewController.map { [$0] } ?? []
        var stage: HeroShowcaseStage.Controller?
        while let controller = controllers.popLast() {
            if let candidate = controller as? HeroShowcaseStage.Controller { stage = candidate; break }
            controllers.append(contentsOf: controller.children)
        }
        guard let stage, let system = UIFocusSystem.focusSystem(for: stage.view) else {
            print("HERO_STAGE_PROBE missing stage or focus system")
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--hero-showcase-navigation-probe") {
            var passed = stage.state.isExpanded && stage.contains(system.focusedItem, in: stage.hero)
            print("HERO_STAGE_PROBE navigation-entry heroFocus=\(passed)")
            var rowViews = [stage.rows.view!]
            var navigation: TopNavigationScroll?
            while let view = rowViews.popLast() {
                if let position = view as? FocusHeroNativeScrollPosition.PositionView {
                    navigation = position.navigation
                    break
                }
                rowViews.append(contentsOf: view.subviews)
            }
            let measuresTopBar = ProcessInfo.processInfo.arguments.contains("--top-bar-home")
            var navigationViews: [UIView] = window.map { [$0] } ?? []
            var navigationMarker: NavigationRowFocusRequester.RequestView?
            var returnCue: HeroShowcaseReturnCue.CueView?
            while let view = navigationViews.popLast() {
                if let marker = view as? NavigationRowFocusRequester.RequestView {
                    navigationMarker = marker
                }
                if let cue = view as? HeroShowcaseReturnCue.CueView { returnCue = cue }
                navigationViews.append(contentsOf: view.subviews)
            }
            func presentedNavigationY() -> CGFloat? {
                guard let layer = navigationMarker?.layer.presentation() else { return nil }
                return layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: nil).y
            }
            let visibleNavigationY = presentedNavigationY()
            let moves: [(Bool, TimeInterval)] = [
                (false, 0.7), (true, 0.7), (false, 0.7), (true, 0.7), (false, 0.7), (true, 0.7),
                (false, 0.18), (true, 0.18), (false, 0.18), (true, 0.7)
            ]
            for (expanded, duration) in moves {
                let press = HeroBoundaryProbePress(expanded ? .upArrow : .downArrow)
                guard let recognizer = stage.view.gestureRecognizers?.first(where: {
                    $0.allowedPressTypes.contains(NSNumber(value: press.type.rawValue))
                }), stage.gestureRecognizer(recognizer, shouldReceive: press) else {
                    print("HERO_STAGE_PROBE missing eligible boundary recognizer")
                    return
                }
                recognizer.pressesBegan([press], with: UIPressesEvent())
                let source = system.focusedItem
                let heading: UIFocusHeading = expanded ? .up : .down
                let blocked = !stage.allowsFocusUpdate(from: source, to: nil, heading: heading)
                recognizer.pressesEnded([press], with: UIPressesEvent())
                if measuresTopBar {
                    let started = CACurrentMediaTime()
                    var samples = 0
                    var transitionSamples = 0
                    var maximumError: CGFloat = 0
                    var targetChanges = 0
                    var lastTarget = navigation?.stageTransition
                    repeat {
                        do { try await Task.sleep(for: .milliseconds(16)) }
                        catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                        guard let visibleNavigationY, let currentY = presentedNavigationY(),
                              let rows = stage.rows.view.layer.presentation(),
                              stage.state.motion.distance > 0 else {
                            print("HERO_STAGE_PROBE missing presented navigation or stage"); return
                        }
                        let progress = min(1, max(0, 1 - rows.transform.m42 / stage.state.motion.distance))
                        let expectedY = visibleNavigationY - progress * TopBarNavigationMetrics.foregroundTop
                        maximumError = max(maximumError, abs(currentY - expectedY))
                        if navigation?.stageTransition != lastTarget {
                            targetChanges += 1
                            lastTarget = navigation?.stageTransition
                        }
                        samples += 1
                        if progress > 0.05, progress < 0.95 { transitionSamples += 1 }
                    } while CACurrentMediaTime() - started < duration
                    let synchronized = maximumError < 1 && samples >= 6 && transitionSamples >= 3 && targetChanges <= 1
                    passed = passed && synchronized
                    print("HERO_STAGE_MOTION expanded=\(expanded) maxError=\(maximumError) samples=\(samples) transitionSamples=\(transitionSamples) targetChanges=\(targetChanges) synchronized=\(synchronized)")
                } else {
                    do { try await Task.sleep(for: .seconds(duration)) }
                    catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                }
                let focused = stage.contains(system.focusedItem, in: expanded ? stage.hero : stage.rows)
                passed = passed && blocked && focused && stage.state.isExpanded == expanded
                if ProcessInfo.processInfo.arguments.contains("--top-bar-home") {
                    let offset = navigation?.offset ?? -1
                    let correctVisibility = expanded ? offset == 0 : offset >= TopBarNavigationMetrics.foregroundTop
                    passed = passed && correctVisibility
                    print("HERO_STAGE_NAV expanded=\(expanded) offset=\(offset) correctVisibility=\(correctVisibility)")
                    if !expanded, duration >= 0.7 {
                        guard let returnCue, let window else {
                            print("HERO_STAGE_PROBE missing return cue"); return
                        }
                        let cueY = returnCue.arrow.convert(returnCue.arrow.bounds, to: window).midY
                        let cueHidden = returnCue.arrow.alpha == 0 && !returnCue.isEligible
                        passed = passed && abs(cueY - 48) < 1 && cueHidden
                        print("HERO_STAGE_NAV cueY=\(cueY) hiddenAfterHeroDescent=\(cueHidden)")
                        do { try await Task.sleep(for: .seconds(1)) }
                        catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                    }
                }
                print("HERO_STAGE_BOUNDARY expanded=\(expanded) blocksPendingEscape=\(blocked) correctFocus=\(focused)")
            }
            if measuresTopBar {
                stage.present(expanded: false, focus: true)
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                guard let navigation, navigation.scrollToTop(), let visibleNavigationY else {
                    print("HERO_STAGE_PROBE missing navigation reset"); return
                }
                do { try await Task.sleep(for: .milliseconds(80)) }
                catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                let started = CACurrentMediaTime()
                var maximumError: CGFloat = 0
                repeat {
                    guard let currentY = presentedNavigationY() else {
                        print("HERO_STAGE_PROBE missing presented navigation after reset"); return
                    }
                    maximumError = max(maximumError, abs(currentY - visibleNavigationY))
                    do { try await Task.sleep(for: .milliseconds(16)) }
                    catch { print("HERO_STAGE_PROBE cancelled: \(error)"); return }
                } while CACurrentMediaTime() - started < 0.7
                passed = passed && maximumError < 1 && stage.state.isExpanded
                print("HERO_STAGE_NAV resetMaxError=\(maximumError)")
            }
            print("HERO_STAGE_PROBE complete passed=\(passed)")
            return
        }
        var foreground: UIView?
        var foregroundViews = [stage.hero.view!]
        while let view = foregroundViews.popLast() {
            if view is HeroDirectionalPressMonitor.InstallerView { foreground = view; break }
            foregroundViews.append(contentsOf: view.subviews)
        }
        let foregroundOrigin = foreground.map { $0.convert($0.bounds, to: stage.view) }
        var cue: HeroShowcaseReturnCue.CueView?
        var cueViews: [UIView] = window.map { [$0] } ?? []
        while let view = cueViews.popLast() {
            if let candidate = view as? HeroShowcaseReturnCue.CueView { cue = candidate; break }
            cueViews.append(contentsOf: view.subviews)
        }
        func cueIsStationary() -> Bool {
            guard let cue, let window else { return false }
            let frame = cue.arrow.convert(cue.arrow.bounds, to: window)
            return abs(frame.midX - window.bounds.midX) < 1 && abs(frame.midY - cue.top) < 1
        }
        var showcaseForeground: UIView?
        var showcaseArtwork: UIView?
        var showcaseControllers = stage.showcase.children
        while let controller = showcaseControllers.popLast() {
            if let surface = controller as? HeroShowcaseForegroundSurface.Controller,
               surface.surface == .showcase { showcaseForeground = surface.host.view; break }
            showcaseControllers.append(contentsOf: controller.children)
        }
        func report(_ phase: String, expanded: Bool) -> Bool {
            let focused = system.focusedItem
            var artworkFillsScreen = false
            var showcaseReachesScreenEdge = false
            var foregroundInPlace = false
            if let foreground, let foregroundOrigin {
                let frame = foreground.convert(foreground.bounds, to: stage.view)
                let lift = foregroundOrigin.minY - frame.minY
                let expected: CGFloat = expanded || UIAccessibility.isReduceMotionEnabled ? 0 : stage.state.motion.distance
                foregroundInPlace = abs(lift - expected) < 1
                print("HERO_STAGE_FOREGROUND \(phase) frame=\(frame) lift=\(lift) passed=\(foregroundInPlace)")
            }
            if let window {
                print("HERO_STAGE_GEOMETRY \(phase) window=\(window.bounds) stage=\(stage.view.convert(stage.view.bounds, to: window)) hero=\(stage.hero.view.convert(stage.hero.view.bounds, to: window)) safe=\(stage.hero.view.safeAreaInsets)")
                for host in [stage.hero, stage.showcase] {
                    var views = [host.view!]
                    while let view = views.popLast() {
                        if String(describing: type(of: view)) == "HeroWipeContainerView" {
                            let frame = view.convert(view.bounds, to: window)
                            if host === stage.hero {
                                let expectedY: CGFloat = expanded || UIAccessibility.isReduceMotionEnabled
                                    ? 0 : -stage.state.motion.distance * HeroShowcaseScrollMotion.backdropTravelFraction
                                artworkFillsScreen = abs(frame.maxX - window.bounds.maxX) < 1
                                    && abs(frame.minX - window.bounds.minX) < 1
                                    && abs(frame.minY - window.bounds.minY - expectedY) < 1
                                print("HERO_STAGE_ART \(phase) frame=\(frame) fullWidth=\(artworkFillsScreen)")
                            } else {
                                showcaseArtwork = view
                                let expectedY: CGFloat = expanded || UIAccessibility.isReduceMotionEnabled
                                    ? 0 : -stage.state.motion.distance * HeroShowcaseScrollMotion.backdropTravelFraction
                                let reachesEdge = abs(frame.maxX - window.bounds.maxX) < 1
                                    && abs(frame.minY - window.bounds.minY - expectedY) < 1
                                showcaseReachesScreenEdge = reachesEdge
                                print("HERO_STAGE_SHOWCASE_ART \(phase) frame=\(frame) reachesEdge=\(reachesEdge)")
                            }
                        }
                        views.append(contentsOf: view.subviews)
                    }
                }
            }
            let correct = stage.state.isExpanded == expanded
                && (geometryOnly || stage.contains(focused, in: expanded ? stage.hero : stage.rows))
                && artworkFillsScreen
                && showcaseReachesScreenEdge
                && foregroundInPlace
                && cueIsStationary()
            print("HERO_STAGE_PROBE \(phase) expanded=\(stage.state.isExpanded) heroFocus=\(stage.contains(focused, in: stage.hero)) rowsFocus=\(stage.contains(focused, in: stage.rows)) focusedType=\(focused.map { String(describing: type(of: $0)) } ?? "nil") passed=\(correct)")
            return correct
        }
        var passed = report("initial", expanded: true)
        let delayedCommit = ProcessInfo.processInfo.arguments.contains("--hero-showcase-delayed-commit")
        var firstMove = true
        if geometryOnly {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        for expanded in geometryOnly ? [false, true] : [false, true, false, true, false, true] {
            let delayThisMove = delayedCommit && firstMove
            firstMove = false
            if delayThisMove {
                // Model cold layout/focus work before the run loop submits its transaction.
                CATransaction.begin()
                stage.present(expanded: expanded, focus: !geometryOnly)
                Thread.sleep(forTimeInterval: 0.5)
                CATransaction.commit()
                print("HERO_STAGE_COLD_COMMIT injectedDelay=0.5")
            } else if geometryOnly {
                stage.present(expanded: expanded, focus: false)
            } else {
                stage.beginBoundaryMove(expanded ? .up : .down)
            }
            for sample in 1...6 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                if let foreground, let foregroundOrigin {
                    let foregroundFrame: CGRect
                    if let layer = foreground.layer.presentation(), let parent = stage.view.layer.presentation() {
                        foregroundFrame = layer.convert(layer.bounds, to: parent)
                    } else {
                        foregroundFrame = foreground.convert(foreground.bounds, to: stage.view)
                    }
                    let lift = foregroundOrigin.minY - foregroundFrame.minY
                    let rowLayer = stage.rows.view.layer.presentation() ?? stage.rows.view.layer
                    let rowY = rowLayer.transform.m42
                    let backdropY = (stage.hero.view.layer.presentation() ?? stage.hero.view.layer).transform.m42
                    let showcaseBackdropY = (stage.showcase.view.layer.presentation() ?? stage.showcase.view.layer).transform.m42
                    let opacity = stage.hero.view.layer.presentation()?.opacity ?? stage.hero.view.layer.opacity
                    let showcaseY = showcaseForeground.map {
                        ($0.layer.presentation() ?? $0.layer).transform.m42 + showcaseBackdropY
                    }
                    let error = abs(lift + rowY - stage.state.motion.distance)
                    let expectedBackdropY = -lift * HeroShowcaseScrollMotion.backdropTravelFraction
                    let synchronized = UIAccessibility.isReduceMotionEnabled
                        || (error < 1 && showcaseY.map { abs($0 - rowY) < 1 } == true
                            && abs(backdropY - expectedBackdropY) < 1
                            && abs(showcaseBackdropY - rowY * HeroShowcaseScrollMotion.backdropTravelFraction) < 1)
                    var coversTop = false
                    if let showcaseArtwork, let window {
                        let frame: CGRect
                        if let layer = showcaseArtwork.layer.presentation(), let parent = window.layer.presentation() {
                            frame = layer.convert(layer.bounds, to: parent)
                        } else {
                            frame = showcaseArtwork.convert(showcaseArtwork.bounds, to: window)
                        }
                        coversTop = frame.minY <= window.bounds.minY + 1
                            && abs(frame.maxX - window.bounds.maxX) < 1
                    }
                    passed = synchronized && cueIsStationary() && coversTop && passed
                    if delayThisMove && sample == 1 && !UIAccessibility.isReduceMotionEnabled {
                        let stillAnimating = rowY > 1 && rowY < stage.state.motion.distance - 1
                            && opacity > 0 && opacity < 1
                        passed = stillAnimating && passed
                        print("HERO_STAGE_COLD_COMMIT rowY=\(rowY) opacity=\(opacity) stillAnimating=\(stillAnimating)")
                    }
                    print("HERO_STAGE_MOTION expanded=\(expanded) sample=\(sample) lift=\(lift) rowY=\(rowY) showcaseY=\(String(describing: showcaseY)) backdropY=\(backdropY) showcaseBackdropY=\(showcaseBackdropY) opacity=\(opacity) scrollError=\(error) synchronized=\(synchronized) cueStationary=\(cueIsStationary()) coversTop=\(coversTop)")
                }
            }
            passed = report(expanded ? "up" : "down", expanded: expanded) && passed
            if geometryOnly {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        print("HERO_STAGE_PROBE complete passed=\(passed)")
    }
}

private final class HeroBoundaryProbePress: UIPress {
    private let pressedType: UIPress.PressType
    init(_ type: UIPress.PressType) {
        pressedType = type
        super.init()
    }
    override var type: UIPress.PressType { pressedType }
}

private struct ProductionHomeContent: View {
    let fixture: ProductionHomeState
    @Binding var path: [MediaItem]
    @Binding var libraryPath: NavigationPath
    let isPinned: Bool
    var isActive = true
    @State private var playbackCount = 0
    @State private var lastPlayedID = ""
    private var isLibrarySequence: Bool {
        ProcessInfo.processInfo.arguments.contains("--library-detail-sequence")
    }

    var body: some View {
        Group {
            if isLibrarySequence {
                NavigationStack(path: $libraryPath) {
                    LibraryBrowseView(
                        viewModel: fixture.library, title: Text("Movie sequence library"),
                        onSelect: { item in
                            withCinematicDetailNavigation(for: item) {
                                libraryPath.append(LibraryDetailRoute(item: item, originAccountID: "home-fixture"))
                            }
                        }
                    )
                    .modifier(NavigationRailRootContentInset())
                    .navigationDestination(for: LibraryDetailRoute.self) { route in
                        detailPage(for: route.item)
                    }
                }
                .cinematicDetailNavigation(path: $libraryPath)
            } else {
                NavigationStack(path: $path) {
                    HomeView(
                        viewModel: fixture.model,
                        visibility: fixture.visibility,
                        heroSettings: fixture.heroSettings,
                        heroBackground: fixture.background,
                        heroTrailerController: fixture.trailer,
                        heroIsFrontmost: isActive && path.isEmpty,
                        heroRuntime: fixture.runtime,
                        heroFeaturedProvider: { limit in await fixture.featuredContent(limit: limit) },
                        heroArtworkProvider: { $0.backdropURL },
                        heroArtworkValidator: { _ in true },
                        navigationStyle: isPinned
                            ? .rail
                            : (ProcessInfo.processInfo.arguments.contains("--native-sidebar-home")
                                ? .sidebar : (ProcessInfo.processInfo.arguments.contains("--top-bar-home")
                                    ? .tabBar : .default)),
                        onSelectItem: { item in withCinematicDetailNavigation(for: item) { path.append(item) } },
                        onPlayItem: { item in
                            playbackCount += 1
                            lastPlayedID = item.id
                        },
                        onSelectLibrary: { _ in }
                    )
                    .modifier(NavigationRailRootContentInset())
                    .navigationDestination(for: MediaItem.self) { item in
                        detailPage(for: item)
                    }
                }
                .cinematicDetailNavigation(path: $path)
            }
        }
        .reportsNavigationDepth(
            isLibrarySequence ? libraryPath.count : path.count,
            to: isPinned || ProcessInfo.processInfo.arguments.contains("--top-bar-home") ? fixture.chrome : nil
        )
        .mediaItemActionHandler(
            ProcessInfo.processInfo.arguments.contains("--home-menu-control") ? fixture.actions : nil
        )
        .overlay(alignment: .bottomTrailing) {
            if ProcessInfo.processInfo.arguments.contains("--continue-watching-action-probe") {
                VStack {
                    Text(verbatim: "\(playbackCount):\(lastPlayedID)")
                        .accessibilityIdentifier("home-playback-probe")
                    Text(verbatim: "\(path.count)")
                        .accessibilityIdentifier("home-detail-depth-probe")
                }
                .font(.caption2)
                .allowsHitTesting(false)
            }
        }
    }

    private func detailPage(for item: MediaItem) -> some View {
        ItemDetailView(
            viewModel: fixture.detail(for: item),
            onPlay: { _ in },
            onSelectChild: { next in
                withCinematicDetailNavigation(for: next) {
                    if isLibrarySequence {
                        libraryPath.append(LibraryDetailRoute(item: next, originAccountID: "home-fixture"))
                    } else {
                        path.append(next)
                    }
                }
            },
            stackDepth: isLibrarySequence ? fixture.detailDepth : nil,
            heroTrailerResolver: { [url = fixture.trailerURL] item in
                url.map {
                    HeroTrailerSource(
                        ownerItemID: item.id, trailerItemID: "trailer-\(item.id)",
                        url: $0, duration: 60
                    )
                }
            }
        )
        .environment(fixture.trailer)
        .environment(fixture.background)
        .overlay(alignment: .topTrailing) {
            Text("Detail fixture \(item.title)")
                .font(.caption2)
                .allowsHitTesting(false)
        }
    }
}

@MainActor
private final class ProductionHomeActions: MediaItemActionHandling {
    private(set) var performed: [MediaItemAction] = []

    func actions(for item: MediaItem, context: MediaItemActionContext) -> [MediaItemAction] {
        [.markWatched, .addToWatchlist, .removeFromContinueWatching]
    }

    func perform(_ action: MediaItemAction, on item: MediaItem, context: MediaItemActionContext) {
        performed.append(action)
    }
}

@MainActor
@Observable
private final class ProductionDiscoveryLoadState {
    var isReady = false
}

@MainActor @Observable
private final class ProductionResumePublicationState {
    var isWaiting = false
}

private actor ProductionHomeReadCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

@MainActor
private final class ProductionHomeState {
    let model: HomeViewModel
    let search: SearchViewModel
    let library: LibraryBrowseViewModel
    let detailDepth = DetailStackDepth()
    let trailerURL: URL?
    let visibility = HomeLibraryVisibilityModel()
    let heroSettings = HeroSettingsModel()
    let background = HeroBackgroundSettingsModel()
    let trailer = HeroTrailerController()
    let runtime = HomeHeroRuntimeState()
    let chrome = NavigationChromeModel()
    let actions = ProductionHomeActions()
    let discoveryLoad = ProductionDiscoveryLoadState()
    let resumePublication = ProductionResumePublicationState()
    private let provider: ProductionHomeProvider
    private var details: [String: ItemDetailViewModel] = [:]

    private init(poster: URL, backdrop: URL, logo: URL, trailerURL: URL?) {
        self.trailerURL = trailerURL
        let provider = ProductionHomeProvider(poster: poster, backdrop: backdrop, logo: logo)
        self.provider = provider
        library = LibraryBrowseViewModel(
            provider: provider, containerID: "detail-sequence-library", containerKind: .movie,
            sourceAccountID: "home-fixture"
        )
        let account = Account(
            id: "home-fixture", server: provider.session.server,
            userID: "fixture", userName: "Fixture", deviceID: "fixture"
        )
        let visibility = self.visibility
        visibility.setContinueWatchingShowsSeriesArtwork(
            !ProcessInfo.processInfo.arguments.contains("--episode-home-artwork")
        )
        if ProcessInfo.processInfo.arguments.contains("--continue-watching-action-probe") {
            visibility.setContinueWatchingAction(
                ProcessInfo.processInfo.arguments.contains("--continue-watching-open-details") ? .openDetails : .play
            )
            visibility.setContinueWatchingLayout(
                ProcessInfo.processInfo.arguments.contains("--continue-watching-posters") ? .portrait : .landscape
            )
        }
        let libraryRows = ProcessInfo.processInfo.arguments.contains("--progressive-library-rows")
        if libraryRows { visibility.useRowDefaults(.legacy) }
        visibility.setMergeLibrariesOnHome(!libraryRows)
        for row in HomeGlobalRow.allCases {
            visibility.setGlobalRowEnabled(!libraryRows || row == .continueWatching, for: row)
        }
        if libraryRows {
            for index in 0..<20 {
                visibility.setLibraryRowEnabled(
                    true, libraryKey: "home-fixture:fixture-library-\(index)", kind: .recentlyAdded
                )
            }
        }
        let partialFailure = ProcessInfo.processInfo.arguments.contains("--partial-home-failure")
        var accounts = [ResolvedAccount(account: account, provider: provider)]
        if partialFailure {
            accounts = (0..<5).map { index in
                var source = provider
                source.isOffline = index == 4
                let account = Account(
                    id: "home-fixture-\(index)", server: source.session.server,
                    userID: "fixture", userName: "Fixture", deviceID: "fixture"
                )
                return ResolvedAccount(account: account, provider: source)
            }
        }
        let reads = ProductionHomeReadCounter()
        search = SearchViewModel(accounts: accounts)
        let resumePublication = self.resumePublication
        model = HomeViewModel(
            accounts: accounts,
            layoutStore: InMemoryHomeLayoutStore(),
            contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility },
            recentlyAppliedRecency: {
                // Four successful detail feeds reconcile before the merged row.
                if partialFailure, await reads.next() > 4 {
                    await MainActor.run { resumePublication.isWaiting = true }
                    await provider.waitForResumePublication()
                    await MainActor.run { resumePublication.isWaiting = false }
                }
                return [:]
            }
        )
        var settings = heroSettings.settings
        settings.isEnabled = !ProcessInfo.processInfo.arguments.contains("--hero-disabled-home")
        settings.sources = [.continueWatching, .recentlyAdded]
        settings.autoAdvance = false
        settings.trailersEnabled = false
        // Settings persist between launches, so every launch picks its layout.
        settings.style = ProcessInfo.processInfo.arguments.contains("--hero-showcase-home")
            ? .heroShowcase
            : ProcessInfo.processInfo.arguments.contains("--immersive-home") ? .followsFocus : .carousel
        settings.showsDiscoverRow = ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture")
        heroSettings.settings = settings
        background.settings.homeTrailerEnabled = false
        if trailerURL != nil { background.settings.detailMode = .trailer }
    }

    func detail(for item: MediaItem) -> ItemDetailViewModel {
        if let existing = details[item.id] { return existing }
        let model = ItemDetailViewModel(provider: provider, itemID: item.id, initialItem: item)
        details[item.id] = model
        return model
    }

    func featuredContent(limit: Int) async -> [MediaItem] {
        guard ProcessInfo.processInfo.arguments.contains("--showcase-discover-fixture") else { return [] }
        let items = await provider.featuredContent(limit: limit)
        discoveryLoad.isReady = true
        return items
    }

    static func load() async -> ProductionHomeState {
        let settingsStore = MetadataProviderSettingsStore()
        var settings = settingsStore.load()
        settings.preferOnlineArtwork = false
        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
            settings = .init(
                orderMode: .custom,
                disabledOrder: MetadataSourceAttribution.all.map(\.source.rawValue)
            )
            ArtworkImageCache.shared.configure(networkFileService: ArtworkNetworkFileService(loader: HeldHomeArtworkLoader()))
        }
        settingsStore.save(settings)
        let poster = await artwork(name: "poster", size: CGSize(width: 240, height: 360), color: .systemIndigo)
        let backdrop = await artwork(name: "backdrop", size: CGSize(width: 960, height: 540), color: .systemBlue)
        let scheduleFixture = ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture")
        let logo = await artwork(
            name: "logo", size: scheduleFixture ? CGSize(width: 180, height: 320) : CGSize(width: 320, height: 100),
            color: .white
        )
        let trailerURL: URL?
        if ProcessInfo.processInfo.arguments.contains("--library-detail-sequence") {
            do {
                trailerURL = try await makeTrailerVideo()
            } catch {
                preconditionFailure("The detail sequence requires a playable local trailer: \(error)")
            }
        } else {
            trailerURL = nil
        }
        let state = ProductionHomeState(poster: poster, backdrop: backdrop, logo: logo, trailerURL: trailerURL)
        if ProcessInfo.processInfo.arguments.contains("--cached-home-hero") {
            state.model.cacheHeroItems([state.provider.heroSeed], for: state.heroSettings.settings)
            await state.model.waitForHeroPersistence()
        }
        if ProcessInfo.processInfo.arguments.contains("--cached-showcase-discover") {
            var discovery = state.heroSettings.settings
            discovery.isEnabled = true
            discovery.sources = [.featured]
            state.model.cacheHeroItems([state.provider.heroSeed], for: discovery)
            await state.model.waitForHeroPersistence()
        }
        if ProcessInfo.processInfo.arguments.contains("--slow-home-load")
            || ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
            // Show Home at once and let its rows arrive late, over the skeleton.
            Task { await state.model.load() }
        } else {
            await state.model.load()
        }
        return state
    }

    private static func makeTrailerVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("detail-sequence-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.unknown("") }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer else { throw AppError.invalidResponse }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let address = CVPixelBufferGetBaseAddress(buffer) {
            memset(address, 0x80, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = ContinuousClock.now + .seconds(10)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1))
            else { throw writer.error ?? AppError.invalidResponse }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? AppError.invalidResponse }
        return url
    }

    private static func artwork(name: String, size: CGSize, color: UIColor) async -> URL {
        let url = URL(string: "https://production-home.example.test/\(name).png")!
        let complex = ProcessInfo.processInfo.arguments.contains("--complex-home-artwork")
        let image = UIGraphicsImageRenderer(size: size).image { context in
            if name == "logo", ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") {
                UIColor.systemGreen.setFill()
                context.fill(CGRect(x: 20, y: 10, width: 40, height: 300))
                context.fill(CGRect(x: 50, y: 10, width: 110, height: 40))
                context.fill(CGRect(x: 50, y: 140, width: 70, height: 40))
            } else if complex, name == "logo" {
                for index in 0..<8 {
                    UIColor(hue: CGFloat(index) / 8, saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
                    UIBezierPath(roundedRect: CGRect(
                        x: CGFloat(index) * size.width / 8 + 2, y: 15,
                        width: size.width / 8 - 4, height: 70 - CGFloat(index % 3) * 9
                    ), cornerRadius: 5).fill()
                }
            } else if complex {
                NativeComparisonPattern.makeImage().draw(in: CGRect(origin: .zero, size: size))
            } else {
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }
        guard let bytes = image.pngData(), let cache = ArtworkSession.shared.configuration.urlCache else {
            preconditionFailure("The isolated Home fixture requires its local artwork cache.")
        }
        let references = ProcessInfo.processInfo.arguments.contains("--distinct-home-artwork")
            ? [url] + (0..<150).map { ProductionHomeProvider.artworkURL(url, index: $0) }
            : [url]
        for reference in references {
            let referenceBytes: Data
            if ProcessInfo.processInfo.arguments.contains("--gradient-performance"),
               let value = URLComponents(url: reference, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "fixture-item" })?.value,
               let index = Int(value) {
                let tinted = UIGraphicsImageRenderer(size: size).image { context in
                    image.draw(in: CGRect(origin: .zero, size: size))
                    context.cgContext.setBlendMode(.color)
                    UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.8, brightness: 0.7, alpha: 1).setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
                referenceBytes = tinted.pngData() ?? bytes
            } else {
                referenceBytes = bytes
            }
            for variant in ArtworkImageVariant.allCases {
                let requestURL = variant.requestURL(for: reference)
                let response = HTTPURLResponse(
                    url: requestURL, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
                )!
                cache.storeCachedResponse(
                    CachedURLResponse(response: response, data: referenceBytes), for: URLRequest(url: requestURL)
                )
            }
        }
        for variant in ArtworkImageVariant.allCases {
            guard await ArtworkImageCache.shared.image(for: url, variant: variant) != nil else {
                preconditionFailure("The isolated Home fixture artwork failed to decode.")
            }
        }
        return url
    }
}

private struct ProductionHomeProvider: MediaProvider, WatchlistProviding {
    let poster: URL
    let backdrop: URL
    let logo: URL
    var isOffline = false
    private let heldArtworkRevision = CredentialRevision()
    private let progressiveGate = ProductionHomeRowsGate()
    private let recentGate = ProductionHomeRowsGate(notificationKey: "PLOZZ_HOME_RECENT_RELEASE_NOTIFICATION")
    private let discoverGate = ProductionHomeRowsGate(notificationKey: "PLOZZ_HOME_DISCOVER_RELEASE_NOTIFICATION")
    private let resumePublicationGate = ProductionHomeRowsGate(notificationKey: "PLOZZ_HOME_RESUME_PUBLICATION_NOTIFICATION")
    private var rowCount: Int {
        ProcessInfo.processInfo.arguments.contains("--home-performance-fixture") ? 75 : 24
    }
    var heroSeed: MediaItem { movie(rowCount + 10) }

    func watchlist() async throws -> [MediaItem] {
        ProcessInfo.processInfo.arguments.contains("--real-root-pages") ? (0..<48).map(movie) : []
    }

    func setWatchlisted(_ on: Bool, item: MediaItem) async throws {
        throw AppError.unknown("Read-only navigation fixture")
    }

    func waitForResumePublication() async { await resumePublicationGate.wait() }

    func featuredContent(limit: Int) async -> [MediaItem] {
        await discoverGate.wait()
        return Array((rowCount..<(rowCount * 2)).prefix(limit).map(movie))
    }

    static func artworkURL(_ base: URL, index: Int) -> URL {
        base.appending(queryItems: [URLQueryItem(name: "fixture-item", value: String(index))])
    }

    private func reference(_ base: URL, index: Int) -> URL {
        ProcessInfo.processInfo.arguments.contains("--distinct-home-artwork")
            ? Self.artworkURL(base, index: index) : base
    }
    var kind: ProviderKind { .jellyfin }
    var session: UserSession {
        UserSession(
            server: MediaServer(id: "home-fixture", name: "Fixture", baseURL: backdrop, provider: .jellyfin),
            userID: "fixture", userName: "Fixture", deviceID: "fixture", accessToken: ""
        )
    }

    private func movie(_ index: Int) -> MediaItem {
        let poster = reference(self.poster, index: index)
        let backdrop = reference(self.backdrop, index: index)
        let namespace = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--home-artwork-cache-namespace=") }
            .map { String($0.dropFirst("--home-artwork-cache-namespace=".count)) + "-" } ?? ""
        var item = MediaItem(
            id: "\(namespace)home-movie-\(index)", title: "Fixture movie \(index)",
            kind: ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") ? .series : .movie,
            posterURL: poster, backdropURL: backdrop
        )
        item.sourceAccountID = "home-fixture"
        item.logoURL = reference(logo, index: index)
        item.heroBackdropURL = backdrop
        item.runtime = 7200
        item.resumePosition = index < rowCount ? 1800 : nil
        item.overview = "A locally supplied movie for measuring the production Home view."
        if ProcessInfo.processInfo.arguments.contains("--held-home-artwork") {
            item.posterURL = nil
            item.backdropURL = nil
            item.heroBackdropURL = nil
            item.logoURL = nil
            do {
                let reference = ArtworkReference.networkFile(try NetworkArtworkReference(
                    accountID: "home-fixture", credentialRevision: heldArtworkRevision,
                    catalogArtworkID: "held-\(index)",
                    representation: RemoteFileRepresentation(
                        size: 1_024,
                        identity: RemoteFileIdentity(kind: .modificationTime, modifiedAt: .distantPast),
                        consistency: .changeDetecting
                    ),
                    sourceRevision: "held", dimensions: ArtworkDimensions(width: 960, height: 540)
                ))
                item.artworkSelections = [ArtworkPlacement.poster, .detailBackdrop, .homeHero, .logo].map {
                    .init(placement: $0, references: [reference])
                }
            } catch {
                preconditionFailure("Invalid held artwork fixture: \(error)")
            }
        }
        return item
    }

    func libraries() async throws -> [MediaLibrary] {
        guard ProcessInfo.processInfo.arguments.contains("--progressive-library-rows") else { return [] }
        let count = ProcessInfo.processInfo.arguments.contains("--populated-home-return") ? 8 : 20
        return (0..<count).map {
            MediaLibrary(id: "fixture-library-\($0)", title: "Fixture library \($0)", kind: .movie)
        }
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        if ProcessInfo.processInfo.arguments.contains("--progressive-home-load") {
            await progressiveGate.wait()
        }
        if isOffline { throw AppError.serverUnreachable }
        if ProcessInfo.processInfo.arguments.contains("--empty-home-resume") { return [] }
        try await holdForSlowLoad()
        let items = Array((0..<rowCount).prefix(limit).map(movie))
        if ProcessInfo.processInfo.arguments.contains("--showcase-schedule-fixture") {
            let now = Date()
            for item in items {
                await SeriesScheduleStore.shared.store(SeriesScheduleRecord(
                    seriesKey: MetadataQuery(item).seriesScoped.enrichmentCacheKey,
                    upcomingEpisode: UpcomingEpisode(
                        seriesIdentity: .external(source: "fixture", value: item.id),
                        airDate: now.addingTimeInterval(20 * 86_400),
                        datePrecision: .dateOnly, source: .tvdb, refreshedAt: now
                    ),
                    cadence: AirCadence(weekdays: [6]),
                    refreshedAt: now, refreshDueAt: now.addingTimeInterval(3_600)
                ))
            }
        }
        return items
    }
    func latest(limit: Int) async throws -> [MediaItem] {
        await recentGate.wait()
        try await holdForSlowLoad()
        return Array((rowCount..<(rowCount * 2)).prefix(limit).map(movie))
    }
    /// Keeps Home on its loading skeleton for a while so it can be captured.
    private func holdForSlowLoad() async throws {
        guard ProcessInfo.processInfo.arguments.contains("--slow-home-load") else { return }
        try await Task.sleep(for: .seconds(6))
    }
    func item(id: String) async throws -> MediaItem {
        let count = ProcessInfo.processInfo.arguments.contains("--progressive-library-rows")
            ? rowCount + 400 : rowCount * 2
        guard let index = Int(id.split(separator: "-").last ?? ""), (0..<count).contains(index) else {
            throw AppError.notFound
        }
        return movie(index)
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if containerID == "detail-sequence-library" {
            let end = min(page.startIndex + page.limit, rowCount * 2)
            return MediaPage(
                items: page.startIndex < end ? (page.startIndex..<end).map(movie) : [],
                startIndex: page.startIndex, totalCount: rowCount * 2
            )
        }
        guard containerID.hasPrefix("fixture-library-"),
              let index = Int(containerID.split(separator: "-").last ?? "") else {
            return MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
        }
        if index > 0 {
            await progressiveGate.wait()
        } else {
            await recentGate.wait()
        }
        let start = rowCount + index * 20
        return MediaPage(
            items: Array((start..<(start + 20)).prefix(page.limit).map(movie)),
            startIndex: page.startIndex, totalCount: 20
        )
    }

    private final class ProductionHomeRowsGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var token: Int32 = -1

        init(notificationKey: String = "PLOZZ_HOME_ROWS_RELEASE_NOTIFICATION") {
            guard let name = ProcessInfo.processInfo.environment[notificationKey] else {
                opened = true
                return
            }
            let status = notify_register_dispatch(name, &token, .main) { [weak self] _ in self?.open() }
            precondition(status == UInt32(NOTIFY_STATUS_OK), "The progressive Home fixture needs its release notification.")
        }

        deinit { if token >= 0 { notify_cancel(token) } }

        private func open() {
            lock.lock()
            opened = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if opened {
                        lock.unlock()
                        continuation.resume()
                    } else {
                        waiters.append(continuation)
                        lock.unlock()
                    }
                }
            } onCancel: {
                self.open()
            }
        }
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? {
        guard let index = Int(itemID.split(separator: "-").last ?? "") else { return poster }
        return reference(poster, index: index)
    }
}
