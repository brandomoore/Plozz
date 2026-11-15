import AppRuntime
import CoreModels
import CoreUI
@testable import FeatureHomeCore
import FeatureAuth
import MetadataKit
import SwiftUI
import UIKit
import Vision
#if os(tvOS)
@testable import AppShell
import FeatureHome
#else
@testable import AppShelliOS
#endif

struct UpcomingCaptureFixture: View {
    @State private var fixture = UpcomingCaptureState()
    @State private var isLoaded = false
    #if os(tvOS)
    @State private var tvSelection: NavigationRailDestination =
        ProcessInfo.processInfo.arguments.contains("--capture-home") ? .home : .upcoming
    #endif
    private let palette = ThemePalette.dark

    var body: some View {
        Group {
            #if os(tvOS)
            TopBarNavigation(
                destinations: [.home, .upcoming, .watchlist, .search],
                selection: $tvSelection, preventsAccidentalExit: true,
                content: { destination, _ in
                    AnyView(page(home: destination == .home))
                },
                label: { destination in
                    switch destination {
                    case .home: AnyView(Label("Home", systemImage: "house"))
                    case .upcoming: AnyView(Label("Upcoming", systemImage: "calendar"))
                    case .watchlist: AnyView(Label("Watchlist", systemImage: "bookmark"))
                    default: AnyView(Label("Search", systemImage: "magnifyingglass"))
                    }
                },
                profile: Profile(name: "Viewer"), onOpenProfileSwitcher: {}
            )
            #else
            if isLoaded {
                fixture.shell
                    .environment(fixture.app)
                    .environment(fixture.trailer)
                    .environment(fixture.sidebar)
                    .environment(\.plozzMetrics, .touch(density: .standard))
            } else {
                Color.clear
            }
            #endif
        }
        .environment(\.themePalette, palette)
        .environment(\.plozzCardStyle, .borderless)
        .preferredColorScheme(.dark)
        .tint(palette.primaryText)
        .environment(\.plozzReduceTransparency, ProcessInfo.processInfo.arguments.contains("--capture-opaque"))
        .task {
            await fixture.load()
            isLoaded = true
            #if os(iOS)
            do {
                try await Task.sleep(for: .milliseconds(500))
                fixture.app.screenshotDirector.tab =
                    ProcessInfo.processInfo.arguments.contains("--capture-home") ? "home" : "upcoming"
                try await prepareCapture()
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Upcoming capture failed: \(error)")
            }
            #endif
        }
    }

