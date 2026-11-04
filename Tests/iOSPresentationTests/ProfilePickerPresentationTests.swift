#if os(iOS)
import CoreModels
import CoreNetworking
@testable import CoreUI
import SwiftUI
import UIKit
import Vision
import XCTest
@testable import AppShelliOS

@MainActor
final class ProfilePickerPresentationTests: XCTestCase {
    func testLayoutUsesCompactAvatarsAndBoundsLargeHouseholds() {
        for width in [CGFloat(320), 390, 430, 768, 1024] {
            for count in [1, 3, 6, 12, 40] {
                let layout = PlozziOSProfilePickerLayout(
                    width: width, itemCount: count, usesAccessibleText: false
                )
                XCTAssertLessThanOrEqual(layout.contentWidth, min(640, width - 48))
                XCTAssertLessThanOrEqual(layout.avatarSize, 104)
                XCTAssertGreaterThanOrEqual(layout.avatarSize, 64)
                XCTAssertLessThanOrEqual(
                    CGFloat(layout.columnCount) * layout.avatarSize
                        + CGFloat(layout.columnCount - 1) * layout.columnSpacing,
                    layout.contentWidth
                )
            }
        }
        XCTAssertEqual(PlozziOSProfilePickerLayout(
            width: 390, itemCount: 12, usesAccessibleText: false
        ).columnCount, 3)
        XCTAssertEqual(PlozziOSProfilePickerLayout(
            width: 390, itemCount: 12, usesAccessibleText: true
        ).columnCount, 1)
    }

    func testRenderedPickerFitsThemesWidthsAndHouseholdSizes() async throws {
        let cases: [(CGSize, Int, ThemePalette, Bool)] = [
            (.init(width: 390, height: 844), 3, .dark, true),
            (.init(width: 390, height: 844), 10, .dark, true),
            (.init(width: 320, height: 568), 12, .light, false),
            (.init(width: 320, height: 568), 40, .dark, false),
            (.init(width: 768, height: 1024), 4, .light, true),
            (.init(width: 844, height: 390), 6, .pureBlack, false),
            (.init(width: 390, height: 844), 1, .light, false)
        ]
        for (size, count, palette, gradient) in cases {
            try await renderPicker(size: size, count: count, palette: palette, gradient: gradient) { window in
                let scroll = try XCTUnwrap(self.scrollViews(window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                let image = self.capture(window, name: "picker-\(Int(size.width))-\(count)-\(gradient)")
                let text = try self.recognize(image)
                XCTAssertTrue(text.contains { $0.contains(count == 1 ? "Profiles" : "watching") }, "\(text)")
                XCTAssertTrue(text.contains { $0.contains("Alex") }, "\(text)")
                XCTAssertFalse(text.contains { $0.contains("Choose a profile") })
                if count <= 4, size.height > 700 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.height, scroll.bounds.height + 1)
                }
                if count >= 12 {
                    for _ in 0..<3 {
                        scroll.setContentOffset(CGPoint(x: 0, y: max(
                            0, scroll.contentSize.height - scroll.bounds.height
                        )), animated: false)
                        try await Task.sleep(for: .milliseconds(80))
                    }
                    let bottom = self.capture(window, name: "picker-many-bottom")
                    XCTAssertTrue(try self.recognize(bottom).contains { $0.contains("Viewer \(count)") })
                }
            }
        }
    }

