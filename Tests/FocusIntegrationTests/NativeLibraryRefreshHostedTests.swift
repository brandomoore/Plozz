#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import AppShell
@testable import FeatureHome
import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class NativeLibraryRefreshHostedTests: XCTestCase {
    func testShareNameFillsHeaderOnlyWhenModeTabsAreAbsent() async throws {
        for hasTabs in [false, true] {
            let provider = RefreshLibraryProvider(
                kind: hasTabs ? .jellyfin : .mediaShare, supportsModes: hasTabs, supportsFilters: true
            )
            let name = "ShareHeader.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: defaults, initialContentMode: .titles
            )
            await model.loadFirstPage()
            try await withLibrary(model: model, title: Text(verbatim: "Family Media")) { _, window in
                let image = self.capture(window, name: hasTabs ? "library-mode-header" : "share-name-header")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.regionOfInterest = CGRect(x: 0, y: 0.8, width: 1, height: 0.2)
                try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                XCTAssertEqual(text.contains("Family Media"), !hasTabs, text)
                let controls = self.focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return frame
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(controls.count, hasTabs ? model.availableContentModes.count + 2 : 2,
                               "The share name must not become a focusable control.")
                XCTAssertLessThanOrEqual(try XCTUnwrap(controls.last).maxX, window.bounds.width)
                if !hasTabs {
                    XCTAssertGreaterThan(try XCTUnwrap(controls.first).minX, window.bounds.width / 2,
                                         "Filter and Sort must remain on the right of the share name.")
                }
            }
        }
    }

    func testLongCombinedFilterFitsHeaderWithoutReplacingFocusedControl() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        let name = "LibraryAdaptiveFilter.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            @MainActor func controls() -> [(any UIFocusItem, CGRect)] {
                self.focusItems(in: window).compactMap { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return (item, frame)
                }.sorted { $0.1.minX < $1.1.minX }
            }
            let initial = controls()
            XCTAssertEqual(initial.count, model.availableContentModes.count + 2)
            guard initial.count >= 2 else { return }
            let filter = initial[initial.count - 2].0
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            controller.target = filter
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            controller.target = nil
            var widths: [CGFloat] = []
            for selection in [
                LibraryFilters(filter: .unwatched),
                LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024),
                LibraryFilters(filter: .unwatched, genre: "Adapted From A Live-Action Movie", year: 2024),
                LibraryFilters(filter: .unwatched, genre: "Drama", year: 2024),
            ] {
                await model.setFilters(selection)
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                let current = controls()
                XCTAssertEqual(current.count, initial.count)
                XCTAssertTrue(focus.focusedItem === filter, "Changing label representation must keep the same native Menu.")
                guard current.count == initial.count else { continue }
                widths.append(current[current.count - 2].1.width)
                for (index, entry) in current.enumerated() {
                    XCTAssertGreaterThanOrEqual(entry.1.minX, 0)
                    XCTAssertLessThanOrEqual(entry.1.maxX, window.bounds.width)
                    XCTAssertEqual(entry.1.midY, initial[index].1.midY, accuracy: 1)
                    if index > 0 { XCTAssertGreaterThanOrEqual(entry.1.minX, current[index - 1].1.maxX) }
                }
                XCTAssertEqual(current.last!.1.maxX, initial.last!.1.maxX, accuracy: 1)
            }
            XCTAssertEqual(widths.count, 4)
            guard widths.count == 4 else { return }
            XCTAssertGreaterThan(widths[1], widths[0], "A short combined selection must still display its names.")
            XCTAssertLessThan(widths[2], widths[0], "Only the overflowing selection should collapse to its count.")
            XCTAssertEqual(widths[3], widths[1], accuracy: 1, "Names must return when the selection fits again.")
        }
    }

    func testSameFilterSummaryUsesNamesAgainWhenMoreHeaderSpaceIsAvailable() async throws {
        let name = "LibraryAdaptiveFilterWidth.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var widths: [CGFloat] = []
        for supportsModes in [true, false] {
            let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: supportsModes, supportsFilters: true)
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library-\(supportsModes)", containerKind: .movie,
                defaults: defaults, initialContentMode: .titles
            )
            await model.setFilters(.init(filter: .unwatched, genre: "Adapted From A Live-Action Movie", year: 2024))
            try await withLibrary(model: model) { _, window in
                let controls = self.focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          frame.midY < window.bounds.height * 0.2 else { return nil }
                    return frame
                }.sorted { $0.minX < $1.minX }
                XCTAssertEqual(controls.count, model.availableContentModes.count + 2)
                guard controls.count >= 2 else { return }
                widths.append(controls[controls.count - 2].width)
                XCTAssertLessThanOrEqual(controls.last!.maxX, window.bounds.width)
                XCTAssertGreaterThanOrEqual(controls.first!.minX, 0)
            }
        }
        XCTAssertEqual(widths.count, 2)
        guard widths.count == 2 else { return }
        XCTAssertGreaterThan(widths[1], widths[0] * 2,
                             "The same long selection must use available room, not a character-count cutoff.")
    }

    func testFilterSharesHeaderLineAndRetainsNativeFocusAfterSelection() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        await provider.enableAlphabet()
        let name = "LibraryFilterFocus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let controls = self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.sorted { $0.1.minX < $1.1.minX }
            XCTAssertEqual(controls.count, model.availableContentModes.count + 2,
                           "Alphabet navigation must not add a separate header control.")
            guard controls.count >= 3 else { return }
            let filter = controls[controls.count - 2]
            let sort = try XCTUnwrap(controls.last)
            XCTAssertEqual(filter.1.midY, sort.1.midY, accuracy: 1)
            XCTAssertEqual(sort.1.minX - filter.1.maxX, PlozzTheme.Spacing.medium, accuracy: 1)
            XCTAssertEqual(try XCTUnwrap(controls.first).1.midY, sort.1.midY, accuracy: 1)
            controller.target = filter.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === filter.0)
            controller.target = nil
            await model.setFilters(.init(filter: .unwatched))
            try await Task.sleep(for: .milliseconds(200))
            window.layoutIfNeeded()
            XCTAssertTrue(focus.focusedItem === filter.0, "Selecting a filter must retain the actual header control.")
            _ = self.capture(window, name: "named-active-library-filter")
        }
    }

    func testSortKeepsHeaderFocusWhenScrollingAlphabetEligibilityChanges() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true)
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let sort = try XCTUnwrap(self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.max { $0.1.maxX < $1.1.maxX }?.0)
            controller.target = sort
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === sort)
            controller.target = nil

            for field: SortField in [.runtime, .name] {
                await model.setSort(CoreModels.SortDescriptor(field: field, direction: field.defaultDirection))
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                XCTAssertEqual(model.alphabet.isVisible, field == .name)
                XCTAssertTrue(focus.focusedItem === sort,
                              "Changing alphabet eligibility must not move focus out of Sort.")
            }
        }
    }

    func testIndexedFilterKeepsHeaderPositionAndCentersProgressInContent() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, supportsFilters: true)
        let name = "LibraryQueryGeometry.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: defaults, initialContentMode: .titles
        )
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            @MainActor func headerFrames() -> [CGRect] {
                self.focusItems(in: window).compactMap {
                    NavigationRowFocusRequester.frame(of: $0, relativeTo: window)
                }.filter { $0.midY < window.bounds.height * 0.2 }.sorted { $0.minX < $1.minX }
            }
            let before = headerFrames()
            XCTAssertEqual(before.count, model.availableContentModes.count + 2)
            await provider.holdNextPage(at: 0)
            let query = Task { await model.setFilters(.init(filter: .dolbyVision)) }
            await self.waitForHeldPage(provider)
            try await Task.sleep(for: .milliseconds(100))
            window.layoutIfNeeded()
            let during = headerFrames()
            XCTAssertEqual(during.count, before.count, "Loading must not relocate the header out of its top band.")
            for (old, current) in zip(before, during) {
                XCTAssertEqual(current.midY, old.midY, accuracy: 1)
            }
            let progress = self.find(UIProgressView.self, in: root)
            let progressFrame = progress.map { $0.convert($0.bounds, to: window) }
            _ = self.capture(window, name: "indexed-filter-fixed-header")
            await provider.releasePage()
            await query.value
            let bar = try XCTUnwrap(progressFrame, "Measure the actual rendered progress bar, not its enclosing screen.")
            let contentTop = try XCTUnwrap(during.last).maxY + PlozzTheme.Spacing.large
            XCTAssertEqual(bar.midY, (contentTop + window.safeAreaLayoutGuide.layoutFrame.maxY) / 2, accuracy: 3)
            window.layoutIfNeeded()
            let after = headerFrames()
            XCTAssertEqual(after.count, before.count)
            for (old, current) in zip(before, after) {
                XCTAssertEqual(current.midY, old.midY, accuracy: 1)
            }
        }
    }

    func testLibraryModeSwitchKeepsFocusOnSelectedTab() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let headerControls = self.focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2,
                      frame.maxX < window.bounds.width * 0.6 else { return nil }
                return (item, frame)
            }.sorted { $0.1.minX < $1.1.minX }
            XCTAssertEqual(headerControls.count, model.availableContentModes.count)
            guard headerControls.count == model.availableContentModes.count else { return }
            for mode: LibraryContentMode in [.titles, .collections, .playlists, .recommended] {
                let index = try XCTUnwrap(model.availableContentModes.firstIndex(of: mode))
                let control = headerControls[index].0
                controller.target = control
                focus.requestFocusUpdate(to: controller)
                focus.updateFocusIfNeeded()
                XCTAssertTrue(focus.focusedItem === control, "\(mode) must be focused before selection")
                controller.target = nil

                await model.setContentMode(mode)
                try await Task.sleep(for: .milliseconds(120))
                window.layoutIfNeeded()
                XCTAssertTrue(focus.focusedItem === control, "\(mode) must retain actual focus after selection")
            }
        }
    }

    func testRecommendedShowcaseHidesNavigationBelowFirstRowAndRestoresItOnReturn() async throws {
        let provider = RefreshLibraryProvider(kind: .jellyfin, supportsModes: true, recommendationHub: true)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!
        )
        await model.loadRecommendationsIfNeeded()
        try await withLibrary(model: model) { _, window in
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            @MainActor func headerControls() -> [any UIFocusItem] {
                self.focusItems(in: window).filter { item in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window) else {
                        return false
                    }
                    return frame.midY < window.bounds.height * 0.2 && frame.height < 150 &&
                        frame.maxX < window.bounds.width * 0.6
                }
            }
            let cards = focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY > window.bounds.height * 0.3,
                      frame.width > 100 else { return nil }
                return (item, frame)
            }.sorted { $0.1.midY < $1.1.midY }
            XCTAssertEqual(headerControls().count, model.availableContentModes.count)
            let first = try XCTUnwrap(cards.first)
            controller.target = first.0
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === first.0, "Enter the first row before navigating below it.")
            controller.target = nil
            try await Task.sleep(for: .milliseconds(200))
            let next = try XCTUnwrap(focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.width > 100, frame.midY > first.1.midY + 100 else { return nil }
                return (item, frame)
            }.min { $0.1.midY < $1.1.midY })

            for (card, expectedHeaderCount) in [
                (next.0, 0),
                (first.0, model.availableContentModes.count),
            ] {
                controller.target = card
                focus.requestFocusUpdate(to: controller)
                focus.updateFocusIfNeeded()
                XCTAssertTrue(focus.focusedItem === card, "The requested Showcase row must receive focus")
                controller.target = nil
                try await Task.sleep(for: .milliseconds(200))
                window.layoutIfNeeded()
                XCTAssertEqual(headerControls().count, expectedHeaderCount)
            }
        }
    }

    func testWatchlistAndJumpToastsShareOpaqueThemeSurfaceAndHeight() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for (name, palette) in [("dark", ThemePalette.dark), ("light", .light), ("black", .pureBlack)] {
            let presenter = TransientStatusPresenter(announcement: { _ in })
            var frame = CGRect.zero
            func fixture(background: Color) -> some View {
                TransientStatusView(presenter: presenter, palette: palette)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(background)
                    .environment(\.colorScheme, palette.isLight ? .light : .dark)
            }
            let host = UIHostingController(rootView: fixture(background: .red))
            window.rootViewController = host
            window.makeKeyAndVisible()
            presenter.present(icon: "bookmark.fill", text: "Added to Watchlist")
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let watchlistFrame = frame
            XCTAssertGreaterThan(watchlistFrame.width, 200)
            let watchlistImage = capture(window, name: "watchlist-toast-\(name)")
            let surfacePoint = CGPoint(x: frame.midX, y: frame.minY + 6)
            let watchlistSurface = try pixel(watchlistImage, at: surfacePoint)

            host.rootView = fixture(background: .blue)
            presenter.present(icon: "magnifyingglass", text: "Jumping to U…", isProgress: true)
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            XCTAssertEqual(frame.height, watchlistFrame.height, accuracy: 1,
                           "The spinner must not enlarge the shared capsule")
            let progressImage = capture(window, name: "jump-toast-\(name)")
            let progressSurface = try pixel(progressImage, at: CGPoint(x: frame.midX, y: frame.minY + 6))
            XCTAssertEqual(progressSurface, watchlistSurface,
                           "The same opaque theme surface must ignore different artwork behind it")
            presenter.dismiss()
        }
    }

    func testJumpUsesSharedToastBeforeMenuDismissalWithoutAddingFocusTargets() async throws {
        for light in [false, true] {
            let provider = RefreshLibraryProvider()
            await provider.enableAlphabet(letters: ["A", "U"])
            let model = LibraryBrowseViewModel(
                provider: provider, containerID: "library", containerKind: .movie,
                defaults: UserDefaults(suiteName: UUID().uuidString)!)
            await model.loadFirstPage()
            await provider.holdNextPage(at: 112)
            let presenter = TransientStatusPresenter(announcement: { _ in })
            try await withLibrary(model: model, palette: light ? .light : .dark, presenter: presenter) { _, window in
                let host = try XCTUnwrap(window.rootViewController)
                let menu = UIAlertController(title: "Letters", message: nil, preferredStyle: .alert)
                menu.addAction(UIAlertAction(title: "U", style: .default))
                await withCheckedContinuation { continuation in
                    host.present(menu, animated: true) { continuation.resume() }
                }
                let id = UUID()
                let jump = try XCTUnwrap(model.beginLetterJump("U", menuPresentationID: id))
                XCTAssertEqual(model.alphabet.jumpingTo, "U")
                defer {
                    model.cancelLetterJump()
                    Task { await provider.releasePage() }
                }
                await waitForHeldPage(provider)
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(presenter.message?.isProgress, true, "Status is available while the menu is still presented")
                XCTAssertEqual(presenter.message.map { String(localized: $0.text) }, "Jumping to U…")
                XCTAssertNil(model.alphabet.destination)
                await withCheckedContinuation { continuation in
                    menu.dismiss(animated: true) { continuation.resume() }
                }
                model.alphabet.menuDidDismiss(id)
                try await Task.sleep(for: .milliseconds(250))
                window.layoutIfNeeded()
                let footerTargets = focusItems(in: window).compactMap { item -> CGRect? in
                    guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                          window.bounds.contains(frame),
                          frame.midY > window.bounds.height * 0.75, frame.height < 100 else { return nil }
                    return frame
                }
                XCTAssertTrue(footerTargets.isEmpty, "The toast must not add an inaccessible Cancel focus target")
                capture(window, name: light ? "alphabet-shared-toast-light" : "alphabet-shared-toast-dark")
                model.cancelLetterJump()
                await provider.releasePage()
                _ = await jump.value
                try await Task.sleep(for: .milliseconds(50))
                XCTAssertNil(model.alphabet.destination)
                XCTAssertNil(presenter.message)
            }
        }
    }

    func testMenuSelectionCommitsOnlyAfterPresentedControllerDismisses() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let host = try XCTUnwrap(window.rootViewController)
            let completion = LibraryAlphabetMenuCompletion.Controller()
            host.addChild(completion)
            root.addSubview(completion.view)
            completion.didMove(toParent: host)
            defer {
                completion.update(selection: nil, onCommit: nil)
                completion.willMove(toParent: nil)
                completion.view.removeFromSuperview()
                completion.removeFromParent()
            }
            let menu = UIAlertController(title: "Letters", message: nil, preferredStyle: .alert)
            menu.addAction(UIAlertAction(title: "M", style: .default))
            await withCheckedContinuation { continuation in
                host.present(menu, animated: true) { continuation.resume() }
            }
            var committed: [UUID] = []
            let id = UUID()
            let finished = expectation(description: "Menu selection committed after dismissal")
            completion.update(selection: id) { selection in
                committed.append(selection)
                finished.fulfill()
            }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(committed.isEmpty, "The menu still owns focus")
            await withCheckedContinuation { continuation in
                menu.dismiss(animated: true) { continuation.resume() }
            }
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(committed, [id])
            completion.update(selection: nil, onCommit: nil)
        }
    }

    func testManualScrollingKeepsViewportAndFocusWhenPendingRowsArrive() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet(letters: LibraryLetterIndex.railLetters)
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        await provider.holdNextPage(at: 112)
        defer { Task { await provider.releasePage() } }
        try await withGrid(model: model) { collection in
            let path = IndexPath(item: 140, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            await waitForHeldPage(provider)
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertNil(cell.item)
            XCTAssertTrue(cell.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(250))
            let offset = collection.contentOffset
            XCTAssertNil(model.alphabet.positionLetter,
                         "A pending viewport must not claim an earlier letter: top=\(String(describing: model.topVisibleIndex)) visible=\(collection.indexPathsForVisibleItems.sorted()) offset=\(offset)")
            XCTAssertTrue(model.alphabet.isPositionLoading)
            capture(try XCTUnwrap(collection.window), name: "alphabet-manual-pending")
            await provider.releasePage()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(collection.contentOffset.x, offset.x, accuracy: 2)
            XCTAssertEqual(collection.contentOffset.y, offset.y, accuracy: 2)
            XCTAssertTrue(cell.isFocused)
            XCTAssertTrue(UIFocusSystem(for: cell)?.focusedItem === cell)
            XCTAssertEqual(cell.item?.title, "Movie 140")
            XCTAssertNil(model.alphabet.destination)
            capture(try XCTUnwrap(collection.window), name: "alphabet-manual-loaded")
        }
    }

    func testCustomGridAlphabetJumpTransfersRealFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model, focusStyle: .highlight) { root, window in
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(800))
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
            let item = try XCTUnwrap(model.item(at: 140))
            let source = try XCTUnwrap(findSource(item.stablePresentationID, in: root))
            let frame = try XCTUnwrap(NavigationRowFocusRequester.frame(of: focused, relativeTo: source))
            XCTAssertTrue(frame.contains(CGPoint(x: source.bounds.midX, y: source.bounds.midY)),
                          "The real SwiftUI focus item must enclose the destination artwork")
            XCTAssertTrue(window.bounds.intersects(source.convert(source.bounds, to: window)))
            XCTAssertEqual(source.reference?.isFocused, true, "The destination must also draw its focus highlight")
        }
    }

    func testRailPreviewScrollDoesNotStealFocusFromItsControl() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        try await withLibrary(model: model) { root, window in
            let railControl = UIButton(type: .system)
            railControl.setTitle("M", for: .normal)
            railControl.frame = CGRect(x: root.bounds.maxX - 100, y: 400, width: 80, height: 70)
            root.addSubview(railControl)
            defer { railControl.removeFromSuperview() }
            window.layoutIfNeeded()
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            controller.target = railControl
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === railControl)
            controller.target = nil
            _ = await model.jumpToLetter("M", focusesItem: false)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertTrue(focus.focusedItem === railControl, "Rail navigation only previews the new window")
            let collection = try XCTUnwrap(find(UICollectionView.self, in: root))
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(IndexPath(item: 140, section: 0)))
        }
    }

    func testDeferredAlphabetJumpScrollsToLoadedNativeCardAndRetainsUsableFocus() async throws {
        let provider = RefreshLibraryProvider()
        await provider.enableAlphabet()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie,
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            XCTAssertTrue(model.alphabet.isVisible, "Alphabet indexing must remain available without a header button.")
            let window = try XCTUnwrap(collection.window)
            let controller = try XCTUnwrap(window.rootViewController as? LibraryFocusFixtureController)
            let headerTarget = try XCTUnwrap(focusItems(in: window).compactMap { item -> (any UIFocusItem, CGRect)? in
                guard let frame = NavigationRowFocusRequester.frame(of: item, relativeTo: window),
                      frame.midY < window.bounds.height * 0.2 else { return nil }
                return (item, frame)
            }.max { $0.1.maxX < $1.1.maxX }?.0)
            let focus = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            controller.target = headerTarget
            focus.requestFocusUpdate(to: controller)
            focus.updateFocusIfNeeded()
            XCTAssertTrue(focus.focusedItem === headerTarget, "Begin with the remaining Sort control focused.")
            controller.target = nil
            let index = await model.jumpToLetter("M")
            XCTAssertEqual(index, 140)
            try await Task.sleep(for: .milliseconds(700))
            collection.layoutIfNeeded()
            let path = IndexPath(item: 140, section: 0)
            XCTAssertTrue(collection.indexPathsForVisibleItems.contains(path))
            let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertEqual(cell.item?.title, "Movie 140")
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(cell.isFocused, "A committed alphabet jump must transfer actual focus, not just scroll")
            XCTAssertTrue(UIFocusSystem(for: cell)?.focusedItem === cell)
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, "Before-140")
        }
    }

    func testCorrectedPageTotalsPreserveScrollAndExistingCells() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let controller = NativeLibraryGridController()
        defer { controller.stopObserving() }
        func update() {
            controller.update(
                model: model, total: model.totalCount, generation: model.contentGeneration,
                spoilerSettings: .default, environment: EnvironmentValues(),
                leadingInset: 40, trailingInset: 40, header: AnyView(Text("Library")),
                hidesScrollIndicator: false, onSelect: { _, _ in }, onLoaded: { _ in }
            )
        }
        update()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        controller.view.layoutIfNeeded()
        let collection = try XCTUnwrap(find(UICollectionView.self, in: controller.view))
        collection.layoutIfNeeded()
        collection.setContentOffset(CGPoint(x: 0, y: 4000), animated: false)
        collection.layoutIfNeeded()
        let before = collection.contentOffset.y
        XCTAssertGreaterThan(before, 3000)
        let visible = try XCTUnwrap(collection.indexPathsForVisibleItems.sorted().first)
        let cell = try XCTUnwrap(collection.cellForItem(at: visible))

        for (count, index) in [(245, 100), (230, 170)] {
            await provider.change(total: count, prefix: "Before")
            await model.itemAppeared(at: index, generation: model.contentGeneration)
            XCTAssertEqual(model.totalCount, count)
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertEqual(collection.contentOffset.y, before, accuracy: 1)
            XCTAssertTrue(collection.cellForItem(at: visible) === cell)
        }
        for count in [5, 0] {
            await provider.change(total: count, prefix: "Before")
            await model.refreshAfterCatalogChange()
            update()
            collection.layoutIfNeeded()
            XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
            XCTAssertLessThanOrEqual(collection.contentOffset.y, max(0, collection.contentSize.height - collection.bounds.height))
        }
    }

    func testSameCountCatalogRefreshUpdatesVisibleNativeCellsAndSelection() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            let path = IndexPath(item: 0, section: 0)
            let first = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            let slot = model.slot(at: 0)
            XCTAssertEqual(first.item?.title, "Before 0")
            let generation = model.contentGeneration
            await provider.change(total: 240, prefix: "After")
            await model.refreshAfterCatalogChange()
            try await Task.sleep(for: .milliseconds(200))
            let refreshed = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(refreshed === first)
            XCTAssertTrue(model.slot(at: 0) === slot)
            XCTAssertEqual(model.contentGeneration, generation)
            XCTAssertEqual(refreshed.item?.title, "After 0")
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, refreshed.item?.id)
            XCTAssertEqual(selected?.title, refreshed.item?.title)
        }
    }

    func testCatalogCountChangesKeepScrolledNativeFocus() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 240
        )
        await model.loadFirstPage()
        try await withGrid(model: model) { collection in
            let path = IndexPath(item: 60, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let focused = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertTrue(focused.onRequestFocus?() == true)
            try await Task.sleep(for: .milliseconds(600))
            let offset = collection.contentOffset.y
            XCTAssertGreaterThan(offset, 2000)
            for count in [245, 230] {
                await provider.change(total: count, prefix: "Count \(count)")
                await model.refreshAfterCatalogChange()
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(collection.numberOfItems(inSection: 0), count)
                XCTAssertTrue(collection.cellForItem(at: path) === focused)
                XCTAssertTrue(focused.isFocused)
                XCTAssertEqual(focused.item?.title, "Count \(count) 60")
                XCTAssertEqual(collection.contentOffset.y, offset, accuracy: 2)
            }
        }
    }

    func testFailedCatalogRefreshKeepsExistingPagingCallbacksValid() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let generation = model.contentGeneration
        let slot = model.slot(at: 0)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 0) === slot)
        await model.itemAppeared(at: 100, generation: generation)
        XCTAssertNotNil(model.item(at: 100))
    }

    func testCatalogRefreshReloadsPreviouslyLoadedOffscreenPageInLargeLibrary() async {
        let provider = RefreshLibraryProvider()
        await provider.change(total: 2_178, prefix: "Before")
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await model.itemAppeared(at: 1_750, generation: generation)
        let slot = model.slot(at: 1_750)
        XCTAssertEqual(slot?.item?.id, "Before-1750")
        model.itemDisappeared(at: 1_750, generation: generation)

        await provider.change(total: 2_178, prefix: "After")
        await model.refreshAfterCatalogChange()

        XCTAssertEqual(model.totalCount, 2_178)
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 1_750) === slot)
        XCTAssertNil(slot?.item, "An off-screen page is invalidated, not treated as already loaded.")
        await model.itemAppeared(at: 1_750, generation: generation)
        XCTAssertEqual(slot?.item?.id, "After-1750", "Returning must refill the existing slot without reopening the grid.")
        XCTAssertEqual(model.item(at: 1_791)?.id, "After-1791", "The entire 42-item page must reload.")
        XCTAssertNil(model.pageError)
    }

    func testLargeNativeGridRefillsOffscreenPageAfterMidScanRefresh() async throws {
        let provider = RefreshLibraryProvider()
        await provider.change(total: 2_178, prefix: "Before")
        let model = LibraryBrowseViewModel(provider: provider, containerID: "library", containerKind: .movie)
        await model.loadFirstPage()
        var selected: MediaItem?
        try await withGrid(model: model, onSelect: { selected = $0 }) { collection in
            let path = IndexPath(item: 1_750, section: 0)
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            _ = try await waitForGridItem("Before-1750", at: path, in: collection)
            let slot = model.slot(at: path.item)
            let generation = model.contentGeneration

            collection.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
            collection.layoutIfNeeded()
            _ = try await waitForGridItem("Before-0", at: IndexPath(item: 0, section: 0), in: collection)
            XCTAssertNil(collection.cellForItem(at: path), "The regression requires a previously loaded off-screen page.")
            await provider.change(total: 2_178, prefix: "After")
            await model.refreshAfterCatalogChange()
            XCTAssertTrue(model.slot(at: path.item) === slot)
            XCTAssertNil(slot?.item)
            XCTAssertEqual(model.contentGeneration, generation)

            await provider.holdNextPage(at: 1_750)
            defer { Task { await provider.releasePage() } }
            collection.scrollToItem(at: path, at: .centeredVertically, animated: false)
            collection.layoutIfNeeded()
            await waitForHeldPage(provider)
            let loading = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
            XCTAssertNil(loading.item)
            await provider.releasePage()
            let loaded = try await waitForGridItem("After-1750", at: path, in: collection)
            XCTAssertTrue(loaded === loading, "The on-screen placeholder must update without recycling or reopening.")
            XCTAssertEqual(slot?.item?.id, "After-1750")
            collection.delegate?.collectionView?(collection, didSelectItemAt: path)
            XCTAssertEqual(selected?.id, "After-1750")
        }
    }

    func testRefreshIncludesViewportThatMovedWhileFirstPageWasPending() async throws {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 0)
        let refresh = Task { await model.refreshAfterCatalogChange() }
        await waitForHeldPage(provider)
        await model.itemAppeared(at: 30, generation: generation)
        XCTAssertNotNil(model.item(at: 30), "The visible snapshot must remain pageable during refresh.")
        let slot = model.slot(at: 30)
        await provider.change(total: 240, prefix: "Moved")
        await provider.releasePage()
        await refresh.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertTrue(model.slot(at: 30) === slot)
        XCTAssertEqual(model.item(at: 30)?.title, "Moved 30")
        XCTAssertEqual(model.topVisibleIndex, 30)
    }

    func testInFlightPageSurvivesFailedRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let generation = model.contentGeneration
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: generation) }
        await waitForHeldPage(provider)
        await provider.setFailure(true)
        await model.refreshAfterCatalogChange()
        await provider.setFailure(false)
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.contentGeneration, generation)
        XCTAssertNotNil(model.item(at: 30))
    }

    func testLatePageCannotOverwriteSuccessfulRefresh() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        await provider.holdNextPage(at: 30)
        let paging = Task { await model.itemAppeared(at: 30, generation: model.contentGeneration) }
        await waitForHeldPage(provider)
        await provider.change(total: 240, prefix: "After")
        await model.refreshAfterCatalogChange()
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
        await provider.releasePage()
        await paging.value
        XCTAssertEqual(model.item(at: 30)?.title, "After 30")
    }

    func testShortRefreshClearsUnreturnedItemsWithinTheRefreshedPage() async {
        let provider = RefreshLibraryProvider()
        let model = LibraryBrowseViewModel(
            provider: provider, containerID: "library", containerKind: .movie, pageSize: 10
        )
        await model.loadFirstPage()
        let slot = model.slot(at: 5)
        XCTAssertNotNil(slot?.item)
        await provider.setPageCap(3)
        await model.refreshAfterCatalogChange()
        XCTAssertTrue(model.slot(at: 5) === slot)
        XCTAssertNotNil(model.item(at: 2))
        XCTAssertNil(model.item(at: 3))
        XCTAssertNil(model.item(at: 5))
    }

    private func withGrid(
        model: LibraryBrowseViewModel,
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UICollectionView) async throws -> Void
    ) async throws {
        try await withLibrary(model: model, onSelect: onSelect) { root, _ in
            try await body(XCTUnwrap(find(UICollectionView.self, in: root)))
        }
    }

    private func withLibrary(
        model: LibraryBrowseViewModel,
        title: Text = Text("Library"),
        focusStyle: CardFocusStyle = .system,
        palette: ThemePalette = .dark,
        presenter: TransientStatusPresenter = TransientStatusPresenter(announcement: { _ in }),
        onSelect: @escaping (MediaItem) -> Void = { _ in },
        body: (UIView, UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(
            rootView:
                LibraryBrowseView(viewModel: model, title: title, onSelect: onSelect)
                .environment(\.plozzCardFocusStyle, focusStyle)
                .environment(\.plozzCardStyle, .borderless)
                .environment(\.themePalette, palette)
                .preferredColorScheme(palette.isLight ? .light : .dark)
                .transientStatusOverlay(presenter: presenter, palette: palette)
        )
        let container = LibraryFocusFixtureController()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.view.frame = window.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.didMove(toParent: container)
        window.rootViewController = container
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(400))
        try await body(container.view, window)
    }

    private func waitForHeldPage(_ provider: RefreshLibraryProvider) async {
        for _ in 0..<100 {
            if await provider.isHoldingPage { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Expected the fixture page request to reach its gate.")
    }

    private func waitForGridItem(
        _ id: String, at path: IndexPath, in collection: UICollectionView
    ) async throws -> NativeTVLibraryCell {
        for _ in 0..<200 {
            if let cell = collection.cellForItem(at: path) as? NativeTVLibraryCell, cell.item?.id == id {
                return cell
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cell = try XCTUnwrap(collection.cellForItem(at: path) as? NativeTVLibraryCell)
        XCTAssertEqual(cell.item?.id, id, "The displayed page did not finish loading.")
        return cell
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func findSource(_ itemKey: String, in view: UIView) -> DetailTransitionSourceView? {
        if let source = view as? DetailTransitionSourceView, source.reference?.itemKey == itemKey { return source }
        return view.subviews.lazy.compactMap { self.findSource(itemKey, in: $0) }.first
    }

    private func findController<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        return controller.children.lazy.compactMap { self.findController(type, in: $0) }.first
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var result: [any UIFocusItem] = []
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let frame = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: frame) {
                if let children = item.focusItemContainer { containers.append(children) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { result.append(item) }
            }
        }
        return result
    }

    @discardableResult
    private func capture(_ window: UIWindow, name: String) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image {
            window.layer.render(in: $0.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        let rect = CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)
        let cropped = try XCTUnwrap(image.cropping(to: rect))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

private final class LibraryFocusFixtureController: UIViewController {
    weak var target: (any UIFocusEnvironment)?
    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        target.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

private actor RefreshLibraryProvider: MediaLibraryQueryProviding, CapabilityReporting {
    nonisolated let kind: ProviderKind
    nonisolated let session: UserSession
    nonisolated let capabilities: ProviderCapability
    private let recommendationHub: Bool
    nonisolated let supportsFilters: Bool
    init(kind: ProviderKind = .mediaShare, supportsModes: Bool = false, recommendationHub: Bool = false,
         supportsFilters: Bool = false) {
        self.kind = kind
        self.capabilities = supportsModes ? [.libraryCollections, .videoPlaylists] : []
        self.recommendationHub = recommendationHub
        self.supportsFilters = supportsFilters
        self.session = UserSession(
            server: MediaServer(
                id: "fixture", name: "Fixture", baseURL: URL(string: "https://fixture.test")!,
                provider: kind
            ),
            userID: "viewer", userName: "Viewer", deviceID: "fixture", accessToken: "fixture"
        )
    }
    private var total = 240
    private var prefix = "Before"
    private var fails = false
    private var pageCap: Int?
    private var alphabetEnabled = false
    private var alphabetLetters = ["A", "M"]
    private var heldStart: Int?
    private var heldPage: CheckedContinuation<Void, Never>?
    var isHoldingPage: Bool { heldPage != nil }

    nonisolated func supportedSortFields(in containerID: String, kind: MediaItemKind) -> [SortField] {
        SortField.legacyFields
    }
    nonisolated func libraryQueryCapabilities(in containerID: String, kind: MediaItemKind) -> LibraryQueryCapabilities {
        .init(filters: supportsFilters ? [.all, .unwatched, .dolbyVision] : [.all], nativeFilters: [.all, .unwatched],
              supportsGenres: supportsFilters, supportsYears: supportsFilters, nativeFacets: true)
    }
    func libraryQueryFacets(in containerID: String, kind: MediaItemKind) async throws -> LibraryQueryFacets {
        .init()
    }

    func enableAlphabet(letters: [String] = ["A", "M"]) {
        alphabetEnabled = true
        alphabetLetters = letters
    }
    func letterIndex(in containerID: String, kind: MediaItemKind,
                     sort: CoreModels.SortDescriptor) async throws -> [LibraryLetterIndexEntry] {
        alphabetEnabled && sort.field == .name ? alphabetLetters.map { .init(letter: $0) } : []
    }
    func letterPosition(in containerID: String, kind: MediaItemKind, letter: String,
                        sort: CoreModels.SortDescriptor) async throws -> Int? {
        letter == "A" ? 0 : 140
    }

    func change(total: Int, prefix: String) {
        self.total = total
        self.prefix = prefix
    }
    func setFailure(_ value: Bool) { fails = value }
    func setPageCap(_ value: Int) { pageCap = value }
    func holdNextPage(at start: Int) { heldStart = start }
    func releasePage() {
        heldPage?.resume()
        heldPage = nil
    }

    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        if fails { throw AppError.invalidResponse }
        let end = min(total, page.startIndex + min(page.limit, pageCap ?? page.limit))
        let response = MediaPage(
            items: (min(page.startIndex, end)..<end).map {
                MediaItem(id: "\(prefix)-\($0)",
                          title: "\(alphabetEnabled ? ($0 < 140 ? "Alpha" : "Movie") : prefix) \($0)", kind: .movie)
            }, startIndex: page.startIndex, totalCount: total)
        if heldStart == page.startIndex {
            heldStart = nil
            await withCheckedContinuation { heldPage = $0 }
        }
        return response
    }
    func collections(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await items(in: libraryID, kind: .collection, page: page)
    }
    func videoPlaylists(in libraryID: String, page: PageRequest) async throws -> MediaPage {
        try await items(in: libraryID, kind: .playlist, page: page)
    }
    func libraries() async throws -> [MediaLibrary] { [] }
    func libraryHubs(libraryID: String, kind: MediaItemKind, limit: Int) async throws -> [LibrarySection] {
        guard recommendationHub else { return [] }
        return [LibrarySection(
            id: "featured", title: "Featured",
            items: (0..<4).map { MediaItem(id: "Featured-\($0)", title: "Featured \($0)", kind: .movie) }
        )]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
#endif
