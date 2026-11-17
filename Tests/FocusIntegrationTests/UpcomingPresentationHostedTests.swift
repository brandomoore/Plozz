#if os(tvOS)
import CoreModels
@testable import CoreUI
@testable import FeatureHomeCore
import SwiftUI
import TVUIKit
import UIKit
import Vision
import XCTest
@testable import AppShell

@MainActor
final class UpcomingPresentationHostedTests: XCTestCase {
    func testDateRailPreservesDistinctReleasesAndTheirOriginalNavigationItem() async throws {
        let suite = "UpcomingPresentationHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let today = Calendar.current.startOfDay(for: Date())
        let item = MediaItem(id: "same-series", title: "Same series", kind: .series)
        let releases = [2, 3].flatMap { season in
            UpcomingReleaseBuilder.episodes([UpcomingEpisode(
                seriesIdentity: .external(source: "fixture", value: item.id),
                seasonNumber: season, episodeNumber: 1, title: nil, airDate: today,
                datePrecision: .dateOnly, source: .tvmaze, sourceURL: nil, refreshedAt: today
            )], for: item)
        }
        await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
        var selected: [MediaItem] = []
        let window = try host(UpcomingView(model: model, interval: .init(start: today, duration: 86_400))
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .mediaItemNavigator { selected.append($0) })
        defer { close(window) }
        func cards() -> [NativePosterButton] {
            descendants(window).compactMap { $0 as? NativePosterButton }
                .filter { $0.accessibilityLabel == item.title }
        }
        try await waitUntil { cards().count == 2 }
        let buttons = cards()
        XCTAssertEqual(Set(buttons.compactMap(\.accessibilityValue)), ["S2 · E1", "S3 · E1"])
        for button in buttons { button.sendActions(for: .primaryActionTriggered) }
        XCTAssertEqual(selected, [item, item], "Presentation must not replace the real provider/navigation identity.")
    }