    func testAccessibleLongNamesWrapAndRemainScrollableInBothDirections() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await renderPicker(
                size: .init(width: 390, height: 844), count: 8, palette: .dark,
                gradient: true, typeSize: .accessibility3, direction: direction
            ) { window in
                let scroll = try XCTUnwrap(self.scrollViews(window).first)
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
                let text = try self.recognize(self.capture(window, name: "picker-accessible-\(direction)"))
                XCTAssertTrue(text.contains { $0.contains("Alex") })
                XCTAssertFalse(text.contains { $0.contains("…") })
            }
        }
    }

    func testEntranceIsStaggeredSettlesWithoutOvershootAndHonorsReduceMotion() async throws {
        for count in [1, 3, 6, 8, 16, 40] {
            XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 0, profileCount: count), 0)
            let interval = PlozziOSProfilePickerEntrance.delay(at: 1, profileCount: count)
            XCTAssertLessThanOrEqual(interval, 0.09)
            if count <= 6 { XCTAssertEqual(interval, 0.09) }
            for position in 1...(count + 1) {
                let delay = PlozziOSProfilePickerEntrance.delay(at: position, profileCount: count)
                let previous = PlozziOSProfilePickerEntrance.delay(at: position - 1, profileCount: count)
                XCTAssertGreaterThan(delay, previous, "Even the Add tiles need distinct reveal slots.")
                XCTAssertEqual(delay - previous, interval, accuracy: 0.001)
            }
            XCTAssertLessThanOrEqual(
                PlozziOSProfilePickerEntrance.delay(at: count - 1, profileCount: count), 0.45 + 1e-9
            )
        }
        XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 15, profileCount: 16), 0.45, accuracy: 0.001)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.delay(at: 17, profileCount: 16), 0.51, accuracy: 0.001)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.duration, 0.45)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.headingDuration, 0.45)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.initialScale, 0.3)
        XCTAssertEqual(PlozziOSProfilePickerEntrance.initialOffset, 8)
        let model = PickerMotionFixtureModel()
        try await withWindow(
            PickerMotionFixture(model: model), size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertLessThan(try self.brightness(self.capture(window), x: 70, y: 70), 5)
            model.isPresented = true
            try await Task.sleep(for: .milliseconds(120))
            let entering = self.capture(window, name: "picker-motion-early", afterUpdates: false)
            let first = try self.brightness(entering, x: 70, y: 70)
            let last = try self.brightness(entering, x: 70, y: 190)
            XCTAssertGreaterThan(first, last + 20, "The first tile must lead the later tile.")
            XCTAssertGreaterThan(
                first, try self.brightness(entering, x: 30, y: 70) + 20,
                "The tile must grow into its final bounds rather than only fade at full size."
            )
            try await Task.sleep(for: .seconds(2))
            let settled = self.capture(window, name: "picker-motion-settled")
            XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 70), 245)
            XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 190), 245)
            XCTAssertGreaterThan(try self.brightness(settled, x: 30, y: 70), 245)
            XCTAssertLessThan(try self.brightness(settled, x: 17, y: 70), 5)
        }
        let reduced = PickerMotionFixtureModel()
        try await withWindow(
            PickerMotionFixture(model: reduced, reduceMotion: true),
            size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            let image = self.capture(window, name: "picker-reduce-motion")
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 70), 245)
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 190), 245)
            XCTAssertGreaterThan(try self.brightness(image, x: 21, y: 70), 245)
        }
    }

    func testProductionPickerActuallyAnimatesOnPresentation() async throws {
        let progress = try await measureProductionEntrance(count: 6, isSwitcher: false)
        XCTAssertLessThan(
            progress.initial, progress.settled * 9 / 10,
            "The launch cascade must remain visible after native presentation."
        )
        XCTAssertGreaterThan(progress.cascading, 1_000, "Some avatars must already be appearing.")
        XCTAssertLessThan(progress.cascading, progress.settled * 9 / 10, "The cascade must not appear all at once.")
        XCTAssertEqual(progress.headingPhase, 0, "The heading must appear before any avatar.")
        XCTAssertGreaterThan(progress.headingProgress, 0.05)
        XCTAssertLessThan(progress.headingProgress, 0.9, "The heading itself must visibly animate.")
        XCTAssertGreaterThan(
            progress.completed, progress.settled * 95 / 100,
            "Six profiles must settle within 1.5 seconds, including the heading entrance."
        )
    }

    func testRootPickerShowsHeadingThenAnimatedAvatars() async throws {
        let progress = try await measureProductionEntrance(
            count: 6, isSwitcher: false, size: .init(width: 768, height: 1024), asRoot: true
        )
        XCTAssertEqual(progress.headingPhase, 0, "The initial screen must reveal its heading before avatars.")
        XCTAssertGreaterThan(progress.headingProgress, 0.05)
        XCTAssertLessThan(progress.headingProgress, 0.9, "The initial heading must not appear fully formed.")
        XCTAssertGreaterThan(progress.cascading, 1_000)
        XCTAssertLessThan(progress.cascading, progress.settled * 9 / 10,
                          "The initial screen must animate, not insert fully visible avatars.")
        XCTAssertGreaterThan(progress.completed, progress.settled * 95 / 100)
    }

    func testProfilesArrivingDuringHeadingStillJoinTheCascade() async throws {
        let progress = try await measureProductionEntrance(
            count: 6, isSwitcher: false, size: .init(width: 768, height: 1024),
            profilesArriveDuringHeading: true
        )
        XCTAssertEqual(progress.headingPhase, 0, "Newly materialized profiles must still start hidden.")
        XCTAssertGreaterThan(progress.cascading, 1_000)
        XCTAssertLessThan(progress.cascading, progress.settled * 9 / 10,
                          "Startup updates must not skip the remaining avatars' entrance.")
        XCTAssertGreaterThan(progress.completed, progress.settled * 95 / 100)
    }

    func testLaunchObserverWaitsForItsWindowAndWarmSwitcherStartsImmediately() {
        var launchStarts = 0
        let launch = ProfilePickerPresentationObserver.Observer(startsDuringPresentation: false) {
            launchStarts += 1
        }
        launch.loadViewIfNeeded()
        launch.viewDidAppear(false)
        XCTAssertEqual(launchStarts, 0, "Appearance alone cannot start a launch animation without a visible window.")
        launch.cancelPendingEntrance()

        var switcherStarts = 0
        let switcher = ProfilePickerPresentationObserver.Observer(startsDuringPresentation: true) {
            switcherStarts += 1
        }
        switcher.loadViewIfNeeded()
        switcher.viewIsAppearing(false)
        switcher.viewDidAppear(false)
        XCTAssertEqual(switcherStarts, 1)
        switcher.cancelPendingEntrance()
    }

    func testLaunchObserverCancelsBeforeItsFirstFrame() async throws {
        try await withWindow(Color.black, size: .init(width: 390, height: 844)) { window in
            var starts = 0
            let observer = ProfilePickerPresentationObserver.Observer(startsDuringPresentation: false) {
                starts += 1
            }
            window.rootViewController = observer
            window.layoutIfNeeded()
            observer.viewDidAppear(false)
            observer.cancelPendingEntrance()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(starts, 0)
        }
    }

    func testObserverCanBecomeReadyAfterPresentationBegins() {
        var starts = 0
        let observer = ProfilePickerPresentationObserver.Observer(
            startsDuringPresentation: true, isReady: false
        ) {
            starts += 1
        }
        observer.loadViewIfNeeded()
        observer.viewIsAppearing(false)
        observer.viewDidAppear(false)
        XCTAssertEqual(starts, 0)
        observer.isReady = true
        XCTAssertEqual(starts, 1)
        observer.isReady = true
        XCTAssertEqual(starts, 1, "Readiness updates must not replay the entrance.")
        observer.cancelPendingEntrance()
    }

    func testPerformanceProfilePickerEntrance() async throws {
        try PerformanceProbe.requireEnabled()
        try await PerformanceProbe.measure(self, scenario: "mobile-profile-picker-entrance") {
            let progress = try await self.measureProductionEntrance(
                count: 16, isSwitcher: false, size: .init(width: 768, height: 1024)
            )
            XCTAssertLessThan(progress.cascading, progress.settled * 9 / 10)
            XCTAssertEqual(progress.headingPhase, 0)
            XCTAssertGreaterThan(progress.completed, progress.settled * 95 / 100)
            return ["profiles": 16, "completedEntrances": 1]
        }
    }

    func testPickerPreservesPhotoEmojiAndSymbolAvatars() async throws {
        let url = try XCTUnwrap(URL(string: "https://profile-picker.example.invalid/\(UUID()).png"))
        let image = UIGraphicsImageRenderer(size: .init(width: 100, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let cache = try XCTUnwrap(ArtworkSession.shared.configuration.urlCache)
        let requestURL = ArtworkImageVariant.musicThumbnail.requestURL(for: url)
        let request = URLRequest(url: requestURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: requestURL, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png", "Cache-Control": "max-age=3600"]
        ))
        cache.storeCachedResponse(
            CachedURLResponse(response: response, data: try XCTUnwrap(image.pngData())), for: request
        )
        defer { cache.removeCachedResponse(for: request) }
        let decoded = await ArtworkImageCache.shared.image(for: url, variant: .musicThumbnail)
        _ = try XCTUnwrap(decoded)

        var photo = Profile(id: "photo", name: "Photo", colorIndex: 2)
        photo.avatarImageURL = url.absoluteString
        var emoji = Profile(id: "emoji", name: "Emoji")
        emoji.avatarEmoji = "\u{1F34E}"
        let symbol = Profile(id: "symbol", name: "Symbol", avatarSymbol: "person.fill", colorIndex: 0)
        for profile in [photo, emoji, symbol] {
            try await withWindow(
                PlozziOSProfilePickerView(
                    profiles: [profile], activeProfileID: profile.id, onSelect: { _ in }
                )
                    .environment(\.themePalette, .pureBlack)
                    .environment(\.gradientBackgroundsEnabled, false)
                    .preferredColorScheme(.dark),
                size: .init(width: 390, height: 844)
            ) { window in
                try await Task.sleep(for: .seconds(1))
                XCTAssertGreaterThan(
                    try self.redPixelCount(self.capture(window, name: "picker-avatar-\(profile.id)")), 500,
                    "The avatar's original colored content must remain visible in the picker."
                )
            }
        }
    }

    func testEntranceContinuesWhileMainThreadIsBusy() async throws {
        let model = PickerMotionFixtureModel()
        try await withWindow(
            PickerMotionFixture(model: model), size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            model.isPresented = true
            try await Task.sleep(for: .milliseconds(100))
            let before = try self.brightness(self.capture(window, afterUpdates: false), x: 70, y: 70)
            Self.simulateBusyMainThread()
            let during = try self.brightness(self.capture(window, afterUpdates: false), x: 70, y: 70)
            let data = try JSONSerialization.data(withJSONObject: [
                "before": before, "afterMainThreadStall": during
            ], options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "profile-entrance-main-thread-stall"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            XCTAssertGreaterThan(during, before + 30, "The committed entrance should advance without another UI update.")
        }
    }

    private static func simulateBusyMainThread() {
        Thread.sleep(forTimeInterval: 0.18)
    }

    func testSixteenProfilesSettleWithinOneSecondOfCascade() async throws {
        let progress = try await measureProductionEntrance(
            count: 16, isSwitcher: false, size: .init(width: 768, height: 1024)
        )
        XCTAssertLessThan(progress.cascading, progress.settled * 9 / 10)
        XCTAssertGreaterThan(
            progress.completed, progress.settled * 95 / 100,
            "Sixteen profiles must settle within 1.5 seconds, including the heading entrance."
        )
    }

    func testManualPickerStartsDuringNativePresentation() async throws {
        let progress = try await measureProductionEntrance(count: 6, isSwitcher: true)
        XCTAssertGreaterThan(
            progress.initial, progress.settled / 5,
            "Switching profiles must already be revealing avatars when the cover finishes opening."
        )
        XCTAssertLessThan(
            progress.initial, progress.settled * 9 / 10,
            "Starting sooner must not coalesce the whole cascade into an immediate reveal."
        )
        XCTAssertGreaterThan(progress.completed, progress.settled * 95 / 100)
    }

    func testHeadingAndAvatarsIgnoreLaunchDelayWithReduceMotion() async throws {
        try await withWindow(
            VStack(spacing: 20) {
                Color.white.frame(width: 100, height: 40)
                    .modifier(PlozziOSProfilePickerHeadingEntrance(
                        isPresented: false, isLaunch: true, reduceMotion: true
                    ))
                Color.white.frame(width: 100, height: 100)
                    .modifier(PlozziOSProfilePickerEntrance(
                        isPresented: false, position: 15, profileCount: 16,
                        reduceMotion: true
                    ))
            }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.black)
                .ignoresSafeArea(),
            size: .init(width: 240, height: 360)
        ) { window in
            try await Task.sleep(for: .milliseconds(100))
            let image = self.capture(window, name: "heading-first-reduce-motion")
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 40), 245)
            XCTAssertGreaterThan(try self.brightness(image, x: 70, y: 130), 245)
        }
    }

    func testPINKeyCascadeRevealsInOrderAndHonorsReduceMotion() async throws {
        for reduceMotion in [false, true] {
            try await withWindow(
                PINKeyMotionFixture(reduceMotion: reduceMotion),
                size: .init(width: 240, height: 360)
            ) { window in
                try await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 300))
                let early = self.capture(window, name: "pin-keys-early-\(reduceMotion)", afterUpdates: false)
                let first = try self.brightness(early, x: 70, y: 70)
                let last = try self.brightness(early, x: 70, y: 190)
                if reduceMotion {
                    XCTAssertGreaterThan(first, 245)
                    XCTAssertGreaterThan(last, 245)
                } else {
                    XCTAssertGreaterThan(first, last + 20)
                    try await Task.sleep(for: .seconds(1))
                    let settled = self.capture(window, name: "pin-keys-settled")
                    XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 70), 245)
                    XCTAssertGreaterThan(try self.brightness(settled, x: 70, y: 190), 245)
                }
            }
        }
    }

    func testProfilePINLayoutFitsPhoneTabletAndAccessibleNames() async throws {
        let cases: [(CGSize, DynamicTypeSize)] = [
            (.init(width: 320, height: 568), .large),
            (.init(width: 390, height: 844), .large),
            (.init(width: 844, height: 390), .large),
            (.init(width: 768, height: 1024), .large),
            (.init(width: 1024, height: 768), .large),
            (.init(width: 390, height: 844), .accessibility3)
        ]
        for (size, typeSize) in cases {
            let model = ProfilePINLayoutFixtureModel()
            try await withWindow(
                ProfilePINLayoutFixture(model: model, usesLongName: typeSize.isAccessibilitySize)
                    .environment(\.dynamicTypeSize, typeSize)
                    .environment(\.themePalette, .dark)
                    .environment(\.locale, Locale(identifier: "en"))
                    .preferredColorScheme(.dark),
                size: size
            ) { window in
                for availability in [PINEntryAvailability.checking, .available] {
                    model.availability = availability
                    try await Task.sleep(for: .milliseconds(750))
                    let scroll = try XCTUnwrap(self.scrollViews(window).first)
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                    let text = try self.recognize(self.capture(
                        window, name: "profile-pin-\(Int(size.width))-\(typeSize)-\(availability)"
                    ))
                    XCTAssertTrue(text.contains { $0.contains("Alex") }, "\(text)")
                    XCTAssertFalse(text.contains { $0.contains("…") }, "\(text)")
                    if availability == .checking {
                        XCTAssertFalse(text.contains { $0.contains("Plex PIN") }, "\(text)")
                    }
                    scroll.setContentOffset(CGPoint(
                        x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height)
                    ), animated: false)
                    try await Task.sleep(for: .milliseconds(80))
                    let bottomText = try self.recognize(self.capture(
                        window, name: "profile-pin-bottom-\(Int(size.width))-\(typeSize)-\(availability)"
                    ))
                    XCTAssertTrue(bottomText.contains { $0 == "Cancel" },
                                  "\(size), \(typeSize), \(availability): \(bottomText)")
                    scroll.setContentOffset(.zero, animated: false)
                }
            }
        }
    }

    private func measureProductionEntrance(
        count: Int, isSwitcher: Bool, size: CGSize = .init(width: 390, height: 844),
        asRoot: Bool = false, profilesArriveDuringHeading: Bool = false
    ) async throws -> (
        initial: Int, headingPhase: Int, headingProgress: Double, cascading: Int, completed: Int, settled: Int
    ) {
        let profiles = (0..<count).map {
            Profile(id: "motion-\($0)", name: "Viewer \($0)", avatarSymbol: "person.fill", colorIndex: 0)
        }
        var result = (initial: 0, headingPhase: 0, headingProgress: 0.0, cascading: 0, completed: 0, settled: 0)
        let model = PickerArrivalFixtureModel()
        model.profiles = profilesArriveDuringHeading ? Array(profiles.prefix(2)) : profiles
        let content = PickerArrivalFixture(
            model: model, activeProfileID: profiles[0].id, isSwitcher: isSwitcher
        )
            .environment(\.themePalette, .pureBlack)
            .environment(\.gradientBackgroundsEnabled, false)
            .environment(\.locale, Locale(identifier: "en"))
            .preferredColorScheme(.dark)
        try await withWindow(
            asRoot ? AnyView(content) : AnyView(Color.black.ignoresSafeArea()), size: size
        ) { window in
            if !asRoot {
                let picker = UIHostingController(rootView: content)
                picker.modalPresentationStyle = .fullScreen
                let presenter = try XCTUnwrap(window.rootViewController)
                await withCheckedContinuation { continuation in
                    presenter.present(picker, animated: true) { continuation.resume() }
                }
            }
            if asRoot { window.layoutIfNeeded() }
            let entering = self.capture(window, name: "production-picker-entering", afterUpdates: asRoot)
            let start = ContinuousClock.now
            if profilesArriveDuringHeading {
                try await Task.sleep(until: start.advanced(by: .milliseconds(100)), clock: .continuous)
                model.profiles = profiles
            }
            try await Task.sleep(until: start.advanced(by: .milliseconds(200)), clock: .continuous)
            let heading = self.capture(window, name: "production-picker-heading", afterUpdates: false)
            try await Task.sleep(
                until: start.advanced(by: .milliseconds(isSwitcher ? 400 : 800)), clock: .continuous
            )
            let cascading = self.capture(window, name: "production-picker-cascading", afterUpdates: false)
            try await Task.sleep(
                until: start.advanced(by: .milliseconds(isSwitcher ? 1_000 : 1_500)), clock: .continuous
            )
            let completed = self.capture(window, name: "production-picker-completed", afterUpdates: false)
            try await Task.sleep(until: start.advanced(by: .seconds(2.4)), clock: .continuous)
            let settled = self.capture(window, name: "production-picker-settled")
            let early = try self.redPixelCount(entering)
            let headingPixels = try self.redPixelCount(heading)
            let middle = try self.redPixelCount(cascading)
            let nearEnd = try self.redPixelCount(completed)
            let final = try self.redPixelCount(settled)
            let headingBounds = try XCTUnwrap(try self.recognizedText(settled).first {
                $0.topCandidates(1).first?.string.contains("watching") == true
            }).boundingBox
            let headingProgress = try self.meanBrightness(heading, in: headingBounds)
                / self.meanBrightness(settled, in: headingBounds)
            let samples: [String: Any] = [
                "profileCount": count, "isSwitcher": isSwitcher,
                "initialPixels": early, "headingPhasePixels": headingPixels, "cascadingPixels": middle,
                "headingProgress": headingProgress,
                "completedPixels": nearEnd, "settledPixels": final
            ]
            let progress = XCTAttachment(
                data: try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]),
                uniformTypeIdentifier: "public.json"
            )
            progress.name = "native-cascade-progress"
            progress.lifetime = .keepAlways
            self.add(progress)
            XCTAssertGreaterThan(final, 10_000, "The actual shared avatars must be rendered.")
            XCTAssertTrue(
                try self.recognize(heading).contains { $0.contains("watching") },
                "The heading must be visible while its entrance is still in progress."
            )
            result = (early, headingPixels, headingProgress, middle, nearEnd, final)
        }
        return result
    }

    private func renderPicker(
        size: CGSize, count: Int, palette: ThemePalette, gradient: Bool,
        typeSize: DynamicTypeSize = .large, direction: LayoutDirection = .leftToRight,
        inspect: (UIWindow) async throws -> Void
    ) async throws {
        let profiles = (0..<count).map { index in
            Profile(
                id: "fixture-\(index)",
                name: index == 0 ? (typeSize.isAccessibilitySize ? "Alex with a longer profile name" : "Alex")
                    : "Viewer \(index + 1)",
                avatarSymbol: ["person.fill", "star.fill", "moon.fill"][index % 3],
                colorIndex: index % 5,
                lock: index.isMultiple(of: 2) ? ProfileLock.make(pin: "2468", iterations: 1) : nil
            )
        }
        try await withWindow(
            PlozziOSProfilePickerView(profiles: profiles, activeProfileID: profiles[0].id, onSelect: { _ in })
                .environment(\.themePalette, palette)
                .environment(\.gradientBackgroundsEnabled, gradient)
                .environment(\.dynamicTypeSize, typeSize)
                .environment(\.layoutDirection, direction)
                .environment(\.locale, Locale(identifier: "en"))
                .preferredColorScheme(palette.isLight ? .light : .dark),
            size: size
        ) { window in
            try await Task.sleep(for: .seconds(3))
            try await inspect(window)
        }
    }

    private func withWindow<Content: View>(
        _ content: Content, size: CGSize, inspect: (UIWindow) async throws -> Void
    ) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await inspect(window)
    }

    private func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func capture(_ window: UIWindow, name: String? = nil, afterUpdates: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: afterUpdates))
        }
        if let name {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return image
    }

    private func recognize(_ image: UIImage) throws -> [String] {
        try recognizedText(image).compactMap { $0.topCandidates(1).first?.string }
    }

    private func recognizedText(_ image: UIImage) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return request.results ?? []
    }

    private func meanBrightness(_ image: UIImage, in normalizedBounds: CGRect) throws -> Double {
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let minX = max(0, Int(normalizedBounds.minX * CGFloat(cg.width)))
        let maxX = min(cg.width, Int(normalizedBounds.maxX * CGFloat(cg.width)))
        let minY = max(0, Int((1 - normalizedBounds.maxY) * CGFloat(cg.height)))
        let maxY = min(cg.height, Int((1 - normalizedBounds.minY) * CGFloat(cg.height)))
        XCTAssertGreaterThan(maxX, minX)
        XCTAssertGreaterThan(maxY, minY)
        var total = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let offset = y * cg.bytesPerRow + x * 4
                total += Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
            }
        }
        return Double(total) / Double((maxX - minX) * (maxY - minY) * 3)
    }

    private func brightness(_ image: UIImage, x: Int, y: Int) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let scale = CGFloat(cg.width) / image.size.width
        let offset = Int(CGFloat(y) * scale) * cg.bytesPerRow + Int(CGFloat(x) * scale) * 4
        return (Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3
    }

    private func redPixelCount(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: cg.width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: rgba.count, by: 4).reduce(0) { count, offset in
            count + (rgba[offset] > 150 && Int(rgba[offset]) > Int(rgba[offset + 1]) * 2 ? 1 : 0)
        }
    }
}