    #if os(iOS)
    @MainActor
    private func prepareCapture() async throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--capture-elasticity") {
            try await observeElasticGestures()
            return
        }
        let showsCalendar = arguments.contains("--capture-calendar") || arguments.contains("--capture-selection")
        let collapsesCalendar = arguments.contains("--capture-calendar-collapsed")
        let resizesCalendar = arguments.contains("--capture-calendar-resize")
        let narrow = arguments.contains("--capture-narrow")
        let thirty = arguments.contains("--capture-thirty")
        let progressive = arguments.contains("--capture-progressive")
        guard arguments.contains("--capture-scrolled") || arguments.contains("--capture-landscape")
            || arguments.contains("--capture-dense") || showsCalendar || collapsesCalendar
            || resizesCalendar || narrow || thirty || progressive else { return }
        try await Task.sleep(for: .seconds(1))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            preconditionFailure("Upcoming capture has no window")
        }
        precondition(fixture.home.upcoming.failedSourceCount == 0, "Preview data was replaced by a live refresh")
        if arguments.contains("--capture-landscape") || narrow {
            let size = narrow ? CGSize(width: 700, height: 900) : CGSize(width: 1194, height: 834)
            window.frame = CGRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(500))
            precondition(window.bounds.size == size, "Test window was not resized")
        }
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap(descendants)
        }
        func agendaScrollView() -> UIScrollView? {
            let candidates = descendants(window).compactMap { $0 as? UIScrollView }.filter { candidate in
                guard candidate.bounds.height > 450, candidate.bounds.width > 200 else { return false }
                var ancestor: UIView? = candidate
                while let view = ancestor {
                    if view.isHidden || view.alpha < 0.01 { return false }
                    ancestor = view.superview
                }
                return true
            }
            precondition(candidates.count <= 1, "Upcoming capture must identify one visible agenda")
            return candidates.first
        }
        func controllers(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap(controllers)
        }
        func hideSidebar() {
            for controller in window.rootViewController.map(controllers) ?? [] {
                (controller as? UITabBarController)?.sidebar.isHidden = true
            }
        }
        if arguments.contains("--capture-landscape") || narrow || thirty {
            hideSidebar()
            try await Task.sleep(for: .milliseconds(500))
        }
        var barItems: [UIBarButtonItem] = []
        for controller in window.rootViewController.map(controllers) ?? [] {
            let item = controller.navigationItem
            barItems += item.leftBarButtonItems ?? []
            barItems += item.rightBarButtonItems ?? []
            let groups = item.leadingItemGroups + item.centerItemGroups + item.trailingItemGroups
            barItems += groups.flatMap(\.barButtonItems)
        }
        func activateCalendar() {
            let items = (window.rootViewController.map(controllers) ?? []).flatMap { controller in
                let item = controller.navigationItem
                return (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
            }
            guard let button = items.first(where: { $0.title == "Calendar" }), let action = button.action else {
                preconditionFailure("Upcoming calendar must expose its native action")
            }
            precondition(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil),
                         "Upcoming calendar action was not handled")
        }
        func datePicker() -> UIDatePicker? {
            descendants(window).compactMap { $0 as? UIDatePicker }.first
        }
        let inlinePicker = datePicker()
        if arguments.contains("--capture-landscape") && !narrow {
            precondition(inlinePicker != nil, "Wide Upcoming must show the side calendar")
        } else if narrow || window.bounds.width < 600 {
            precondition(inlinePicker == nil, "Compact Upcoming must keep the calendar in the toolbar")
        }
        let inlineFrame = inlinePicker.map { $0.convert($0.bounds, to: window) }
        for title in ["Calendar", "Filters"] {
            precondition(barItems.contains { $0.title == title }, "Missing Upcoming action: \(title)")
        }
        precondition(!barItems.contains { $0.title == "Today" }, "Upcoming must not show a Today toolbar action")
        guard let navigationBar = descendants(window).compactMap({ $0 as? UINavigationBar }).first(where: {
            guard !$0.isHidden, $0.alpha > 0, $0.bounds.width > 0, let item = $0.topItem else {
                return false
            }
            let actions = (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
            return ["Calendar", "Filters"].allSatisfy { title in actions.contains { $0.title == title } }
        }) else {
            preconditionFailure("Upcoming actions must have a visible native navigation bar")
        }
        let before = navigationBar.convert(navigationBar.bounds, to: window)
        precondition(before.maxY <= window.safeAreaInsets.top + 64, "Upcoming toolbar occupies a second row")
        func renderedText() throws -> [(String, CGRect)] {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image.cgImage!).perform([request])
            return (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                observation.topCandidates(1).first.map { ($0.string, observation.boundingBox) }
            }
        }
        if progressive {
            func save(_ name: String) throws {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                try image.pngData()!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
            }
            precondition(fixture.home.upcoming.isLoading, "The initial loading state must be exercised")
            let loading = try renderedText()
            guard let label = loading.first(where: { $0.0 == "Updating releases" })?.1 else {
                preconditionFailure("The loading indicator must be visible")
            }
            precondition((1 - label.maxY) * window.bounds.height > before.maxY + 80,
                         "The loading indicator must not overlap the navigation bar")
            try save("upcoming-progressive-loading.png")
            await fixture.phases.advance(to: 1)
            for _ in 0..<100 where fixture.home.upcoming.releases.count != 1 {
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(fixture.home.upcoming.releases.count == 1, "Capture must exercise the first publication alone")
            try await Task.sleep(for: .milliseconds(250))
            func assertTodayVisible() throws {
                let text = try renderedText()
                guard let today = text.first(where: { $0.0 == "Today" })?.1 else {
                    preconditionFailure("Upcoming must remain at Today as earlier dates arrive")
                }
                let top = (1 - today.maxY) * window.bounds.height
                precondition(top >= before.maxY + 8 && top <= before.maxY + 36,
                             "The first date must begin below the navigation bar")
            }
            try save("upcoming-progressive-first.png")
            try assertTodayVisible()
            await fixture.phases.advance(to: 2)
            for _ in 0..<100 where fixture.home.upcoming.isLoading || fixture.home.upcoming.releases.count != fixture.releases.count {
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(!fixture.home.upcoming.isLoading && fixture.home.upcoming.releases.count == fixture.releases.count,
                         "Capture must finish loading the historical feed")
            try await Task.sleep(for: .milliseconds(250))
            try save("upcoming-progressive-complete.png")
            try assertTodayVisible()
        }
        if arguments.contains("--capture-dense") {
            let text = try renderedText()
            guard let today = text.first(where: { $0.0 == "Today" })?.1 else {
                preconditionFailure("Dense preview must start at Today")
            }
            guard let episode = text.first(where: { $0.0.contains("S38") && $0.0.contains("E6") })?.1 else {
                preconditionFailure("Missing episode caption")
            }
            // The subtitle distinguishes the caption from title lettering inside poster artwork.
            guard let first = text.filter({ $0.0.hasPrefix("The Simps") && $0.1.maxY < today.minY })
                .map(\.1).min(by: { abs($0.minY - episode.maxY) < abs($1.minY - episode.maxY) }) else {
                preconditionFailure("Missing Upcoming poster caption: The Simpsons")
            }
            let frames = [first] + ["Severance", "Silo"].map { title in
                guard let frame = text.filter({ $0.0 == title && $0.1.maxY < today.minY })
                    .map(\.1).min(by: { abs($0.midY - first.midY) < abs($1.midY - first.midY) }) else {
                    preconditionFailure("Missing Upcoming poster caption: \(title)")
                }
                return frame
            }
            let agenda = agendaScrollView()!
            let pageInset = PlozziOSMediaRailLayout.pageInset(
                for: window.traitCollection.horizontalSizeClass == .regular ? .regular : .compact
            )
            let metrics = posterMetrics(
                viewport: agenda.bounds.width, inset: pageInset,
                compact: window.traitCollection.horizontalSizeClass == .compact
            )
            let inset = PlozziOSMediaRailLayout.artworkAlignedInset(pageInset, metrics: metrics, cardStyle: .borderless)
            let layout = PlozziOSPosterGridLayout(
                contentWidth: agenda.bounds.width - 2 * inset, metrics: metrics, cardStyle: .borderless
            )
            let pitch = layout.metrics.cardSlotWidth(for: .poster, cardStyle: .borderless) + layout.spacing
            let actualPitch = (frames[1].minX - frames[0].minX) * window.bounds.width
            precondition(abs(frames[1].midY - frames[0].midY) < 0.006, "Adjacent posters must share a row")
            precondition(abs(actualPitch - pitch) < 3, "Poster spacing \(actualPitch) differs from shared spacing \(pitch)")
            if layout.columns == 2 {
                precondition(frames[2].midY < frames[0].midY, "Busy dates must wrap on a phone")
                precondition(abs(frames[2].minX - frames[0].minX) < 0.006, "Wrapped posters must align")
            } else {
                precondition(abs(frames[2].midY - frames[0].midY) < 0.006, "The third poster must remain on the first row")
            }
            precondition(text.contains { $0.0.contains("3 episodes") }, "Missing grouped episode count")
        }
        if arguments.contains("--capture-scrolled") {
            guard let scroll = agendaScrollView(), scroll.contentSize.height > scroll.bounds.height + 250 else {
                preconditionFailure("Upcoming capture requires a scrollable agenda")
            }
            let offset = thirty
                ? scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                : scroll.contentOffset.y + 250
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(500))
            if let inlinePicker, let inlineFrame {
                precondition(abs(inlinePicker.convert(inlinePicker.bounds, to: window).minY - inlineFrame.minY) < 2,
                             "Side calendar must stay fixed while the agenda scrolls")
            }
            precondition(abs(navigationBar.convert(navigationBar.bounds, to: window).minY - before.minY) < 2,
                         "Upcoming actions moved while scrolling")
            precondition(!descendants(window).contains(where: {
                $0.accessibilityIdentifier == "upcoming.navigationBackdrop"
            }), "Upcoming must not stack a material overlay over the system scroll edge")
            if #available(iOS 26.0, *) {
                precondition(
                    scroll.topEdgeEffect.isHidden == arguments.contains("--capture-opaque"),
                    "Upcoming must respect the shell's scroll-edge transparency policy"
                )
                precondition(scroll.topEdgeEffect.style == .soft, "Upcoming must use a soft native scroll edge")
                if arguments.contains("--capture-edge-comparison") {
                    let originalHidden = scroll.topEdgeEffect.isHidden
                    defer { scroll.topEdgeEffect.isHidden = originalHidden }
                    for enabled in [true, false] {
                        scroll.topEdgeEffect.isHidden = !enabled
                        try await Task.sleep(for: .milliseconds(500))
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                        }
                        let path = URL(fileURLWithPath: NSTemporaryDirectory())
                            .appendingPathComponent(enabled ? "upcoming-edge-enabled.png" : "upcoming-edge-disabled.png")
                        try image.pngData()!.write(to: path)
                    }
                }
            }
        }
        if showsCalendar {
            if inlinePicker == nil {
                activateCalendar()
                try await Task.sleep(for: .seconds(1))
            }
            guard let picker = datePicker() else {
                preconditionFailure("Upcoming calendar did not present a native date picker")
            }
            precondition(picker.bounds.width >= 280 && picker.bounds.width <= 400, "Unexpected calendar width")
            precondition(picker.bounds.height > 250 && picker.bounds.height < 450, "Unexpected calendar height")
            let frame = picker.convert(picker.bounds, to: window)
            precondition(window.bounds.contains(frame), "Calendar extends outside the window")
            if arguments.contains("--capture-selection") {
                guard let agenda = agendaScrollView(), agenda.contentSize.height > agenda.bounds.height + 250 else {
                    preconditionFailure("Calendar selection capture requires a scrollable agenda")
                }
                let previousOffset = agenda.contentOffset.y
                let day = Calendar.current.date(byAdding: .day, value: 1, to: picker.date)!
                picker.setDate(day, animated: false)
                picker.sendActions(for: .valueChanged)
                try await Task.sleep(for: .seconds(1))
                precondition((picker.window != nil) == (inlinePicker != nil),
                             "Selection must keep an inline calendar open and dismiss a popover")
                precondition(agenda.contentOffset.y > previousOffset + 100, "Choosing tomorrow must scroll the agenda")
            }
        }
        if collapsesCalendar || resizesCalendar {
            guard let inlinePicker, let agenda = agendaScrollView(),
                  agenda.contentSize.height > agenda.bounds.height + 250 else {
                preconditionFailure("Calendar toggle capture requires an inline picker and scrollable agenda")
            }
            let expandedWidth = agenda.bounds.width
            let selected = Calendar.current.date(byAdding: .day, value: thirty ? 0 : 1, to: inlinePicker.date)!
            inlinePicker.setDate(selected, animated: false)
            inlinePicker.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(500))
            for expanded in [false, true, false] {
                activateCalendar()
                try await Task.sleep(for: .milliseconds(500))
                precondition((datePicker() != nil) == expanded, "Toolbar must hide and reopen the side calendar")
                if let picker = datePicker() {
                    precondition(Calendar.current.isDate(picker.date, inSameDayAs: selected), "Reopening lost the selected date")
                    precondition(abs(agenda.bounds.width - expandedWidth) < 2,
                                 "Reopening must restore agenda width \(expandedWidth), not \(agenda.bounds.width)")
                } else {
                    precondition(agenda.bounds.width > expandedWidth + 300, "Minimizing must return space to the agenda")
                }
            }
            if resizesCalendar {
                let originalFrame = window.frame
                window.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
                try await Task.sleep(for: .milliseconds(500))
                precondition(datePicker() == nil, "Narrowing must not automatically present a calendar")
                activateCalendar()
                try await Task.sleep(for: .milliseconds(500))
                guard let popoverPicker = datePicker() else {
                    preconditionFailure("Narrow iPad must present a native calendar popover")
                }
                precondition(Calendar.current.isDate(popoverPicker.date, inSameDayAs: selected), "Resizing lost the selected date")
                window.frame = originalFrame
                try await Task.sleep(for: .milliseconds(500))
                hideSidebar()
                try await Task.sleep(for: .seconds(1))
                precondition(datePicker() == nil, "Widening must dismiss the popover without undoing manual minimization")
                activateCalendar()
                try await Task.sleep(for: .milliseconds(500))
                guard let restored = datePicker() else {
                    preconditionFailure("Wide calendar must reopen after resizing")
                }
                precondition(Calendar.current.isDate(restored.date, inSameDayAs: selected), "Restoring lost the selected date")
            }
        }
        if thirty {
            let releases = fixture.home.upcoming.visibleReleases.filter { Calendar.current.isDateInToday($0.date) }
            precondition(releases.count == 30 && Set(releases.map(\.id)).count == 30,
                         "Busy-day preview must contain exactly thirty distinct cards")
            precondition(releases.first?.item.title == "01. The Simpsons" && releases.last?.item.title == "30. Foundation",
                         "Numbered preview cards must retain their reading order")
            let text = try renderedText()
            let expected = arguments.contains("--capture-scrolled") ? "30." : "01."
            precondition(text.contains { $0.0.hasPrefix(expected) }, "Busy-day preview did not render \(expected)")
            if !arguments.contains("--capture-scrolled") {
                guard let today = text.first(where: { $0.0 == "Today" })?.1 else {
                    preconditionFailure("Resizing must retain the visible Today heading")
                }
                let captions = text.filter { $0.1.maxY < today.minY }
                let agenda = agendaScrollView()!
                let frame = agenda.convert(agenda.bounds, to: window)
                let inset = PlozziOSMediaRailLayout.pageInset(
                    for: window.traitCollection.horizontalSizeClass == .regular ? .regular : .compact
                )
                let metrics = posterMetrics(
                    viewport: frame.width, inset: inset,
                    compact: window.traitCollection.horizontalSizeClass == .compact
                )
                let layout = PlozziOSPosterGridLayout(
                    contentWidth: frame.width - 2 * PlozziOSMediaRailLayout.artworkAlignedInset(
                        inset, metrics: metrics, cardStyle: .borderless
                    ), metrics: metrics, cardStyle: .borderless
                )
                if window.bounds.width >= 375 && window.bounds.width < 600 {
                    precondition(layout.columns == 3, "Phone Upcoming must fit three posters like Home")
                }
                let firstFrame = captions.first { $0.0.hasPrefix("01.") }!.1
                let lastPrefix = String(format: "%02d.", layout.columns)
                let lastFrame = captions.first { $0.0.hasPrefix(lastPrefix) }!.1
                let nextPrefix = String(format: "%02d.", layout.columns + 1)
                let nextFrame = captions.first { $0.0.hasPrefix(nextPrefix) }!.1
                precondition(abs(firstFrame.midY - lastFrame.midY) < 0.006, "The complete first row must remain aligned")
                precondition(nextFrame.midY < firstFrame.midY && abs(nextFrame.minX - firstFrame.minX) < 0.006,
                             "The next poster must wrap to the left edge of the following row")
                let first = firstFrame.minX * window.bounds.width
                let last = lastFrame.minX * window.bounds.width
                let left = first - layout.metrics.posterCaptionHorizontalInset - frame.minX
                let right = frame.maxX - (last - layout.metrics.posterCaptionHorizontalInset + layout.metrics.posterWidth)
                precondition(abs(left - inset) < 3 && abs(right - inset) < 3,
                             "Poster edge insets must be equal: left=\(left), right=\(right), expected=\(inset)")
                if let picker = datePicker() {
                    let gap = picker.convert(picker.bounds, to: window).minX - (frame.maxX - right)
                    precondition(abs(gap - left) < 3,
                                 "The calendar gutter must match the page inset: gap=\(gap), left=\(left)")
                }
                guard let detent = descendants(agenda).compactMap({ $0 as? UpcomingScrollProbe.Probe })
                    .first(where: { $0.role == .container })?.detent,
                      let nativeDelegate = agenda.delegate, let todayOffset = detent.todayOffset else {
                    preconditionFailure("Upcoming must attach its native Today detent")
                }
                precondition(abs(todayOffset - agenda.contentOffset.y) < 2,
                             "The Today detent must match the initial native date position: \(todayOffset), \(agenda.contentOffset.y)")
                let horizontalOffset = agenda.contentOffset.x
                for delta: CGFloat in [20, 40, 80, 40, 0] {
                    agenda.setContentOffset(CGPoint(x: horizontalOffset, y: todayOffset + delta), animated: false)
                    try await Task.sleep(for: .milliseconds(150))
                    precondition(agenda.delegate === nativeDelegate, "SwiftUI must retain its native scroll delegate")
                    precondition(abs((detent.todayOffset ?? .infinity) - todayOffset) < 2,
                                 "Native scrolling must retain the Today content coordinate")
                }
                if progressive {
                    agenda.contentOffset.y = todayOffset - 300
                    nativeDelegate.scrollViewWillBeginDragging?(agenda)
                    for _ in 0..<60 where detent.phase != .interacting {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    precondition(detent.phase == .interacting, "The native drag must reach SwiftUI")
                    agenda.contentOffset.y = todayOffset - 30
                    var target = CGPoint(x: horizontalOffset, y: todayOffset - 300)
                    nativeDelegate.scrollViewWillEndDragging?(
                        agenda, withVelocity: CGPoint(x: 0, y: 0.6), targetContentOffset: &target
                    )
                    precondition(abs(target.y - todayOffset) < 1, "Native release must select Today")
                    nativeDelegate.scrollViewDidEndDragging?(agenda, willDecelerate: true)
                    for _ in 0..<60 where detent.phase == .interacting {
                        try await Task.sleep(for: .milliseconds(16))
                    }
                    agenda.setContentOffset(target, animated: true)
                    var settleOffsets = [agenda.contentOffset.y]
                    for _ in 0..<60 where abs(agenda.contentOffset.y - todayOffset) >= 1 || detent.phase != .idle {
                        try await Task.sleep(for: .milliseconds(16))
                        settleOffsets.append(agenda.contentOffset.y)
                    }
                    precondition(abs(agenda.contentOffset.y - todayOffset) < 1 && detent.phase == .idle,
                                 "The native settle must return to Today: offsets=\(settleOffsets), today=\(todayOffset), anchor=\(String(describing: detent.todayOffset)), phase=\(detent.phase)")
                    precondition(agenda.delegate === nativeDelegate, "Native settling must preserve SwiftUI's delegate")
                    precondition(abs(agenda.contentOffset.x - horizontalOffset) < 0.5,
                                 "Native settling must preserve the horizontal page inset")
                    FileHandle.standardOutput.write(Data("Upcoming native target and animation verified with injected delegate events\n".utf8))
                }
                let top = (1 - today.maxY) * window.bounds.height
                precondition(top >= before.maxY + 8 && top <= before.maxY + 36,
                             "Resizing must keep Today below the toolbar")
            }
            if arguments.contains("--capture-scrolled") {
                precondition(text.contains { $0.0.hasPrefix("A saved") },
                             "The following date must remain reachable; visible captions: \(text.map(\.0))")
            }
            FileHandle.standardOutput.write(Data("Upcoming thirty-card preview verified\n".utf8))
        }
        if arguments.contains("--capture-landscape") || narrow {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                precondition(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true), "Could not render test window")
            }
            let path = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(narrow ? "upcoming-narrow.png" : "upcoming-landscape.png")
            try image.pngData()!.write(to: path)
        }
        FileHandle.standardOutput.write(Data("Upcoming capture ready\n".utf8))
    }

    @MainActor
    private func observeElasticGestures() async throws {
        struct Evidence: Encodable {
            var pull: Double = 0
            var held: Double = 0
            var offset: Double = 0
            var tensionCount = 0
            var minimumTension: Double = 1
            var maximumTension: Double = 0
            var pops = 0
            var catches = 0
            var returnFrames = 0
            var returnTravel: Double = 0
            var returnModelDrift: Double = 0
            var releaseFrames = 0
        }
        try await Task.sleep(for: .seconds(1))
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else {
            preconditionFailure("Upcoming gesture fixture has no window")
        }
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        guard let probe = descendants(window).compactMap({ $0 as? UpcomingScrollProbe.Probe })
            .first(where: { $0.role == .container && $0.window != nil }),
              let detent = probe.detent, let scroll = detent.scrollView else {
            preconditionFailure("Upcoming gesture fixture has no attached agenda")
        }
        let alignmentDeadline = Date().addingTimeInterval(5)
        while detent.todayOffset.map({ abs(scroll.contentOffset.y - $0) < 1 }) != true, Date() < alignmentDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let today = detent.todayOffset else { preconditionFailure("The gesture fixture needs Today") }
        precondition(today + scroll.adjustedContentInset.top > 400, "The gesture fixture needs real history")
        precondition(abs(scroll.contentOffset.y - today) < 1,
                     "The gesture fixture must start at Today: offset=\(scroll.contentOffset.y), today=\(today)")
        scroll.accessibilityIdentifier = "upcoming-gesture-agenda"
        let label = UILabel(frame: CGRect(x: 8, y: window.bounds.height - 24, width: 160, height: 20))
        label.text = "Upcoming gestures"
        label.font = .systemFont(ofSize: 10)
        label.textColor = .white
        label.accessibilityIdentifier = "upcoming-gesture-evidence"
        window.addSubview(label)
        var evidence = Evidence()
        let feedback = detent.onFeedback
        detent.onFeedback = { event in
            switch event {
            case let .tension(intensity):
                evidence.tensionCount += 1
                evidence.minimumTension = min(evidence.minimumTension, intensity)
                evidence.maximumTension = max(evidence.maximumTension, intensity)
            case .pop: evidence.pops += 1
            case .selection: evidence.catches += 1
            default: break
            }
            feedback(event)
        }
        defer {
            detent.onFeedback = feedback
            label.removeFromSuperview()
            scroll.accessibilityIdentifier = nil
        }
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            guard let today = detent.todayOffset else { preconditionFailure("The gesture fixture lost Today") }
            evidence.offset = scroll.contentOffset.y - today
            if detent.phase == .interacting {
                evidence.pull = max(evidence.pull, scroll.panGestureRecognizer.translation(in: window).y)
                if evidence.pops == 0 { evidence.held = max(evidence.held, -evidence.offset) }
            }
            if let animation = scroll.layer.animation(forKey: "plozz.upcoming.elasticity") as? CASpringAnimation,
               let displacement = animation.fromValue as? NSNumber,
               let presentation = scroll.layer.presentation() {
                if displacement.doubleValue < 0 {
                    evidence.returnFrames += 1
                    evidence.returnTravel = max(evidence.returnTravel, abs(presentation.bounds.origin.y - today))
                    evidence.returnModelDrift = max(evidence.returnModelDrift, abs(evidence.offset))
                } else if detent.phase == .interacting {
                    evidence.releaseFrames += 1
                }
            }
            label.accessibilityValue = String(decoding: try JSONEncoder().encode(evidence), as: UTF8.self)
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func posterMetrics(viewport: CGFloat, inset: CGFloat, compact: Bool) -> PlozzMetrics {
        let metrics = PlozzMetrics.touch(density: .standard)
        guard compact else { return metrics }
        return PlozziOSHomeRailLayout<EmptyView>.posterMetrics(
            in: viewport, inset: inset, metrics: metrics, cardStyle: .borderless
        )
    }
    #endif

    #if os(tvOS)
    private func page(home: Bool) -> some View {
        NavigationStack {
            Group {
                if home {
                    homeContent
                } else {
                    UpcomingView(
                        model: fixture.home.upcoming,
                        interval: DateInterval(
                            start: Date().addingTimeInterval(-30 * 86_400),
                            end: Date().addingTimeInterval(90 * 86_400)
                        )
                    )
                }
            }
            .background { AppBackground(palette: palette) }
        }
    }

    @ViewBuilder
    private var homeContent: some View {
        HomeView(
            viewModel: fixture.home, visibility: fixture.visibility,
            heroSettings: fixture.hero,
            heroBackground: fixture.background,
            heroTrailerController: fixture.trailer,
            heroIsFrontmost: true, heroRuntime: fixture.heroRuntime,
            navigationStyle: .tabBar,
            onSelectItem: { _ in }, onPlayItem: { _ in },
            onSelectLibrary: { _ in }, onBrowse: { destination in
                if case .upcoming = destination { tvSelection = .upcoming }
            }
        )
    }
    #endif
}

