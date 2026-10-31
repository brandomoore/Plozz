import AVFoundation
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import Vision
import XCTest

@MainActor
final class SystemPlaybackAudioHostedTests: XCTestCase {
    func testSystemRowsKeepNativeFocusThroughConfirmationAndRouteChanges() async throws {
        try await withPanel { probe, window in
            try await self.assertFocused("Reduce Loud Sounds", in: window)
            let initialFrame = try self.focusFrame(in: window)
            XCTAssertTrue(LiveChannelOverlay.showsAudio(trackCount: 1, systemAudio: probe.model.systemAudio))
            let rows = PlayerOptionsPanel.audioRows(model: probe.model, actions: PlayerOptionsActions())
            try XCTUnwrap(rows.first { $0.id == -100 }).action()
            try await self.waitUntil {
                probe.model.systemAudio.values[.reduceLoudSounds] == true && probe.model.systemAudio.pending.isEmpty
            }
            XCTAssertEqual(probe.backend.writes, 1)
            try await self.assertFocused("Reduce Loud Sounds", in: window)
            XCTAssertEqual(try self.focusFrame(in: window), initialFrame)

            probe.requestedFocus = .row(-101)
            try await self.waitUntil { probe.focus == .row(-101) }
            try await self.assertFocused("Enhance Dialogue", in: window)
            probe.backend.values = [.reduceLoudSounds: true]
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await self.waitUntil { probe.focus == .row(-100) }
            try await self.assertFocused("Reduce Loud Sounds", in: window)
            XCTAssertEqual(probe.backend.writes, 1, "Route changes must only read the system.")
            let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            attachment.name = "System audio output availability preserves native focus"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            probe.backend.values = [:]
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await self.waitUntil { probe.focus == .subBack }
            try await self.assertFocused("Back", in: window)
            probe.backend.values = [.enhanceDialogue: false]
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await self.waitUntil { probe.focus == .row(-101) }
            try await self.assertFocused("Enhance Dialogue", in: window)
            XCTAssertEqual(probe.backend.writes, 1)
        }
    }

    func testSystemRefreshStopsWhenHiddenAndResumesOnForeground() async throws {
        try await withPanel { probe, _ in
            probe.visible = false
            try await self.waitUntil { !probe.observationActive }
            let readsWhenHidden = probe.backend.reads
            probe.backend.values[.enhanceDialogue] = true
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await Task.sleep(for: .milliseconds(1_200))
            XCTAssertEqual(probe.backend.reads, readsWhenHidden)
            XCTAssertEqual(probe.model.systemAudio.values[.enhanceDialogue], false)

            probe.visible = true
            try await self.waitUntil { probe.model.systemAudio.values[.enhanceDialogue] == true }
            probe.phase = .background
            try await self.waitUntil { !probe.observationActive }
            let readsInBackground = probe.backend.reads
            probe.backend.values[.enhanceDialogue] = false
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await Task.sleep(for: .milliseconds(1_200))
            XCTAssertEqual(probe.backend.reads, readsInBackground)
            XCTAssertEqual(probe.model.systemAudio.values[.enhanceDialogue], true)

            probe.phase = .active
            try await self.waitUntil { probe.model.systemAudio.values[.enhanceDialogue] == false }
            XCTAssertEqual(probe.backend.writes, 0)
        }
    }

    func testRefusedSystemChangeShowsAnAlertWithoutChangingSelection() async throws {
        try await withPanel { probe, window in
            probe.backend.acknowledgesChanges = false
            try XCTUnwrap(PlayerOptionsPanel.audioRows(model: probe.model, actions: .init())
                .first { $0.id == -100 }).action()
            try await self.waitUntil { probe.model.systemAudio.failure == .unconfirmed }
            try await self.waitUntil { window.rootViewController?.presentedViewController != nil }
            let alert = try XCTUnwrap(window.rootViewController?.presentedViewController)
            try await self.waitUntil { !alert.isBeingPresented }
            XCTAssertEqual(probe.model.systemAudio.values[.reduceLoudSounds], false)
            let image = DetailTransitionSnapshot.image(of: window)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            XCTAssertTrue(text.contains("audio setting"), text)
            XCTAssertTrue(text.contains("Apple TV Settings"), text)
            probe.model.systemAudio.failure = nil
            try await self.waitUntil { window.rootViewController?.presentedViewController == nil }
        }
    }

