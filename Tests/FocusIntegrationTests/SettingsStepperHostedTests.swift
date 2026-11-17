@testable import CoreUI
@testable import FeatureSettings
@testable import FeaturePlayback
import CoreModels
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SettingsStepperHostedTests: XCTestCase {
    func testSubtitleSyncRepeatsImmediatelyAndKeepsFocusAtBounds() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PlayerControlsModel()
        var applied: [TimeInterval] = []
        let actions = PlayerOptionsActions(setSubtitleDelay: {
            applied.append($0)
            model.subtitleDelaySeconds = $0
        })
        let host = UIHostingController(rootView: SubtitleSyncFixture(model: model, actions: actions))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.inputController(in: host) != nil }
        let input = try XCTUnwrap(inputController(in: host))
        defer { input.stopRepeating() }
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        system.requestFocusUpdate(to: input)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        let focused = try XCTUnwrap(system.focusedItem)
        input.beginPress(.right)
        XCTAssertEqual(model.subtitleDelaySeconds, 0.05, accuracy: 0.000001)
        try await waitUntil { applied.count >= 3 }
        input.endPress()
        for (index, expected) in [0.05, 0.10, 0.15].enumerated() {
            XCTAssertEqual(applied[index], expected, accuracy: 0.000001)
        }
        XCTAssertTrue(system.focusedItem === focused)
        for (start, direction) in [(9.95, SettingsMoveCommandDirection.right), (-9.95, .left)] {
            model.subtitleDelaySeconds = start
            try await Task.sleep(for: .milliseconds(100))
            input.beginPress(direction)
            XCTAssertEqual(abs(model.subtitleDelaySeconds), 10, accuracy: 0.000001)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(system.focusedItem === focused)
            input.endPress()
            input.beginPress(start < 0 ? .right : .left)
            XCTAssertEqual(model.subtitleDelaySeconds, start, accuracy: 0.000001)
            input.endPress()
        }
        XCTAssertEqual(model.audioDelaySeconds, 0)
        model.subtitleDelaySeconds = 0
        try await Task.sleep(for: .milliseconds(100))
        try sendSwipe(.began, translation: 8, to: input)
        try sendSwipe(.ended, translation: 208, to: input)
        XCTAssertEqual(model.subtitleDelaySeconds, 0.55, accuracy: 0.000001,
                       "The lift sample must apply all eleven steps, not just one swipe event.")
        XCTAssertTrue(system.focusedItem === focused)
        try await Task.sleep(for: .milliseconds(100))
        try sendSwipe(.began, translation: 8, to: input)
        try sendSwipe(.changed, translation: 10_008, to: input)
        XCTAssertEqual(model.subtitleDelaySeconds, 10)
        try sendSwipe(.changed, translation: 9_988, to: input)
        XCTAssertEqual(model.subtitleDelaySeconds, 9.95, accuracy: 0.000001,
                       "Reversing at the bound must not undo discarded overshoot first.")
        try sendSwipe(.cancelled, translation: 9_988, to: input)
        XCTAssertTrue(system.focusedItem === focused)
    }

    func testAudioSyncSwipePreviewsItsDistanceAndDefersReloadUntilLift() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PlayerControlsModel()
        var applied: [TimeInterval] = []
        let actions = PlayerOptionsActions(setAudioDelay: {
            applied.append($0)
            model.audioDelaySeconds = $0
        })
        let host = UIHostingController(rootView: AudioSyncFixture(model: model, actions: actions))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.audioSyncAdjustment.cancel()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.inputController(in: host) != nil }
        let input = try XCTUnwrap(inputController(in: host))
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        system.requestFocusUpdate(to: input)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        let focused = try XCTUnwrap(system.focusedItem)
        try sendSwipe(.began, translation: 8, to: input)
        try sendSwipe(.changed, translation: 408, to: input)
        XCTAssertEqual(model.audioSyncAdjustment.value, 0.21)
        try await Task.sleep(for: .milliseconds(750))
        XCTAssertTrue(applied.isEmpty, "A stationary finger must not trigger the fallback reload.")
        XCTAssertNil(model.audioSyncAdjustment.commitTask)
        try sendSwipe(.ended, translation: 428, to: input)
        XCTAssertEqual(model.audioSyncAdjustment.value, 0.22)
        XCTAssertTrue(applied.isEmpty)
        try await waitUntil { applied == [0.22] }
        XCTAssertTrue(system.focusedItem === focused)
        try await Task.sleep(for: .milliseconds(100))
        try sendSwipe(.began, translation: -8, to: input)
        try sendSwipe(.changed, translation: -30_008, to: input)
        XCTAssertEqual(model.audioSyncAdjustment.value, -10)
        try sendSwipe(.changed, translation: -29_988, to: input)
        XCTAssertEqual(model.audioSyncAdjustment.value, -9.99)
        try sendSwipe(.cancelled, translation: -29_988, to: input)
        XCTAssertNil(model.audioSyncAdjustment.value)
        XCTAssertNil(model.audioSyncAdjustment.commitTask)
        XCTAssertEqual(applied, [0.22])
        XCTAssertTrue(system.focusedItem === focused)
        try await Task.sleep(for: .milliseconds(100))
        try sendSwipe(.began, translation: 8, to: input)
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        try sendSwipe(.ended, translation: 408, to: input)
        XCTAssertNil(model.audioSyncAdjustment.value, "Late swipe samples cannot resume cancelled input.")
        XCTAssertNil(model.audioSyncAdjustment.commitTask)
        XCTAssertEqual(applied, [0.22])
    }

    private func sendSwipe(
        _ phase: UIGestureRecognizer.State, translation: CGFloat,
        to input: any SettingsAdjustmentRemoteInput
    ) throws {
        let controller = try XCTUnwrap(input as? UIViewController)
        let pan = SampledPan(phase: phase, translation: translation)
        if phase == .began {
            let delegate = try XCTUnwrap(controller as? UIGestureRecognizerDelegate)
            XCTAssertEqual(delegate.gestureRecognizerShouldBegin?(pan), true)
        }
        let selector = NSSelectorFromString("swiped:")
        XCTAssertTrue(controller.responds(to: selector))
        _ = controller.perform(selector, with: pan)
    }

    private final class SampledPan: UIPanGestureRecognizer {
        private var phase: UIGestureRecognizer.State
        private let travel: CGFloat

        init(phase: UIGestureRecognizer.State, translation: CGFloat) {
            self.phase = phase
            travel = translation
            super.init(target: nil, action: nil)
        }

        override var state: UIGestureRecognizer.State {
            get { phase }
            set { phase = newValue }
        }

        override func translation(in view: UIView?) -> CGPoint { CGPoint(x: travel, y: 0) }
        override func velocity(in view: UIView?) -> CGPoint { CGPoint(x: travel < 0 ? -100 : 100, y: 0) }
    }

    private struct SubtitleSyncFixture: View {
        let model: PlayerControlsModel
        let actions: PlayerOptionsActions
        @FocusState private var focus: PlayerControls.FocusSlot?

        var body: some View {
            SubtitleSyncScreen(model: model, actions: actions, focus: $focus)
                .environment(\.themePalette, .dark)
                .frame(width: 580, height: 360)
        }
    }

    func testAudioSyncKeepsSingleFocusAtBoundsAndCoalescesReleases() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        for start in [-9.99, 9.99] {
            let model = PlayerControlsModel()
            model.audioDelaySeconds = start
            var applied: [TimeInterval] = []
            let actions = PlayerOptionsActions(setAudioDelay: {
                applied.append($0)
                model.audioDelaySeconds = $0
            })
            let host = UIHostingController(rootView: AudioSyncFixture(model: model, actions: actions))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKeyAndVisible()
            }
            try await waitUntil { self.inputController(in: host) != nil }
            let input = try XCTUnwrap(inputController(in: host))
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            system.requestFocusUpdate(to: input)
            system.updateFocusIfNeeded()
            try await waitUntil { input.ownsHorizontalNavigationInput }
            let focused = try XCTUnwrap(system.focusedItem)
            input.beginPress(start < 0 ? .left : .right)
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(system.focusedItem === focused, "The pending bound must not disable its focused control.")
            XCTAssertTrue(applied.isEmpty)
            input.endPress()
            XCTAssertTrue(applied.isEmpty, "Release starts a quiet period rather than reloading immediately.")
            input.beginPress(start < 0 ? .left : .right)
            input.endPress()
            XCTAssertTrue(system.focusedItem === focused)
            XCTAssertTrue(applied.isEmpty)
            try await waitUntil { applied.count == 1 }
            XCTAssertEqual(applied, [start < 0 ? -10 : 10])
            input.endPress()
            XCTAssertEqual(applied.count, 1)
            input.beginPress(start < 0 ? .right : .left)
            input.stopRepeating()
            XCTAssertNil(model.audioSyncAdjustment.value)
            XCTAssertNil(model.audioSyncAdjustment.commitTask)
            XCTAssertEqual(applied.count, 1, "Cancellation must discard the uncommitted preview.")
        }
    }

    private struct AudioSyncFixture: View {
        let model: PlayerControlsModel
        let actions: PlayerOptionsActions
        @FocusState private var focus: PlayerControls.FocusSlot?

        var body: some View {
            AudioSyncScreen(model: model, actions: actions, focus: $focus)
                .environment(\.themePalette, .dark)
                .frame(width: 580, height: 360)
        }
    }

    func testSkipDelayShowsEachRemoteAdjustmentBeforeTheNextPress() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "skip-delay-feedback-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = PlaybackSettingsModel(store: PlaybackSettingsStore(defaults: defaults))
        model.settings.setConfiguredSkipMode(.autoDelay, for: .intro, category: .movie)
        model.settings.setSkipAutomaticDelay(12, for: .intro, category: .movie)
        let host = SizingHost(rootView:
            SkipMarkerContentSettingsView(model: model, kind: .intro)
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.themePalette, .dark)
                .environment(\.colorScheme, .dark)
                .frame(width: SettingsFormMetrics.pageWidth)
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await waitUntil { self.inputController(in: host) != nil }
        let input = try XCTUnwrap(inputController(in: host))
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        let inputView = try XCTUnwrap((input as? UIViewController)?.view)
        let middle = inputView.convert(inputView.bounds, to: window).midY
        host.target = try XCTUnwrap(focusItems(in: window).filter { $0.frame.width > 300 }.min {
            abs(focusFrame($0, in: window).midY - middle) < abs(focusFrame($1, in: window).midY - middle)
        })
        system.requestFocusUpdate(to: host)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        host.target = nil
        let focused = try XCTUnwrap(system.focusedItem)
        var frames: [(Int, UIImage)] = []
        for expected in [13, 14, 15, 14, 13] {
            press(expected > model.settings.configuredSkipDelay(for: .intro, category: .movie) ? .right : .left, input)
            XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .movie), expected)
            try await Task.sleep(for: .milliseconds(100))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            frames.append((expected, image))
            XCTAssertTrue(system.focusedItem === focused)
        }
        for (expected, image) in frames {
            let attachment = XCTAttachment(image: image)
            attachment.name = "Skip-after-live-\(expected)"
            attachment.lifetime = .keepAlways
            add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("\(expected) seconds"), "Value must be visible before the next press: \(text)")
        }
        XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .anime), 5)
        try sendSwipe(.began, translation: 8, to: input)
        try sendSwipe(.ended, translation: 408, to: input)
        XCTAssertEqual(model.settings.configuredSkipDelay(for: .intro, category: .movie), 14,
                       "Steppers that have not opted in must retain one step per swipe.")
    }

    func testSharedThemeVolumeControlPreviewsOnceUpdatesGainAndStopsOnExit() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let store = RecordingThemeMusicStore()
        let model = ThemeMusicSettingsModel(store: store)
        let preview = PreviewController()
        var resolutionCount = 0
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            ThemeMusicVolumeControl(model: model)
                .environment(\.themeMusicPreviewController, preview)
                .environment(\.themeMusicPreviewResolver, { resolutionCount += 1; return nil })
                .frame(width: 900)
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.inputController(in: host) != nil }
        let input = try XCTUnwrap(inputController(in: host))
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        system.requestFocusUpdate(to: input)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput }
        press(.right, input)
        try await waitUntil { preview.previewOwner != nil }
        XCTAssertEqual(resolutionCount, 1)
        XCTAssertEqual(model.settings.volume.level, 0.26)
        XCTAssertEqual(preview.volume.level, 0.26)
        let owner = try XCTUnwrap(preview.previewOwner)
        for expected in [0.27, 0.28, 0.29] {
            press(.right, input)
            try await waitUntil { model.settings.volume.level == expected }
        }
        press(.left, input)
        try await waitUntil { model.settings.volume.level == 0.28 }
        model.settings.volume = ThemeMusicVolume(0.48)
        try await waitUntil { preview.volume.level == 0.48 }
        XCTAssertEqual(model.settings.volume.level, 0.48, "Presenting a saved value must not rewrite it.")
        press(.right, input)
        try await waitUntil { model.settings.volume.level == 0.49 }
        model.settings.volume = ThemeMusicVolume(0.01)
        try await waitUntil { preview.volume.level == 0.01 }
        press(.left, input)
        try await waitUntil { model.settings.volume.level == 0 }
        model.settings.volume = ThemeMusicVolume(0.99)
        try await waitUntil { preview.volume.level == 0.99 }
        press(.right, input)
        try await waitUntil { model.settings.volume.level == 1 }
        for step in (0..<100).reversed() {
            press(.left, input)
            try await waitUntil { model.settings.volume.level == Double(step) / 100 }
        }
        press(.left, input)
        XCTAssertEqual(model.settings.volume.level, 0)
        model.settings.volume = ThemeMusicVolume(0.50)
        try await waitUntil { preview.volume.level == 0.50 }
        store.clearHistory()
        input.beginPress(.left)
        defer { input.stopRepeating() }
        try await waitUntil(timeout: .seconds(2.5)) { model.settings.volume.level <= 0.15 }
        input.stopRepeating()
        let held = store.savedLevels
        XCTAssertGreaterThanOrEqual(held.count, 35, "A hold must reach 15% from 50% within the fast-repeat budget.")
        XCTAssertEqual(held.first, 0.49)
        for (previous, next) in zip([0.50] + held, held) {
            XCTAssertEqual(previous - next, 0.01, accuracy: 0.000_001, "A fast hold must still visit every percentage.")
        }
        let releasedVolume = model.settings.volume
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.settings.volume, releasedVolume, "Releasing the remote must cancel fast repeat.")
        XCTAssertEqual(preview.previewOwner, owner)
        XCTAssertEqual(resolutionCount, 1, "Scrubbing must not repeatedly look up library themes.")
        window.isHidden = true
        window.rootViewController = nil
        try await waitUntil { preview.previewOwner == nil }
    }

    func testHeroSizeControlsStayCompactAndAdjustIndependentlyWithNativeFocus() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        for preview in [false, true] {
            for direction in [LayoutDirection.leftToRight, .rightToLeft] {
                let previous = scene.windows.first(where: \.isKeyWindow)
                let model = SizingModel()
                let fixture = SizingFixture(model: model, preview: preview)
                    .environment(\.layoutDirection, direction)
                let host = SizingHost(rootView: fixture)
                let window = UIWindow(windowScene: scene)
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                    previous?.makeKeyAndVisible()
                }
                try await waitUntil { self.inputControllers(in: host).count == 2 }
                let inputs = inputControllers(in: host)
                let system = try XCTUnwrap(UIFocusSystem(for: window))
                var frames: [CGRect] = []
                for (index, input) in inputs.enumerated() {
                    let view = try XCTUnwrap((input as? UIViewController)?.view)
                    let middle = view.convert(view.bounds, to: window).midY
                    host.target = try XCTUnwrap(focusItems(in: window).filter { $0.frame.width > 300 }.min {
                        abs(focusFrame($0, in: window).midY - middle) < abs(focusFrame($1, in: window).midY - middle)
                    })
                    system.requestFocusUpdate(to: host)
                    system.updateFocusIfNeeded()
                    try await waitUntil { input.ownsHorizontalNavigationInput }
                    host.target = nil
                    let focused = try XCTUnwrap(system.focusedItem)
                    frames.append(focused.frame)
                    XCTAssertLessThanOrEqual(focused.frame.height, 100, "Each adjustment must remain one compact row.")
                    press(.right, input)
                    try await waitUntil {
                        index == 0 ? model.logo.rawValue == 1 : model.text.rawValue == 1
                    }
                    XCTAssertEqual(model.logo.rawValue, 1)
                    XCTAssertEqual(model.text.rawValue, index == 0 ? 0 : 1)
                    XCTAssertTrue(system.focusedItem === focused)
                    XCTAssertEqual(system.focusedItem?.frame, frames[index])
                    input.stopRepeating()
                }
                let size = host.sizeThatFits(in: CGSize(width: 900, height: 1000))
                let contentHeight = size.height - host.view.safeAreaInsets.top - host.view.safeAreaInsets.bottom
                XCTAssertLessThanOrEqual(contentHeight, 180, "Both adjustments must fit in the old sizing area.")
                XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
                let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "compact-hero-sizing-preview-\(preview)-\(direction)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    func testConnectedGroupsPreserveNativeAdjustmentAndFocusHandoff() async throws {
        try await withStepper(connectedGroups: true) { model, input, window in
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            let focused = try XCTUnwrap(system.focusedItem)
            self.press(.right, input)
            try await self.waitUntil { model.selection == 120 }
            XCTAssertTrue(system.focusedItem === focused)
            model.focusOther = true
            try await self.waitUntil { system.focusedItem !== focused && !model.focused }
            XCTAssertFalse(input.ownsHorizontalNavigationInput)
            self.press(.left, input)
            XCTAssertEqual(model.selection, 120)
        }
    }

    func testRangeTrackReusesBoundedAdjustmentAndNativeFocus() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await withStepper(direction: direction, showsTrack: true) { model, input, window in
                let system = try XCTUnwrap(UIFocusSystem(for: window))
                let focused = try XCTUnwrap(system.focusedItem)
                let frame = focused.frame
                self.press(.right, input)
                try await self.waitUntil { model.selection == 120 }
                self.press(.right, input)
                XCTAssertEqual(model.selection, 120)
                self.press(.left, input)
                self.press(.left, input)
                try await self.waitUntil { model.selection == 5 }
                self.press(.left, input)
                XCTAssertEqual(model.selection, 5)
                XCTAssertTrue(system.focusedItem === focused)
                XCTAssertEqual(system.focusedItem?.frame, frame)
                model.focusOther = true
                try await self.waitUntil { !model.focused }
                self.press(.right, input)
                XCTAssertEqual(model.selection, 5)
            }
        }
    }

    func testHundredStepVolumeRangeKeepsTrackAndNativeFocusBounded() async throws {
        var baselineWidth: CGFloat = 0
        try await withStepper(showsTrack: true) { _, _, window in
            baselineWidth = try XCTUnwrap(UIFocusSystem(for: window)?.focusedItem).frame.width
        }
        try await withStepper(showsTrack: true, denseRange: true) { model, input, window in
            let system = try XCTUnwrap(UIFocusSystem(for: window))
            let focused = try XCTUnwrap(system.focusedItem)
            let frame = focused.frame
            self.press(.right, input)
            try await self.waitUntil { model.selection == 16 }
            self.press(.left, input)
            try await self.waitUntil { model.selection == 15 }
            XCTAssertTrue(system.focusedItem === focused)
            XCTAssertEqual(system.focusedItem?.frame, frame)
            XCTAssertEqual(frame.width, baselineWidth, accuracy: 1)
        }
    }

    func testDirectionalAdjustmentClampsAndKeepsNativeFocusAndWidth() async throws {
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            try await withStepper(direction: direction) { model, input, window in
                let system = try XCTUnwrap(UIFocusSystem(for: window))
                let focused = try XCTUnwrap(system.focusedItem)
                let initialFrame = focused.frame
                XCTAssertGreaterThan(initialFrame.width, 800, "The native target must span the whole labeled row.")
                self.press(.right, input)
                try await self.waitUntil { model.selection == 120 }
                self.press(.right, input)
                XCTAssertEqual(model.selection, 120)
                self.press(.left, input)
                try await self.waitUntil { model.selection == 15 }
                self.press(.left, input)
                try await self.waitUntil { model.selection == 5 }
                self.press(.left, input)
                XCTAssertEqual(model.selection, 5)
                XCTAssertTrue(system.focusedItem === focused)
                XCTAssertEqual(system.focusedItem?.frame, initialFrame)
                XCTAssertTrue(model.focused)
                model.focusOther = true
                try await self.waitUntil { system.focusedItem !== focused && !model.focused }
                XCTAssertFalse(input.ownsHorizontalNavigationInput)
                self.press(.right, input)
                XCTAssertEqual(model.selection, 5, "An unfocused control cannot change settings.")
            }
        }
    }

    func testCyclicOptionsWrapWithoutChangingTheNativeFocusTarget() async throws {
        try await withStepper(wraps: true) { model, input, window in
            let focused = UIFocusSystem(for: window)?.focusedItem
            self.press(.right, input)
            try await self.waitUntil { model.selection == 120 }
            self.press(.right, input)
            try await self.waitUntil { model.selection == 5 }
            self.press(.left, input)
            try await self.waitUntil { model.selection == 120 }
            XCTAssertTrue(UIFocusSystem(for: window)?.focusedItem === focused)
        }
    }

    func testChangingTheOptionSetCancelsAnOwnedHeldPress() async throws {
        try await withStepper { model, input, _ in
            input.beginPress(.right)
            XCTAssertEqual(model.selection, 120)
            model.options = [120, 240]
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(model.selection, 120, "A held press must not cross a changed option set.")
            self.press(.right, input)
            try await self.waitUntil { model.selection == 240 }
        }
    }

    private func press(_ direction: SettingsMoveCommandDirection, _ input: any SettingsAdjustmentRemoteInput) {
        input.beginPress(direction)
        input.stopRepeating()
    }

    private func withStepper(
        wraps: Bool = false,
        direction: LayoutDirection = .leftToRight,
        showsTrack: Bool = false,
        connectedGroups: Bool = false,
        denseRange: Bool = false,
        body: (Model, any SettingsAdjustmentRemoteInput, UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = Model()
        if denseRange { model.options = Array(0...100) }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(
            model: model, wraps: wraps, showsTrack: showsTrack, connectedGroups: connectedGroups
        )
            .environment(\.layoutDirection, direction))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { self.inputController(in: host) != nil }
        let input = try XCTUnwrap(inputController(in: host))
        let system = try XCTUnwrap(UIFocusSystem(for: window))
        system.requestFocusUpdate(to: input)
        system.updateFocusIfNeeded()
        try await waitUntil { input.ownsHorizontalNavigationInput && model.focused }
        defer { input.stopRepeating() }
        try await body(model, input, window)
    }

    private func inputController(in root: UIViewController) -> (any SettingsAdjustmentRemoteInput)? {
        if let input = root as? any SettingsAdjustmentRemoteInput { return input }
        return root.children.lazy.compactMap { self.inputController(in: $0) }.first
    }

    private func inputControllers(in root: UIViewController) -> [any SettingsAdjustmentRemoteInput] {
        let own = (root as? any SettingsAdjustmentRemoteInput).map { [$0] } ?? []
        return own + root.children.flatMap { inputControllers(in: $0) }
    }

    private class SizingHost<Content: View>: UIHostingController<Content> {
        var target: (any UIFocusEnvironment)?
        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            target.map { [$0] } ?? super.preferredFocusEnvironments
        }
    }

    private func focusItems(in window: UIWindow) -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
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

    private func focusFrame(_ item: any UIFocusItem, in window: UIWindow) -> CGRect {
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        XCTFail("The native focus item must have a coordinate space.")
        return .null
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition())
    }

    @Observable final class Model {
        var options = [5, 15, 120]
        var selection = 15
        var focused = false
        var focusOther = false
    }

    final class RecordingThemeMusicStore: ThemeMusicSettingsStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var settings = ThemeMusicSettings.default
        private var levels: [Double] = []

        func load() -> ThemeMusicSettings {
            lock.lock()
            defer { lock.unlock() }
            return settings
        }

        func save(_ settings: ThemeMusicSettings) {
            lock.lock()
            defer { lock.unlock() }
            self.settings = settings
            levels.append(settings.volume.level)
        }

        var savedLevels: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return levels
        }

        func clearHistory() {
            lock.lock()
            defer { lock.unlock() }
            levels.removeAll()
        }
    }

    @Observable final class PreviewController: ThemeMusicPreviewControlling {
        var previewOwner: UUID?
        var isBlocked = false
        var isAppActive = true
        var failure: LocalizedStringResource?
        var volume = ThemeMusicVolume.low

        func updateVolume(_ volume: ThemeMusicVolume) { self.volume = volume }
        func stopPreview(owner: UUID) {
            if previewOwner == owner { previewOwner = nil }
        }
        func preview(
            owner: UUID, volume: ThemeMusicVolume, resolve: ThemeMusicPreviewResolving,
            authenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)?
        ) async {
            self.volume = volume
            _ = try? await resolve()
            previewOwner = owner
        }
    }

    @Observable final class SizingModel {
        var logo = HeroLogoSize.default
        var text = HeroTextSize.default
    }

    private struct SizingFixture: View {
        @Bindable var model: SizingModel
        let preview: Bool

        var body: some View {
            HeroLogoSizeControl(
                size: $model.logo, textSize: $model.text, surface: .showcase, showsLibraryPreview: preview
            )
            .frame(width: 900)
        }
    }

    private struct Fixture: View {
        @Bindable var model: Model
        let wraps: Bool
        let showsTrack: Bool
        let connectedGroups: Bool
        @FocusState private var otherFocused: Bool

        var body: some View {
            Group {
                if connectedGroups {
                    SettingsConnectedControlGroups { controls }
                } else {
                    VStack(spacing: 50) { controls }
                }
            }
            .frame(width: 900)
            .onChange(of: model.focusOther) { _, value in otherFocused = value }
        }

        private var controls: some View {
            Group {
                SettingsStepper(
                    options: model.options, selection: $model.selection, compact: showsTrack, wraps: wraps,
                    onFocusChange: { model.focused = $0 }, label: "Seconds",
                    subtitle: "Adjustment helper",
                    rangeLabels: showsTrack ? ("Small", "Large") : nil,
                    verbatimTitle: { "\($0) sec" }
                )
                Button("Next setting") {}.focused($otherFocused)
            }
        }
    }
}