@MainActor
final class UpcomingCaptureState {
    let home: HomeViewModel
    let releases: [UpcomingRelease]
    fileprivate let phases: UpcomingCapturePhases
    let visibility: HomeLibraryVisibilityModel
    let hero = HeroSettingsModel(store: InMemoryHeroSettingsStore())
    let background = HeroBackgroundSettingsModel(store: InMemoryHeroBackgroundSettingsStore())
    let trailer = HeroTrailerController()
    #if os(tvOS)
    let heroRuntime = HomeHeroRuntimeState()
    #else
    let app: PlozziOSAppModel
    let shell: PlozziOSTabShell
    let sidebar = PlozziOSSidebarGeometryModel()
    #endif

    init(releases: [UpcomingRelease]? = nil) {
        let phases = UpcomingCapturePhases()
        self.phases = phases
        let releases = releases ?? UpcomingCaptureProvider.releases
        self.releases = releases
        let provider = UpcomingCaptureProvider()
        let account = Account(id: "upcoming-capture", from: provider.session)
        let defaults = UserDefaults(suiteName: "UpcomingCapture.\(UUID().uuidString)")!
        #if os(tvOS)
        visibility = HomeLibraryVisibilityModel(store: HomeLibraryVisibilityStore(defaults: defaults))
        #else
        SyncSetupFeatureFlag().isEnabled = false
        let accounts = AccountStore(secureStore: InMemorySecureStore())
        app = PlozziOSAppModel(accountStore: accounts, profileStore: ProfileStore(defaults: defaults))
        let profile = app.profiles.add(name: "Preview", isAwaitingSetup: false)
        app.profiles.select(profile.id)
        app.refreshActiveProfileSettings()
        app.accountsProviders.registry.register(.jellyfin) { _ in provider }
        do {
            try accounts.add(account, token: "fixture")
        } catch {
            preconditionFailure("Could not prepare Upcoming preview: \(error)")
        }
        app.profiles.setActiveAccountIDs([account.id], for: profile.id)
        app.accountsProviders.tokenResolver = { _ in "fixture" }
        app.accountsProviders.reloadAccounts()
        app.settings.hero.settings.isEnabled = false
        app.settings.cardStyle.style = .borderless
        app.settings.cardStyle.captions = .default
        app.settings.theme.theme = .dark
        app.settings.heroBackground.settings.detailMode = .off
        let destinations = [
            NavigationLibraryLayout.homeKey, NavigationLibraryLayout.musicKey,
            NavigationLibraryLayout.upcomingKey, NavigationLibraryLayout.downloadsKey,
            NavigationLibraryLayout.searchKey, NavigationLibraryLayout.watchlistKey,
            NavigationLibraryLayout.settingsKey
        ]
        app.settings.navigation.applyLibrarySections(
            .init(enabled: destinations, disabled: NavigationDestinationDefaults.iOS.filter { !destinations.contains($0) }),
            available: NavigationDestinationDefaults.iOS
        )
        app.metadataProviderSettingsModel.settings = MetadataProviderSettings(
            orderMode: .custom, preferOnlineArtwork: false,
            disabledOrder: MetadataSourceAttribution.all.map(\.id)
        )
        visibility = app.settings.homeVisibility
        #endif
        hero.settings.isEnabled = false
        hero.settings.style = .carousel
        visibility.useRowDefaults(.combined)
        visibility.setContinueWatchingLayout(.landscape)
        let rows: [HomeRowID] = [.global(.continueWatching), .global(.comingSoon), .global(.recentlyAdded)]
        visibility.applyRows(
            .init(enabled: rows, disabled: HomeRowChoice.shared.map(\.id).filter { !rows.contains($0) }),
            choices: HomeRowChoice.shared
        )
        #if os(tvOS)
        let visibility = visibility
        home = HomeViewModel(
            accounts: [.init(account: account, provider: provider)],
            profileNamespace: "upcoming-capture",
            layoutStore: InMemoryHomeLayoutStore(), contentStore: InMemoryHomeContentStore(),
            currentVisibility: { visibility.visibility }
        )
        #else
        var shell = PlozziOSTabShell(
            appModel: app, homeViewModelBox: LazyViewState<HomeViewModel>(), onAddServer: {},
            showingSettings: .constant(false), showingProfileSwitcher: .constant(false),
            deferredPairingURL: .constant(nil), systemColorScheme: .dark
        )
        shell.upcomingFeedLoader = { progress in
            if ProcessInfo.processInfo.arguments.contains("--capture-progressive") {
                try await phases.wait(for: 1)
                await progress(Array(releases.filter { Calendar.current.isDateInToday($0.date) }.prefix(1)))
                try await phases.wait(for: 2)
            }
            return UpcomingFeedSnapshot(releases: releases)
        }
        self.shell = shell
        home = shell.sharedHomeViewModel
        #endif
    }