    func testDialogueHierarchyUsesExistingSubmenuAndRestoresEntryFocus() async throws {
        try await withPanel(configure: { probe in
            probe.backend.dialogueLevel = .enhance
            probe.backend.values[.enhanceDialogue] = true
            probe.model.audioOptions = [
                .init(id: 1, title: Text("English"), isSelected: true),
                .init(id: 2, title: Text("French"), isSelected: false)
            ]
        }) { probe, window in
            probe.requestedFocus = .row(-101)
            try await self.waitUntil { probe.focus == .row(-101) }
            try await self.assertFocused("Enhance Dialogue", in: window)
            let menu = try self.recognizedText(in: window)
            let initialDialogueFrame = try self.focusFrame(in: window)
            XCTAssertFalse(menu.contains("Applies across Apple TV"))
            XCTAssertTrue(menu.contains("Reduce Loud Sounds"))
            XCTAssertTrue(menu.contains("English"))
            let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            attachment.name = "Audio adjustments separated from audio tracks"
            attachment.lifetime = .keepAlways
            self.add(attachment)

            let input = try XCTUnwrap(self.inputController(in: XCTUnwrap(window.rootViewController)))
            input.beginPress(.right)
            input.stopRepeating()
            try await self.waitUntil { probe.audioScreen == .dialogue && probe.focus == .row(-201) }
            try await self.assertFocused("Enhance", in: window)
            let submenu = try self.recognizedText(in: window)
            XCTAssertTrue(submenu.contains("Enhance More"))
            XCTAssertFalse(submenu.contains("English"))
            let submenuAttachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            submenuAttachment.name = "Enhance Dialogue levels in Plozz menu styling"
            submenuAttachment.lifetime = .keepAlways
            self.add(submenuAttachment)
            probe.requestedFocus = .row(-200)
            try await self.waitUntil { probe.focus == .row(-200) }
            try await self.assertFocused("Off", in: window)
            let choices = PlayerOptionsPanel.dialogueRows(model: probe.model)
            try XCTUnwrap(choices.first { $0.id == -202 }).action()
            try await self.waitUntil { probe.model.systemAudio.dialogueLevel == .enhanceMore }
            probe.backRequest += 1
            try await self.waitUntil { probe.audioScreen == .options && probe.focus == .row(-101) }
            try await self.assertFocused("Enhance Dialogue", in: window)
            let confirmedFrame = try self.focusFrame(in: window)
            let confirmedLabel = try self.recognizedText(in: window, crop: confirmedFrame)
            XCTAssertEqual(confirmedFrame.height, initialDialogueFrame.height,
                           "Enhance More must not wrap the default English dialogue row.")
            XCTAssertTrue(confirmedLabel.contains("Enhance Dialogue"), confirmedLabel)
            XCTAssertTrue(confirmedLabel.contains("Enhance More"), confirmedLabel)
            let confirmedAttachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
            confirmedAttachment.name = "Confirmed Enhance More summary"
            confirmedAttachment.lifetime = .keepAlways
            self.add(confirmedAttachment)
            XCTAssertEqual(probe.backend.writes, 1)

            let reopened = try XCTUnwrap(self.inputController(in: XCTUnwrap(window.rootViewController)))
            reopened.beginPress(.right)
            reopened.stopRepeating()
            try await self.waitUntil { probe.audioScreen == .dialogue && probe.focus == .row(-202) }
            probe.backend.dialogueLevel = nil
            NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil)
            try await self.waitUntil { probe.audioScreen == .options && probe.focus == .row(-101) }
            XCTAssertNil(PlayerOptionsPanel.audioRows(model: probe.model, actions: .init())[0].submenu)
        }
    }

    func testLongAudioLabelMarqueesOnlyWhileFocusedAndHonorsReduceMotion() async throws {
        try await withPanel(configure: { probe in
            probe.model.audioOptions = [
                .init(id: 1, title: Text("English - Original Surround - FINAL MIX"), isSelected: true),
                .init(id: 2, title: Text("French"), isSelected: false)
            ]
        }) { probe, window in
            probe.requestedFocus = .row(0)
            try await self.waitUntil { probe.focus == .row(0) }
            let frame = try self.focusFrame(in: window)
            XCTAssertLessThan(frame.width, PlayerOptionsPanel.width(for: .audio, subtitleScreen: .tracks))
            XCTAssertTrue(try self.recognizedText(in: window, crop: frame).contains("English"))
            let motion = XCTAttachment(string: "Reduce Motion: \(UIAccessibility.isReduceMotionEnabled)")
            motion.name = "Audio marquee system motion preference"
            motion.lifetime = .keepAlways
            self.add(motion)
            if UIAccessibility.isReduceMotionEnabled {
                try await Task.sleep(for: .seconds(4))
                let stationary = try self.recognizedText(in: window, crop: frame)
                XCTAssertTrue(stationary.contains("English"))
                XCTAssertFalse(stationary.contains("FINAL MIX"), "Reduce Motion must not scroll the title.")
                return
            }
            let deadline = ContinuousClock.now + .seconds(8)
            var revealedTail = false
            repeat {
                try await Task.sleep(for: .milliseconds(250))
                revealedTail = try self.recognizedText(in: window, crop: frame).contains("FINAL MIX")
            } while !revealedTail && ContinuousClock.now < deadline
            XCTAssertTrue(revealedTail, "The real focused audio row must scroll far enough to reveal its ending.")
            XCTAssertEqual(try self.focusFrame(in: window), frame, "Only the label moves, not the row.")

            probe.requestedFocus = .row(1)
            try await self.waitUntil { probe.focus == .row(1) }
            XCTAssertTrue(try self.recognizedText(in: window, crop: frame).contains("English"),
                          "Losing focus resets the marquee to the beginning.")
            probe.requestedFocus = .row(0)
            try await self.waitUntil { probe.focus == .row(0) }
            XCTAssertTrue(try self.recognizedText(in: window, crop: frame).contains("English"))
        }
    }

    @MainActor
    final class Backend: SystemPlaybackAudioControlling {
        var values: [SystemPlaybackAudioSetting: Bool] = [.reduceLoudSounds: false, .enhanceDialogue: false]
        var writes = 0
        var reads = 0
        var acknowledgesChanges = true
        var dialogueLevel: SystemDialogueLevel?

        func read() -> SystemPlaybackAudioState {
            reads += 1
            return .init(values: values, dialogueLevel: dialogueLevel)
        }

        func setEnabled(_ enabled: Bool, for setting: SystemPlaybackAudioSetting) {
            writes += 1
            if acknowledgesChanges { values[setting] = enabled }
        }

        func setDialogueLevel(_ level: SystemDialogueLevel) {
            writes += 1
            if acknowledgesChanges {
                dialogueLevel = level
                values[.enhanceDialogue] = level != .off
            }
        }
    }

    @MainActor @Observable
    final class Probe {
        let backend = Backend()
        let model: PlayerControlsModel
        var requestedFocus: PlayerControls.FocusSlot = .row(-101)
        var focus: PlayerControls.FocusSlot?
        var visible = true
        var phase = ScenePhase.active
        var observationActive = true
        var audioScreen = PlayerControls.AudioScreen.options
        var backRequest = 0

        init() {
            model = PlayerControlsModel(systemAudio: SystemPlaybackAudio(backend: backend))
        }
    }

    private struct Panel: View {
        let probe: Probe
        @State private var heights: [PlayerControls.Category: CGFloat] = [:]
        @FocusState private var focus: PlayerControls.FocusSlot?

        var body: some View {
            PlayerOptionsPanel(
                category: .audio, model: probe.model, palette: .dark, actions: PlayerOptionsActions(),
                subtitleScreen: .constant(.tracks), heightCache: $heights, focus: $focus,
                close: {}, backRequest: probe.backRequest, maximumHeight: 900,
                audioScreen: Binding(get: { probe.audioScreen }, set: { probe.audioScreen = $0 })
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(60)
            .background(.black)
            .observingSystemPlaybackAudio(probe.model.systemAudio, isVisible: probe.visible)
            .environment(\.scenePhase, probe.phase)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .dark)
            .onChange(of: probe.requestedFocus) { _, value in focus = value }
            .onChange(of: focus) { _, value in probe.focus = value }
            .onChange(of: probe.visible && probe.phase == .active) { _, value in probe.observationActive = value }
        }
    }

    private func withPanel(
        configure: (Probe) -> Void = { _ in }, _ body: (Probe, UIWindow) async throws -> Void
    ) async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let probe = Probe()
        configure(probe)
        await probe.model.systemAudio.refresh().value
        window.rootViewController = UIHostingController(rootView: Panel(probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { probe.focus != nil && UIFocusSystem.focusSystem(for: window)?.focusedItem != nil }
        probe.requestedFocus = .row(-100)
        try await waitUntil { probe.focus == .row(-100) }
        try await body(probe, window)
    }

    private func focusFrame(in window: UIWindow) throws -> CGRect {
        let item = try XCTUnwrap(UIFocusSystem.focusSystem(for: window)?.focusedItem)
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return try XCTUnwrap(nil as CGRect?, "The focused row must have a coordinate space.")
    }

    private func inputController(in root: UIViewController) -> (any PlayerOptionsRemoteInput)? {
        if let input = root as? any PlayerOptionsRemoteInput { return input }
        return root.children.lazy.compactMap { self.inputController(in: $0) }.first
    }

    private func recognizedText(in window: UIWindow, crop: CGRect? = nil) throws -> String {
        let image = DetailTransitionSnapshot.image(of: window)
        var pixels = try XCTUnwrap(image.cgImage)
        if let crop {
            pixels = try XCTUnwrap(pixels.cropping(to: crop.applying(
                CGAffineTransform(scaleX: image.scale, y: image.scale)
            ).integral))
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.customWords = ["Off", "Enhance More", "Enhance Dialogue"]
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func assertFocused(
        _ expected: String, in window: UIWindow, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        var previous: CGRect?
        repeat {
            let frame = try focusFrame(in: window)
            let text = try recognizedText(in: window, crop: frame)
            let words = expected.split(separator: " ").map(String.init)
            if frame == previous, frame.height < 120, words.allSatisfy(text.contains) { return }
            previous = frame
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "Native focus did not settle on \(expected)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTFail("The settled native focused row must contain \(expected).", file: file, line: line)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition())
    }
}