@MainActor @Observable
private final class PickerMotionFixtureModel {
    var isPresented = false
}

@MainActor @Observable
private final class PickerArrivalFixtureModel {
    var profiles: [Profile] = []
}

private struct PickerArrivalFixture: View {
    let model: PickerArrivalFixtureModel
    let activeProfileID: String
    let isSwitcher: Bool

    var body: some View {
        PlozziOSProfilePickerView(
            profiles: model.profiles, activeProfileID: activeProfileID,
            onSelect: { _ in }, onCancel: isSwitcher ? {} : nil
        )
    }
}

private struct PickerMotionFixture: View {
    let model: PickerMotionFixtureModel
    var reduceMotion = false

    var body: some View {
        VStack(spacing: 20) {
            ForEach([0, 6], id: \.self) { position in
                Color.white.frame(width: 100, height: 100)
                    .modifier(PlozziOSProfilePickerEntrance(
                        isPresented: model.isPresented, position: position,
                        profileCount: 7, reduceMotion: reduceMotion
                    ))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .ignoresSafeArea()
    }
}

private struct PINKeyMotionFixture: View {
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 20) {
            ForEach([0, 10], id: \.self) { position in
                Color.white.frame(width: 100, height: 100)
                    .modifier(PINKeyEntrance(enabled: true, position: position, reduceMotion: reduceMotion))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.black)
        .ignoresSafeArea()
    }
}

@MainActor @Observable
private final class ProfilePINLayoutFixtureModel {
    var availability = PINEntryAvailability.checking
}

private struct ProfilePINLayoutFixture: View {
    let model: ProfilePINLayoutFixtureModel
    let usesLongName: Bool
    @Namespace private var identity

    var body: some View {
        PINEntryScaffold(
            title: "Plex PIN",
            name: Text(verbatim: usesLongName ? "Alex with a longer profile name" : "Alex"),
            availability: model.availability,
            onSubmit: { _ in }, onCancel: {}
        ) {
            Circle().fill(.red).frame(width: 88, height: 88)
        }
        .environment(\.pinProfileTransition, PINProfileTransition(profileID: "alex", namespace: identity))
        .background(.black)
    }
}
#endif