    func load() async {
        await home.load()
        if ProcessInfo.processInfo.arguments.contains("--capture-progressive") { return }
        #if os(tvOS)
        let scope = "upcoming-capture"
        let namespace: String? = "upcoming-capture"
        #else
        let scope = UpcomingFeedLoader.scopeKey(
            profileID: app.profiles.activeProfileID, accounts: app.upcomingAccounts,
            requestIdentity: app.profiles.activeProfile.seerrRequestIdentity,
            connectionRevision: app.seerService.connectionRevision,
            language: Locale.current.identifier, regionCode: Locale.current.region?.identifier
        )
        let namespace = app.profiles.activeNamespace
        #endif
        let releases = releases
        await home.upcoming.refresh(scope: scope, namespace: namespace, isCurrent: { true }) {
            UpcomingFeedSnapshot(releases: releases)
        }
    }
}

private actor UpcomingCapturePhases {
    private var phase = 0

    func advance(to phase: Int) { self.phase = phase }

    func wait(for phase: Int) async throws {
        for _ in 0..<400 {
            if self.phase >= phase { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        preconditionFailure("Upcoming capture did not advance its loading phase")
    }
}

private struct UpcomingCaptureProvider: MediaProvider {
    let kind: ProviderKind = .jellyfin
    var session: UserSession {
        .init(
            server: .init(
                id: "upcoming-capture", name: "Preview",
                baseURL: URL(string: "https://upcoming-preview.example.invalid")!, provider: .jellyfin
            ),
            userID: "preview", userName: "Preview", deviceID: "fixture", accessToken: "fixture"
        )
    }

    static let series: [MediaItem] = [
        ("The Simpsons", "637/1594614", "218/547446"),
        ("Severance", "548/1371406", "384/960581"),
        ("Silo", "631/1577677", "459/1149869"),
        ("Slow Horses", "641/1604425", "471/1178812"),
        ("Foundation", "573/1433544", "262/656371")
    ].enumerated().map { index, example in
        var item = MediaItem(
            id: "capture-show-\(index)", title: example.0, kind: .series,
            allowsTitleBasedMetadataMatching: false
        )
        item.sourceAccountID = "upcoming-capture"
        item.libraryID = "shows"
        item.posterURL = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/\(example.1).jpg")
        item.backdropURL = URL(string: "https://static.tvmaze.com/uploads/images/original_untouched/\(example.2).jpg")
        return item
    }

    func libraries() async throws -> [MediaLibrary] {
        [.init(id: "shows", title: "Shows", kind: .series)]
    }
    func continueWatching(limit: Int) async throws -> [MediaItem] {
        Array(Self.series.suffix(3).enumerated().map { index, series in
            var episode = series
            episode.id = "continue-\(series.id)"
            episode.kind = .episode
            episode.seriesID = series.id
            episode.seriesPosterURL = series.posterURL
            episode.fallbackArtworkURL = series.backdropURL
            episode.parentTitle = series.title
            episode.seasonNumber = 1
            episode.episodeNumber = index + 3
            episode.resumePosition = TimeInterval((index + 1) * 400)
            episode.runtime = 3_000
            return episode
        }.prefix(limit))
    }
    func latest(limit: Int) async throws -> [MediaItem] { Array(Self.series.reversed().prefix(limit)) }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        .init(
            items: Array(Self.series.dropFirst(page.startIndex).prefix(page.limit)),
            startIndex: page.startIndex, totalCount: Self.series.count
        )
    }
    func item(id: String) async throws -> MediaItem {
        guard let item = Self.series.first(where: { $0.id == id }) else { throw AppError.notFound }
        return item
    }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }

    static var releases: [UpcomingRelease] {
        let today = Calendar.current.startOfDay(for: Date())
        let dense = ProcessInfo.processInfo.arguments.contains("--capture-dense")
        let thirty = ProcessInfo.processInfo.arguments.contains("--capture-thirty")
        let items = thirty ? (0..<30).map { index in
            var item = Self.series[index % Self.series.count]
            let number = String(format: "%02d", index + 1)
            item.id = "capture-busy-show-\(number)"
            item.title = "\(number). \(item.title)"
            return item
        } : Array(Self.series.prefix(dense ? Self.series.count : 3))
        var result = items.enumerated().flatMap { index, item -> [UpcomingRelease] in
            let day = Calendar.current.date(byAdding: .day, value: thirty || dense || index == 0 ? 0 : 1, to: today)!
            let episodes = (0..<(index == 1 ? 3 : 1)).map { offset in
                UpcomingEpisode(
                    seriesIdentity: .external(source: "capture", value: "\(index)"),
                    seasonNumber: index == 0 ? 38 : 3, episodeNumber: (index == 0 ? 6 : 1) + offset,
                    title: nil, airDate: day, datePrecision: .dateOnly,
                    source: .tvmaze, sourceURL: nil, refreshedAt: today
                )
            }
            return UpcomingReleaseBuilder.episodes(episodes, for: item)
        }
        let movie = MediaItem(id: "capture-movie", title: "A saved movie", kind: .movie)
        result += UpcomingReleaseBuilder.movies(
            [.init(kind: .digital, date: Calendar.current.date(byAdding: .day, value: 2, to: today)!, regionCode: "US")],
            for: movie, interests: [.watchlist], regionCode: "US"
        )
        if !thirty, ["--capture-scrolled", "--capture-selection", "--capture-calendar-collapsed", "--capture-calendar-resize"]
            .contains(where: ProcessInfo.processInfo.arguments.contains) {
            for index in 3..<20 {
                let item = series[index % series.count]
                result += UpcomingReleaseBuilder.episodes(
                    [.init(
                        seriesIdentity: .external(source: "capture", value: item.id),
                        seasonNumber: 1, episodeNumber: index,
                        title: nil, airDate: Calendar.current.date(byAdding: .day, value: index, to: today)!,
                        datePrecision: .dateOnly,
                        source: .tvmaze, sourceURL: nil, refreshedAt: today
                    )],
                    for: item
                )
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-progressive")
            || ProcessInfo.processInfo.arguments.contains("--capture-elasticity") {
            let future = result
            for offset in [-30, -20, -10, -2] {
                let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
                result += future.prefix(3).map { release in
                    UpcomingRelease(
                        id: "\(release.id)-past-\(offset)", titleKey: release.titleKey, item: release.item,
                        date: date, datePrecision: release.datePrecision, kind: release.kind,
                        interests: release.interests, episodes: release.episodes
                    )
                }
            }
        }
        return UpcomingReleaseBuilder.merging(result)
    }
}
