#if os(tvOS)
import CoreModels
import CoreUI
@testable import FeatureHomeCore
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShell

@MainActor
final class UpcomingPresentationHostedTests: XCTestCase {
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
                                date: today.addingTimeInterval(2 * 86_400), datePrecision: .dateOnly,
                                kind: .digital, interests: [.watchlist])
            ])
        }
        let window = try host(PinnedUpcoming(model: model, interval: .init(start: today, duration: 90 * 86_400)))
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
        _ = try capture(window, name: "upcoming-first-focus")
    }

    func testCalendarShowsUntruncatedMonthAndTodayAlongsideSingleLineDates() async throws {
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
            if locale == "en_US" { XCTAssertTrue(text.contains("Today"), text) }
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
        }
    }

    private var previous: UIWindow?

    private func host(_ view: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView: view
            .environment(\.themePalette, .dark)
            .environment(\.colorScheme, .dark))
        window.makeKeyAndVisible()
        return window
    }

    private func close(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
        previous?.makeKeyAndVisible()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
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
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
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
        .environment(\.plozzCardStyle, .borderless)
    }
}
#endif
