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
    func testSelectionStaysDistinctFromFocusAndLegibleInBothCalendars() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let interval = DateInterval(
            start: try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: today)),
            end: try XCTUnwrap(calendar.date(byAdding: .month, value: 3, to: today))
        )
        for scheme in [ColorScheme.dark, .light] {
            for week in [true, false] {
                let content = week
                    ? AnyView(UpcomingWeekCalendar(
                        selectedDay: .constant(today), displayedWeek: .constant(today), interval: interval
                    ).frame(width: 1600))
                    : AnyView(UpcomingCalendar(selectedDay: .constant(today), interval: interval))
                let controller = UpcomingFocusController(rootView: AnyView(content
                    .padding(48)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.themePalette, scheme == .dark ? .dark : .light)
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: "en_US"))))
                let window = try host(controller: controller)
                defer { close(window) }
                let expectedCount = week ? 9 : try XCTUnwrap(calendar.range(of: .day, in: .month, for: today)).count + 3
                try await waitUntil { self.focusItems(in: window).count == expectedCount }
                let root = try XCTUnwrap(controller.view)
                let unsorted: [(item: any UIFocusItem, frame: CGRect)] = try focusItems(in: window).map {
                    ($0, try XCTUnwrap(NativeFocusRegion.frame(of: $0, in: root)))
                }
                let items = unsorted.sorted { left, right in
                    if abs(left.frame.midY - right.frame.midY) < 1 { return left.frame.midX < right.frame.midX }
                    return left.frame.midY < right.frame.midY
                }
                let dates = Array(items.dropFirst(week ? 1 : 2).dropLast())
                let index = week
                    ? (calendar.component(.weekday, from: today) - calendar.firstWeekday + 7) % 7
                    : calendar.component(.day, from: today) - 1
                let selected = dates[index].item
                let neighbor = dates[(index + 1) % dates.count].item
                let last = try XCTUnwrap(items.last)
                let arrow = week ? last.item : items[1].item
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                var restingSurface: Double?
                var selectionDifference: Double?
                for focused in [false, true] {
                    let target = focused ? selected : arrow
                    controller.target = target
                    system.requestFocusUpdate(to: controller)
                    system.updateFocusIfNeeded()
                    try await waitUntil {
                        guard let frame = NativeFocusRegion.frame(of: system.focusedItem, in: root),
                              let targetFrame = NativeFocusRegion.frame(of: target, in: root) else { return false }
                        return targetFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
                    }
                    try await Task.sleep(for: .milliseconds(600))
                    let image = snapshot(window)
                    try saveCapture(image, name: "upcoming-\(week ? "week" : "month")-today-\(scheme)-\(focused ? "focused" : "selected")")
                    let cgImage = try XCTUnwrap(image.cgImage)
                    let frame = window.convert(try XCTUnwrap(NativeFocusRegion.frame(of: selected, in: root)), from: root)
                    let scale = CGFloat(cgImage.width) / window.bounds.width
                    func samples(_ rect: CGRect) throws -> [Double] {
                        try luminances(cgImage, in: rect.applying(.init(scaleX: scale, y: scale)))
                    }
                    let ink: [Double] = try samples(CGRect(
                        x: frame.midX - 25, y: week ? frame.midY + 2 : frame.midY - 14,
                        width: 50, height: week ? 34 : 28
                    ))
                    let dark = ink[ink.count * 2 / 100]
                    let light = ink[ink.count * 98 / 100]
                    let contrast = (light + 0.05) / (dark + 0.05)
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(week ? "Week" : "Month"), \(scheme), focused: \(focused)")
                    func surface(_ bounds: CGRect) throws -> Double {
                        let values = try samples(CGRect(
                            x: bounds.minX + bounds.width * 0.8, y: bounds.midY, width: 4, height: 4
                        ))
                        return values.reduce(0, +) / Double(values.count)
                    }
                    if !focused {
                        let other = window.convert(try XCTUnwrap(NativeFocusRegion.frame(of: neighbor, in: root)), from: root)
                        let selectedSurface = try surface(frame)
                        let difference = abs(selectedSurface - (try surface(other)))
                        restingSurface = selectedSurface
                        selectionDifference = difference
                        XCTAssertGreaterThan(difference, 0.01, "Selection needs a visible background change.")
                        XCTAssertLessThan(difference, 0.2, "Selection must stay subdued rather than imitate focus.")
                    } else {
                        let focusDifference = abs(try surface(frame) - XCTUnwrap(restingSurface))
                        XCTAssertGreaterThan(focusDifference, try XCTUnwrap(selectionDifference) * 3,
                                             "Native focus must remain much stronger than selection.")
                    }
                }
            }
        }
    }

    func testWeeksFollowLocaleAndCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for (month, day, hours) in [(3, 8, 167), (11, 1, 169)] {
            calendar.firstWeekday = 1
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let week = UpcomingCalendarWeek(containing: date, calendar: calendar)
            XCTAssertEqual(week.days.count, 7)
            XCTAssertEqual(Set(week.days.map { calendar.component(.weekday, from: $0) }), Set(1...7))
            XCTAssertTrue(week.days.allSatisfy { calendar.component(.hour, from: $0) == 0 })
            XCTAssertEqual(week.next.timeIntervalSince(week.days[0]), Double(hours * 3600))
            calendar.firstWeekday = 2
            let mondayWeek = UpcomingCalendarWeek(containing: date, calendar: calendar)
            XCTAssertEqual(calendar.component(.weekday, from: mondayWeek.days[0]), 2)
            XCTAssertEqual(mondayWeek.days[6], date)
        }
    }

    func testWeekNavigationStopsAtAvailableIntervalAndCrossesYears() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        calendar.firstWeekday = 1
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 9)))
        let interval = DateInterval(start: start, end: end)
        let first = UpcomingCalendarWeek(containing: start, calendar: calendar)
        XCTAssertFalse(first.canMoveBackward(in: interval))
        XCTAssertTrue(first.canMoveForward(in: interval))
        XCTAssertEqual(calendar.component(.year, from: first.days[0]), 2026)
        XCTAssertEqual(calendar.component(.year, from: first.days[6]), 2027)
        let last = UpcomingCalendarWeek(containing: first.next, calendar: calendar)
        XCTAssertTrue(last.canMoveBackward(in: interval))
        XCTAssertFalse(last.canMoveForward(in: interval))
        XCTAssertEqual(last.previous, first.days[0])
        XCTAssertFalse(first.canMoveForward(in: .init(start: start, end: first.next)),
                       "The available interval's end is exclusive.")
    }

    func testWeekStripHasSevenNativeDatesAndFitsRTL() async throws {
        for (locale, direction) in [("en_US", LayoutDirection.leftToRight), ("de_DE", .leftToRight), ("ar", .rightToLeft)] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: locale)
            let selected = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 30)))
            let interval = DateInterval(
                start: try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: selected)),
                end: try XCTUnwrap(calendar.date(byAdding: .month, value: 1, to: selected))
            )
            let controller = UpcomingFocusController(rootView: AnyView(
                UpcomingWeekCalendar(
                    selectedDay: .constant(selected), displayedWeek: .constant(selected), interval: interval
                )
                    .environment(\.calendar, calendar)
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.layoutDirection, direction)
                    .environment(\.themePalette, .dark)
                    .environment(\.colorScheme, .dark)
                    .frame(width: 1600)
            ))
            let window = try host(controller: controller)
            defer { close(window) }
            try await waitUntil { self.focusItems(in: window).count == 9 }
            let root = try XCTUnwrap(window.rootViewController?.view)
            let frames = try focusItems(in: window).map { item in
                try XCTUnwrap(NativeFocusRegion.frame(of: item, in: root))
            }.sorted { $0.minX < $1.minX }
            let dates = Array(frames.dropFirst().dropLast())
            XCTAssertEqual(dates.count, 7)
            for arrow in [try XCTUnwrap(frames.first), try XCTUnwrap(frames.last)] {
                XCTAssertGreaterThanOrEqual(arrow.width, 64, "Glass must surround the control, not hug the thin chevron.")
                XCTAssertGreaterThanOrEqual(arrow.height, 80)
            }
            let first = try XCTUnwrap(dates.first)
            for frame in dates {
                XCTAssertEqual(frame.width, first.width, accuracy: 1)
                XCTAssertEqual(frame.midY, first.midY, accuracy: 1)
                XCTAssertTrue(window.bounds.contains(frame))
                XCTAssertGreaterThan(frame.height, 60)
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                XCTAssertLessThan(left.maxX, right.minX, "Native week controls must not overlap.")
            }
            _ = try capture(window, name: "upcoming-week-\(locale)")
            if direction == .leftToRight {
                let target = try XCTUnwrap(focusItems(in: window).max {
                    (NativeFocusRegion.frame(of: $0, in: root)?.midX ?? 0)
                        < (NativeFocusRegion.frame(of: $1, in: root)?.midX ?? 0)
                })
                let targetFrame = try XCTUnwrap(NativeFocusRegion.frame(of: target, in: root))
                let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
                controller.target = target
                system.requestFocusUpdate(to: controller)
                system.updateFocusIfNeeded()
                try await waitUntil {
                    guard let frame = NativeFocusRegion.frame(of: system.focusedItem, in: root) else { return false }
                    return targetFrame.contains(CGPoint(x: frame.midX, y: frame.midY))
                }
                try await Task.sleep(for: .milliseconds(600))
                _ = try capture(window, name: "upcoming-week-arrow-focused-\(locale)")
            }
        }
    }

    func testDateSelectionFocusesItsFirstReleaseAfterScrolling() async throws {
        let suite = "UpcomingWeekFocus.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = UpcomingFeedModel(defaults: defaults)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let releases = (0..<12).map { offset in
            let item = MediaItem(id: "week-\(offset)", title: "Week release \(offset)", kind: .movie)
            return UpcomingRelease(
                id: item.id, titleKey: UpcomingRelease.titleKey(for: item), item: item,
                date: calendar.date(byAdding: .day, value: offset, to: today)!,
                datePrecision: .dateOnly, kind: .digital, interests: [.watchlist]
            )
        }
        await model.refresh(scope: UUID().uuidString, namespace: nil, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
        let destination = releases[9]
        let request = UUID()
        let jump = UpcomingDateJumpState(day: today)
        var handled: UUID?
        var weekFrame = CGRect.zero
        let window = try host(
            ScrollViewReader { proxy in
                ScrollView {
                    VStack {
                        UpcomingWeekCalendar(
                            selectedDay: Binding(get: { jump.day }, set: { jump.day = $0 }),
                            displayedWeek: .constant(today),
                            interval: .init(start: today, end: calendar.date(byAdding: .month, value: 3, to: today)!)
                        )
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { weekFrame = $0 }
                        UpcomingAgenda(
                            model: model, selectedDay: jump.day, minimumLastDayHeight: 900, contentWidth: 1600,
                            focusRequest: jump.request, onFocusRequestHandled: { handled = $0 }
                        )
                    }
                }
                .task(id: jump.request) {
                    guard jump.request != nil else { return }
                    await Task.yield()
                    proxy.scrollTo(jump.day, anchor: .top)
                }
            }
            .environment(\.plozzCardStyle, .borderless)
            .environment(\.plozzCardFocusStyle, .system)
        )
        defer { close(window) }
        try await waitUntil { weekFrame.height > 0 && UIFocusSystem.focusSystem(for: window)?.focusedItem != nil }
        jump.day = destination.date
        jump.request = request
        try await waitUntil {
            let focused = UIFocusSystem.focusSystem(for: window)?.focusedItem as? NativePosterButton
            return focused?.accessibilityLabel == destination.item.title && handled == request
                && weekFrame.height > 0 && weekFrame.maxY < window.bounds.minY
        }
        _ = try capture(window, name: "upcoming-week-date-jump")
        XCTAssertEqual(model.visibleReleases.count, releases.count, "A date jump must not filter the agenda.")
    }

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
        let root = try XCTUnwrap(controller.view)
        func firstHeaderControl() -> (any UIFocusItem)? {
            focusItems(in: window).filter {
                guard let frame = NativeFocusRegion.frame(of: $0, in: root) else { return false }
                return frame.midX > root.bounds.midX
            }.min {
                (NativeFocusRegion.frame(of: $0, in: root)?.midY ?? .infinity)
                    < (NativeFocusRegion.frame(of: $1, in: root)?.midY ?? .infinity)
            }
        }
        try await waitUntil { firstHeaderControl() != nil }
        let headerControl = try XCTUnwrap(firstHeaderControl())
        let headerFrame = try XCTUnwrap(NativeFocusRegion.frame(of: headerControl, in: root))
        XCTAssertLessThan(headerFrame.maxY, first.convert(first.bounds, to: root).minY)
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
        let scrolledHeader = try XCTUnwrap(NativeFocusRegion.frame(of: headerControl, in: root))
        XCTAssertLessThan(scrolledHeader.maxY, agenda.convert(agenda.bounds, to: root).minY,
                          "Calendar and Filters must scroll away with the title, not remain pinned.")
        _ = try capture(window, name: "upcoming-header-scrolled-away")
        controller.target = headerControl
        system.requestFocusUpdate(to: controller)
        system.updateFocusIfNeeded()
        try await waitUntil {
            guard let focused = NativeFocusRegion.frame(of: system.focusedItem, in: root),
                  let returned = NativeFocusRegion.frame(of: headerControl, in: root) else { return false }
            return returned.contains(CGPoint(x: focused.midX, y: focused.midY))
                && agenda.convert(agenda.bounds, to: root).contains(returned)
        }
        _ = try capture(window, name: "upcoming-header-focus-return")
    }

    func testPinnedUpcomingStartsAtWeekAndKeepsFocusedReleaseBelowItsHeading() async throws {
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
            let controller = UpcomingFocusController(rootView: AnyView(
                PinnedUpcoming(model: model, interval: .init(start: today, duration: 90 * 86_400))
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.plozzCardStyle, style)
                .environment(\.plozzCardFocusStyle, .system)
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)))
            let window = try host(controller: controller)
            defer { close(window) }
            let system = try XCTUnwrap(UIFocusSystem.focusSystem(for: window))
            try await waitUntil {
                let firstEntry = self.descendants(window).compactMap { $0 as? NavigationEntryFocusRegionView }
                    .filter { $0.preference == .content }
                    .min { $0.convert($0.bounds, to: window).minY < $1.convert($1.bounds, to: window).minY }
                return firstEntry.map { NativeFocusRegion.contains(system.focusedItem, in: $0) } == true
            }
            try await Task.sleep(for: .milliseconds(600))
            let initial = try capture(window, name: "upcoming-week-entry-\(style.rawValue)")
            let year = Date().formatted(.dateTime.year())
            XCTAssertTrue(initial.contains { $0.topCandidates(1).first?.string.contains(year) == true },
                          "The week range must remain visible on entry.")
            let first = try XCTUnwrap(descendants(window).first {
                $0.canBecomeFocused && $0.accessibilityLabel == item.title
            })
            controller.target = first
            system.requestFocusUpdate(to: controller)
            system.updateFocusIfNeeded()
            try await waitUntil { system.focusedItem === first }
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
        var target: (any UIFocusEnvironment)?

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

    private func snapshot(_ window: UIWindow) -> UIImage {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
    }

    private func capture(_ window: UIWindow, name: String) throws -> [VNRecognizedTextObservation] {
        let image = snapshot(window)
        try saveCapture(image, name: name)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = (1...31).map(String.init)
        request.recognitionLanguages = ["en-US", "de-DE"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results ?? []
    }

    private func saveCapture(_ image: UIImage, name: String) throws {
        if let directory = ProcessInfo.processInfo.environment["PLOZZ_UPCOMING_CAPTURE_DIR"] {
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func luminances(_ image: CGImage, in rect: CGRect) throws -> [Double] {
        let crop = try XCTUnwrap(image.cropping(to: rect.integral))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try pixels.withUnsafeMutableBytes {
            let context = try XCTUnwrap(CGContext(
                data: $0.baseAddress, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        func linear(_ byte: UInt8) -> Double {
            let value = Double(byte) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return stride(from: 0, to: pixels.count, by: 4).map {
            0.2126 * linear(pixels[$0]) + 0.7152 * linear(pixels[$0 + 1]) + 0.0722 * linear(pixels[$0 + 2])
        }.sorted()
    }
}

@MainActor
@Observable
private final class UpcomingDateJumpState {
    var day: Date
    var request: UUID?
    init(day: Date) { self.day = day }
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
