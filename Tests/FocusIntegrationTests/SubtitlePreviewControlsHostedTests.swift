import CoreModels
@testable import CoreUI
@testable import FeaturePlayback
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class SubtitlePreviewControlsHostedTests: XCTestCase {
    func testPreviewExpandsAcrossItsControlsAndReturnsFromFullScreen() async throws {
        try await waitUntil {
            UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = PreviewControlsFixtureModel()
        model.options.animatesBackground = false
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let host = UIHostingController(rootView: PreviewControlsFixture(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        try await waitUntil { model.footerFrame.height > 0 && model.footerFrame.height < 110 }
        let collapsedHeight = model.footerFrame.height
        var lastCenter: CGFloat?
        for control in [SubtitlePreviewControl.header, .background, .fileFormatting, .hdrBrightness] {
            model.requested = control
            try await waitUntil {
                model.focused == control && model.footerFrame.height > 220
                    && self.focusFrame(in: window).map(model.footerFrame.contains) == true
            }
            try await Task.sleep(for: .milliseconds(220))
            let focused = try XCTUnwrap(focusFrame(in: window))
            XCTAssertTrue(model.footerFrame.contains(focused))
            if let lastCenter { XCTAssertGreaterThan(focused.midY, lastCenter) }
            lastCenter = focused.midY
        }
        let inline = try XCTUnwrap(subtitleFrames(in: host.view).first)
        model.requested = .header
        try await waitUntil { model.focused == .header }
        model.fullscreen = true
        try await waitUntil {
            host.presentedViewController?.view.window != nil
                && host.presentedViewController?.isBeingPresented == false
                && host.presentedViewController?.view.frame == window.bounds
                && self.subtitleFrames(in: host.presentedViewController!.view).count == 1
        }
        let fullscreen = try XCTUnwrap(host.presentedViewController)
        XCTAssertEqual(fullscreen.view.frame, window.bounds)
        XCTAssertTrue([UIModalPresentationStyle.fullScreen, .overFullScreen].contains(fullscreen.modalPresentationStyle))
        let full = try XCTUnwrap(subtitleFrames(in: fullscreen.view).first)
        XCTAssertEqual(full.height / inline.height, window.bounds.width / 800, accuracy: 0.05,
                       "Full-screen preview must restore actual playback-sized glyphs, not keep the thumbnail scale.")
        let attachment = XCTAttachment(image: DetailTransitionSnapshot.image(of: window))
        attachment.name = "Full-screen subtitle preview"
        attachment.lifetime = .keepAlways
        add(attachment)

        fullscreen.dismiss(animated: false)
        try await waitUntil {
            host.presentedViewController == nil && !model.fullscreen && model.focused == .header
                && self.focusFrame(in: window).map(model.footerFrame.contains) == true
        }
        XCTAssertGreaterThan(model.footerFrame.height, 220)
        model.requested = nil
        try await waitUntil {
            model.focused == nil && abs(model.footerFrame.height - collapsedHeight) < 1
        }
        XCTAssertLessThan(try XCTUnwrap(focusFrame(in: window)).maxY, model.footerFrame.minY,
                          "Focus must leave the entire Preview section before it collapses.")
    }

    private func subtitleFrames(in view: UIView) -> [CGRect] {
        func lines(_ child: UIView) -> [SubtitleLineView] {
            if let line = child as? SubtitleLineView { return [line] }
            return child.subviews.flatMap(lines)
        }
        return lines(view).map { $0.convert($0.bounds, to: view) }
    }

    private func focusFrame(in window: UIWindow) -> CGRect? {
        guard let item = UIFocusSystem(for: window)?.focusedItem else { return nil }
        var environment: (any UIFocusEnvironment)? = item
        while let current = environment {
            if let container = current.focusItemContainer {
                return container.coordinateSpace.convert(item.frame, to: window)
            }
            environment = current.parentFocusEnvironment
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "The preview must finish its native focus/presentation transition.")
    }
}

@MainActor @Observable
private final class PreviewControlsFixtureModel {
    let options = SubtitlePreviewOptions()
    var requested: SubtitlePreviewControl?
    var focused: SubtitlePreviewControl?
    var footerFrame = CGRect.zero
    var fullscreen = false
}

private struct PreviewControlsFixture: View {
    let model: PreviewControlsFixtureModel
    @FocusState private var focus: SubtitlePreviewControl?
    @FocusState private var editorFocused: Bool
    private let style = SubtitleStyle(fontFamily: .system)

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 60) {
            VStack {
                Button("Style controls") {}
                    .focused($editorFocused)
                Spacer()
                SubtitlePreviewControls(
                    style: style, secondaryVisible: false, options: model.options,
                    fullscreenPresented: $model.fullscreen, focus: $focus
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.footerFrame = $0 }
            }
            .frame(width: SubtitleStylePanel.panelWidth, height: 740)
            SubtitleStylePreviewCanvas(
                style: style, secondaryVisible: false,
                referenceSize: SubtitleStylePreviewMetrics.televisionCanvas, animate: false
            )
            .frame(width: 800, height: 450)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
        .onChange(of: model.requested, initial: true) { _, requested in
            focus = requested
            editorFocused = requested == nil
        }
        .onChange(of: focus) { _, value in model.focused = value }
    }
}