    func testDateRailsStayFocusableAfterScrollingPastTheInitialViewport() async throws {
        let suite = "UpcomingPresentationHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayCount = 12
        let releases = (0..<dayCount).flatMap { day in
            (0..<(day == 0 ? 30 : 1)).map { index in
                let item = MediaItem(id: "\(day)-\(index)", title: "Release \(day)-\(index)", kind: .movie)
                return UpcomingRelease(
                    id: item.id, titleKey: UpcomingRelease.titleKey(for: item), item: item,
                    date: calendar.date(byAdding: .day, value: day, to: today)!,
                    datePrecision: .dateOnly, kind: .digital, interests: [.watchlist]
                )
            }
        }
        await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
        let controller = UpcomingFocusController(rootView: AnyView(
            PinnedUpcoming(model: model, interval: .init(start: today, duration: 90 * 86_400))
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)))
        let window = try host(controller: controller)
        defer { close(window) }
        func card(_ day: Int) -> UIView? {
            descendants(window).first {
                $0.canBecomeFocused && $0.accessibilityLabel == "Release \(day)-0"
            }
        }
        try await waitUntil { card(0) != nil }
        let first = try XCTUnwrap(card(0))
        let scrolls = descendants(window).compactMap { $0 as? UIScrollView }.filter {
            first.isDescendant(of: $0)
        }
        let rail = try XCTUnwrap(scrolls.first { $0.contentSize.width > $0.bounds.width + 1 },
                                "A busy date must use Home's horizontal rail, not a nested vertical grid.")
        let agenda = try XCTUnwrap(scrolls.first { $0.contentSize.height > $0.bounds.height + 1 })
        XCTAssertFalse(rail === agenda)
        XCTAssertLessThan(rail.bounds.height, agenda.bounds.height)
        let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
        for day in 1..<dayCount {
            func visibleCard() -> UIView? {
                guard let target = card(day) else { return nil }
                let frame = target.convert(target.bounds, to: agenda)
                return agenda.bounds.intersects(frame) ? target : nil
            }
            for _ in 0..<4 where visibleCard() == nil {
                let bottom = max(-agenda.adjustedContentInset.top,
                                 agenda.contentSize.height - agenda.bounds.height + agenda.adjustedContentInset.bottom)
                agenda.setContentOffset(CGPoint(
                    x: agenda.contentOffset.x,
                    y: min(bottom, agenda.contentOffset.y + agenda.bounds.height / 2)
                ), animated: false)
                try await Task.sleep(for: .milliseconds(100))
            }
            let target = try XCTUnwrap(visibleCard(), "Date \(day) must become available when the agenda scrolls.")
            controller.target = target
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await waitUntil { NativeFocusRegion.contains(system.focusedItem, in: target) }
        }
        XCTAssertGreaterThan(agenda.contentOffset.y, agenda.bounds.height * 2)
    }

    func testPinnedUpcomingInitiallyFocusesAReleaseRatherThanTheToolbar() async throws {
        let suite = "UpcomingPresentationHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let today = Calendar.current.startOfDay(for: Date())
        let item = MediaItem(id: "first", title: "First upcoming movie", kind: .movie)
        await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: [
                UpcomingRelease(id: "first", titleKey: UpcomingRelease.titleKey(for: item), item: item,
                                date: today.addingTimeInterval(86_400), datePrecision: .dateOnly,
                                kind: .digital, interests: [.watchlist])
            ])
        }
        for style in CardStyle.allCases {
            let window = try host(PinnedUpcoming(model: model, interval: .init(start: today, duration: 90 * 86_400))
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.plozzCardStyle, style)
                .environment(\.plozzCardFocusStyle, .system))
            defer { close(window) }
            let deadline = ContinuousClock.now + .seconds(5)
            func contentHasFocus() -> Bool {
                let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem
                return descendants(window).compactMap { $0 as? NavigationEntryFocusRegionView }.contains {
                    $0.preference == .content && NativeFocusRegion.contains(focused, in: $0)
                }
            }
            while !contentHasFocus(), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(contentHasFocus(), "Native focus must enter the sparse release grid, not Calendar.")
            try await Task.sleep(for: .milliseconds(600))
            let observations = try capture(window, name: "upcoming-first-focus-\(style.rawValue)")
            let heading = try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string == "Tomorrow" })
            let headingBottom = (1 - heading.boundingBox.minY) * window.bounds.height
            let focused = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem as? UIView)
            let poster = focused as? NativePosterButton
            func artworkFrames(_ layer: CALayer) -> [CGRect] {
                guard layer !== poster?.overlayView.layer else { return [] }
                let state = layer.presentation() ?? layer
                guard !state.isHidden, state.opacity > 0 else { return [] }
                let frame = NativeFocusProjection.frame(of: layer, in: window.layer)
                let isArtwork = state.contents != nil && state.bounds.height > 100
                    && frame.map { abs($0.height / $0.width - 1.5) < 0.05 } == true
                return (isArtwork ? frame.map { [$0] } ?? [] : [])
                    + (layer.sublayers ?? []).flatMap(artworkFrames)
            }
            let frame: CGRect
            if let card = focused as? TVCardView {
                frame = try XCTUnwrap(NativeFocusProjection.frame(of: card.contentView.layer, in: window.layer))
            } else {
                let poster = try XCTUnwrap(poster)
                let frames = artworkFrames(poster.artworkView.layer)
                var bounds = try XCTUnwrap(frames.first)
                for next in frames.dropFirst() { bounds = bounds.union(next) }
                frame = bounds
            }
            XCTAssertGreaterThan(frame.minY, headingBottom + 8, "Focused \(style) artwork must stay below its date heading.")
            let scroll = try XCTUnwrap(descendants(window).compactMap { $0 as? UIScrollView }.first {
                focused.isDescendant(of: $0)
            })
            let viewport = scroll.convert(scroll.bounds, to: window)
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX, "Focus lift must not clip at the agenda's leading edge.")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX)
        }
    }

    func testAgendaHidesOnlyPastDatesEvenWhenAFutureDateIsSelected() async throws {
        let suite = "UpcomingPresentationHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let today = Calendar.current.startOfDay(for: Date())
        let releases = [(-1, "Past movie"), (2, "Earlier future movie"), (10, "Selected future movie")].map { offset, title in
            let item = MediaItem(id: title, title: title, kind: .movie)
            return UpcomingRelease(id: title, titleKey: UpcomingRelease.titleKey(for: item), item: item,
                                   date: today.addingTimeInterval(Double(offset) * 86_400), datePrecision: .dateOnly,
                                   kind: .digital, interests: [.watchlist])
        }
        await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
        let window = try host(UpcomingAgenda(
            model: model, selectedDay: releases[2].date, minimumLastDayHeight: 0, contentWidth: 1600
        ).environment(\.plozzCardFocusStyle, .system))
        defer { close(window) }
        try await Task.sleep(for: .milliseconds(600))
        let labels = descendants(window).compactMap { ($0 as? NativePosterButton)?.accessibilityLabel }
        XCTAssertFalse(labels.contains { $0.contains("Past movie") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Earlier future movie") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("Selected future movie") }, "\(labels)")
    }

    func testCalendarShowsUntruncatedMonthAndAlignedUniformControls() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        for (locale, month) in [
            ("en_US", Calendar.current.date(byAdding: .day,
                                           value: Calendar.current.component(.day, from: today) == 1 ? 1 : 0,
                                           to: Calendar.current.dateInterval(of: .month, for: today)!.start)!),
            ("de_DE", Calendar.current.date(from: DateComponents(year: 2026, month: 8, day: 15))!)
        ] {
            let window = try host(
                UpcomingCalendar(selectedDay: .constant(month),
                                 interval: .init(start: month.addingTimeInterval(-31 * 86_400), duration: 150 * 86_400))
                    .environment(\.locale, Locale(identifier: locale))
                    .tint(ThemePalette.dark.primaryText)
            )
            defer { close(window) }
            try await Task.sleep(for: .milliseconds(600))
            let observations = try capture(window, name: "upcoming-calendar-\(locale)")
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let expected = month.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: locale)))
            XCTAssertTrue(text.contains(expected), text)
            XCTAssertFalse(text.contains("Today"), "Today is indicated on its date, not in a separate caption.")
            for day in ["11", "20", "21", "30"] {
                XCTAssertTrue(observations.contains { $0.topCandidates(1).first?.string == day }, text)
            }
            let controls = focusItems(in: window)
            let count = try XCTUnwrap(Calendar.current.range(of: .day, in: .month, for: month)).count
            XCTAssertEqual(controls.count, count + 3, "Each day, two month controls and Cancel must be focusable.")
            let dates = controls.sorted { $0.frame.minY < $1.frame.minY }.dropFirst(2).dropLast()
            let first = try XCTUnwrap(dates.first)
            XCTAssertGreaterThan(first.frame.height, 60)
            for date in dates {
                XCTAssertEqual(date.frame.width, first.frame.width, accuracy: 1)
                XCTAssertEqual(date.frame.height, first.frame.height, accuracy: 1)
            }
            let arrows = controls.sorted { $0.frame.minY < $1.frame.minY }.prefix(2).sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(arrows[0].frame.minX, try XCTUnwrap(dates.map(\.frame.minX).min()), accuracy: 1)
            XCTAssertEqual(arrows[1].frame.maxX, try XCTUnwrap(dates.map(\.frame.maxX).max()), accuracy: 1)
            for arrow in arrows {
                XCTAssertEqual(arrow.frame.width, first.frame.width, accuracy: 1)
                XCTAssertEqual(arrow.frame.height, first.frame.height, accuracy: 1)
            }
        }
    }

    func testPastOnlyFeedShowsEmptyStateAndFailedRefreshOffersRetry() async throws {
        let suite = "UpcomingPresentationHostedTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let today = Calendar.current.startOfDay(for: Date())
        let item = MediaItem(id: "past", title: "Past movie", kind: .movie)
        let release = UpcomingRelease(
            id: "past", titleKey: UpcomingRelease.titleKey(for: item), item: item,
            date: today.addingTimeInterval(-86_400), datePrecision: .dateOnly,
            kind: .digital, interests: [.watchlist]
        )
        let window = try host(PinnedUpcoming(model: model, interval: .init(start: today, duration: 90 * 86_400))
            .environment(\.locale, Locale(identifier: "en_US")))
        defer { close(window) }
        for failures in [0, 1] {
            await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
                UpcomingFeedSnapshot(releases: [release], failedSourceCount: failures)
            }
            try await Task.sleep(for: .milliseconds(600))
            let observations = try capture(window, name: "upcoming-past-only-\(failures)")
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            if failures == 0 {
                XCTAssertTrue(text.contains("Nothing upcoming yet"), text)
                XCTAssertFalse(text.contains("No matching releases"), text)
            } else {
                XCTAssertTrue(text.contains("load releases"), text)
                XCTAssertTrue(text.contains("Retry"), text)
            }
        }
    }

    private var previous: UIWindow?

    private func host(_ view: some View) throws -> UIWindow {
        try host(controller: UIHostingController(rootView: view
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark)))
    }

    private func host(controller: UIViewController) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }

    private func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "The expected native focus/layout did not arrive.", file: file, line: line)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private final class UpcomingFocusController: UIHostingController<AnyView> {
        var target: UIView?

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = descendants(window)
        var visited = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard visited.insert(ObjectIdentifier(container)).inserted else { continue }
            for item in container.focusItems(in: container.coordinateSpace.convert(window.bounds, from: window)) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView) { items[ObjectIdentifier(item)] = item }
            }
        }
        return Array(items.values)
    }

    private func capture(_ window: UIWindow, name: String) throws -> [VNRecognizedTextObservation] {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_UPCOMING_CAPTURE_DIR"] {
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = (1...31).map(String.init)
        request.recognitionLanguages = ["en-US", "de-DE"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results ?? []
    }
}

private struct PinnedUpcoming: View {
    let model: UpcomingFeedModel
    let interval: DateInterval
    @State private var selection = NavigationRailDestination.upcoming
    @State private var chrome = NavigationChromeModel()

    var body: some View {
        NavigationRailShell(
            profile: Profile(name: "Viewer"), entries: [],
            destinations: [.home, .upcoming], selection: $selection,
            onOpenProfileSwitcher: {}, chrome: chrome,
            content: NavigationStack { UpcomingView(model: model, interval: interval) },
            contentDestination: selection
        )
        .environment(chrome)
        .environment(\.plozzNavigationStyle, .rail)
    }
}
#endif
