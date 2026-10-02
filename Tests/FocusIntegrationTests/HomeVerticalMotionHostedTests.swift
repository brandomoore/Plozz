#if os(tvOS)
import CoreUI
@testable import FeatureHome
import Observation
import SwiftUI
import UIKit
import XCTest

@MainActor
final class HomeVerticalMotionHostedTests: XCTestCase {
    func testUpwardMomentumIntoShortRowDoesNotInjectHeightVelocity() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = FocusHeroModel()
        let references = MotionReferences()
        let rows = (0..<5).map { FocusHeroRow(id: "row-\($0)", itemIDs: [], leadItem: nil) }
        let heights: [CGFloat] = [340, 510, 510, 510, 510]
        for (row, height) in zip(rows, heights) { model.record(height: height, for: row.id) }
        model.activate(rows[4], in: rows)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            FocusHeroScrollingRows(rows: rows, model: model) { row, _ in
                Color.gray.frame(height: (row.id == rows[0].id ? heights[0] : heights[1])
                                 + FocusHeroLayout.rowBottomTightening)
                    .overlay(alignment: .bottomLeading) {
                        if row.id == rows[0].id {
                            MotionProbe(references: references, shared: true).frame(width: 80, height: 30)
                        }
                    }
            }
            .frame(width: 1920, height: 1080)
            .background(.black)
            .ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(firstScrollView(in: window))
        let mask = try XCTUnwrap(model.motion.mask)
        let shortRow = try XCTUnwrap(references.shared)
        let tallMaskY = mask.transform.ty
        for index in [3, 2, 1] {
            model.activate(rows[index], in: rows)
            try await Task.sleep(for: .milliseconds(110))
        }
        let beforeY = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
        try await Task.sleep(for: .milliseconds(30))
        let arrivingY = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
        XCTAssertLessThan(arrivingY, beforeY - 30, "Arrive with real upward momentum, not from rest.")
        XCTAssertEqual(try XCTUnwrap(mask.layer.presentation()).affineTransform().ty, tallMaskY, accuracy: 1)
        let tuckedY = visibleY(shortRow, in: window) + arrivingY
        model.activate(rows[0], in: rows)
        let changedAt = CACurrentMediaTime()
        var samples: [String] = []
        var maximumExcess: CGFloat = 0
        var maximumTuckDifference: CGFloat = 0
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(20))
            let elapsed = CACurrentMediaTime() - changedAt
            let maskY = try XCTUnwrap(mask.layer.presentation()).affineTransform().ty
            let expected = tallMaskY + FocusHeroLayout.rowSpring.value(
                target: heights[1] - heights[0], initialVelocity: 0, time: elapsed
            )
            maximumExcess = max(maximumExcess, maskY - expected)
            let offset = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
            let untuck = visibleY(shortRow, in: window) + offset - tuckedY
            let expectedUntuck = FocusHeroLayout.rowSpring.value(
                target: FocusHeroLayout.rowTuck, initialVelocity: 0, time: elapsed
            )
            maximumTuckDifference = max(maximumTuckDifference, abs(untuck - expectedUntuck))
            samples.append("elapsed=\(elapsed) scroll=\(offset) mask=\(maskY) expected=\(expected) untuck=\(untuck) expectedUntuck=\(expectedUntuck)")
        }
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "Upward poster-row momentum entering Continue Watching"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(maximumExcess, 8,
                          "The height was stationary across poster rows; it must not inherit the viewport's existing velocity.")
        XCTAssertLessThan(maximumTuckDifference, 8,
                          "The returning short row must release concealment continuously without interrupting its native motion.")
    }

    func testHeightChangingRowsKeepHeroAlignedWithNativePresentation() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = FocusHeroModel()
        let references = MotionReferences()
        let rows = (0..<2).map { FocusHeroRow(id: "row-\($0)", itemIDs: [], leadItem: nil) }
        let heights: [CGFloat] = [340, 510]
        for (row, height) in zip(rows, heights) { model.record(height: height, for: row.id) }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            ZStack(alignment: .topLeading) {
                FocusHeroScrollingRows(rows: rows, model: model) { row, _ in
                    Color.gray.frame(height: (row.id == rows[0].id ? heights[0] : heights[1])
                                     + FocusHeroLayout.rowBottomTightening)
                }
                FocusHeroColumnMotion(
                    content: MotionProbe(references: references, shared: true).frame(width: 80, height: 30),
                    model: model
                )
            }
            .frame(width: 1920, height: 1080)
            .background(.black)
            .ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(firstScrollView(in: window))
        let column = try XCTUnwrap(references.shared)
        let mask = try XCTUnwrap(model.motion.mask)
        let initialY = visibleY(column, in: window)
        let initialMaskY = mask.transform.ty
        let distance = heights[1] + FocusHeroLayout.rowSpacing
        var maximumDifference: CGFloat = 0
        var maximumMaskDifference: CGFloat = 0
        var samples: [String] = []
        for index in [1, 0, 1, 0] {
            model.activate(rows[index], in: rows)
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(20))
                let offset = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
                let expectedY = initialY - (heights[1] - heights[0]) * offset / distance
                let columnY = visibleY(column, in: window)
                let maskY = try XCTUnwrap(mask.layer.presentation()).affineTransform().ty
                maximumDifference = max(maximumDifference, abs(columnY - expectedY))
                let expectedMaskY = initialMaskY - (heights[1] - heights[0]) * offset / distance
                maximumMaskDifference = max(maximumMaskDifference, abs(maskY - expectedMaskY))
                samples.append("row=\(index) scroll=\(offset) column=\(columnY) expected=\(expectedY) mask=\(maskY) expectedMask=\(expectedMaskY)")
            }
        }
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "Height-changing row and hero presentation"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(maximumDifference, 8,
                          "Continue Watching and poster-row height changes must follow the native slide, including reversals.")
        XCTAssertLessThan(maximumMaskDifference, 8, "The outgoing-row concealment must share the same motion.")
    }

    func testRapidCompositorMovesKeepRowsPaintedBetweenDestinations() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let model = FocusHeroModel()
        let rows = (0..<12).map { FocusHeroRow(id: "row-\($0)", itemIDs: [], leadItem: nil) }
        // Known heights reproduce revisiting real rows without conflating lazy
        // realization with initial measurement or provider loading.
        for row in rows {
            model.record(height: 480 - FocusHeroLayout.rowBottomTightening, for: row.id)
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            FocusHeroScrollingRows(rows: rows, model: model) { _, _ in
                Color.white.frame(height: 480)
            }
            .frame(width: 1920, height: 1080)
            .background(.black)
            .ignoresSafeArea()
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(300))
        let scroll = try XCTUnwrap(firstScrollView(in: window))
        var intermediateSamples = 0
        var minimumPaintedPixels = 350
        for index in Array(1...8) + Array((0...7).reversed()) {
            model.activate(rows[index], in: rows)
            try await Task.sleep(for: .milliseconds(90))
            let presentedY = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
            if abs(scroll.contentOffset.y - presentedY) > 20 {
                intermediateSamples += 1
                minimumPaintedPixels = min(minimumPaintedPixels, try paintedRowPixels(in: window))
            }
        }
        XCTAssertGreaterThan(intermediateSamples, 8, "Exercise the slide, not only settled destinations.")
        XCTAssertGreaterThan(minimumPaintedPixels, 150,
                             "Rows visible in the presentation viewport must not be recycled for the logical destination.")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5)
        XCTAssertGreaterThan(try paintedRowPixels(in: window), 300)
    }

    func testCompositorScrollHasIntermediatePresentationAndContinuousReversal() async throws {
        continueAfterFailure = false
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        let scroll = UIScrollView(frame: CGRect(x: 100, y: 100, width: 800, height: 700))
        scroll.contentSize = CGSize(width: 800, height: 2400)
        let position = FocusHeroNativeScrollPosition.PositionView()
        position.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        scroll.addSubview(position)
        window.rootViewController?.view.addSubview(scroll)
        window.makeKeyAndVisible()
        defer {
            position.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        position.move(to: 0, rowID: "first")
        try await Task.sleep(for: .milliseconds(100))
        position.move(to: 480, rowID: "second")
        try await Task.sleep(for: .milliseconds(100))
        var before = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
        XCTAssertEqual(scroll.contentOffset.y, 480)
        XCTAssertGreaterThan(before, 1)
        XCTAssertLessThan(before, 479)
        XCTAssertFalse((scroll.layer.animationKeys() ?? []).isEmpty)
        var previousVelocity: CGFloat = 0
        for (row, destination) in [("third", CGFloat(960)), ("fourth", CGFloat(1440))] {
            let sampleTime = CACurrentMediaTime()
            let sampleY = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
            try await Task.sleep(for: .milliseconds(40))
            let beforeTime = CACurrentMediaTime()
            before = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
            previousVelocity = (before - sampleY) / (beforeTime - sampleTime)
            XCTAssertGreaterThan(previousVelocity, 300)
            position.move(to: destination, rowID: row)
            try await Task.sleep(for: .milliseconds(40))
            let after = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
            let velocity = (after - before) / (CACurrentMediaTime() - beforeTime)
            XCTAssertGreaterThan(velocity, previousVelocity * 0.65,
                                 "Another Down must carry motion forward instead of restarting from rest.")
        }
        before = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
        position.move(to: 0, rowID: "first")
        try await Task.sleep(for: .milliseconds(20))
        let reversed = try XCTUnwrap(scroll.layer.presentation()).bounds.minY
        XCTAssertEqual(reversed, before, accuracy: max(80, previousVelocity * 0.06),
                       "Reversal must start at the painted position, not the old target.")
        XCTAssertGreaterThan(reversed, before,
                             "Reversal must brake the forward momentum, not instantly reverse its velocity.")
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(scroll.contentOffset.y, 0)
        XCTAssertEqual(try XCTUnwrap(scroll.layer.presentation()).bounds.minY, 0, accuracy: 0.5)
    }

    func testNativeShowcaseColumnMatchesPaintedOffsetAfterRelayoutAndReversal() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = MotionState()
        let references = MotionReferences()
        let model = FocusHeroModel()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            HStack(alignment: .top, spacing: 40) {
                OriginalMotionFixture(state: original, references: references)
                IsolatedShowcaseMotionFixture(model: model, references: references)
                    .frame(width: 200, height: 120)
            }
            .padding(.top, 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(references.original)
        let second = try XCTUnwrap(references.shared)
        for height in [CGFloat(340), 390, 440, 490, 540, 490, 440, 390, 340] {
            let offset = max(FocusHeroLayout.lowestSlotTop,
                             FocusHeroLayout.rowsBottom(rowSpacing: FocusHeroLayout.rowSpacing) - height)
                - FocusHeroLayout.lowestSlotTop
            model.motion.height = height
            model.motion.applyTargets()
            original.y = offset
            try await Task.sleep(for: .milliseconds(25))
            window.setNeedsLayout()
            window.layoutIfNeeded()
            let positions = try pixelPositions(first, second, in: window)
            XCTAssertEqual(positions.0, positions.1, accuracy: 1, "Isolated drawing must preserve the original pixels.")
            XCTAssertEqual(visibleY(first, in: window), visibleY(second, in: window), accuracy: 0.5)
        }
    }

    func testSharedOffsetMatchesOriginalMotionAndReversal() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let original = MotionState()
        let shared = MotionState()
        let references = MotionReferences()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = UIHostingController(rootView:
            HStack(alignment: .top, spacing: 40) {
                OriginalMotionFixture(state: original, references: references)
                SharedMotionFixture(state: shared, references: references)
            }
            .padding(.top, 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.black)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(references.original)
        let second = try XCTUnwrap(references.shared)
        let firstOrigin = visibleY(first, in: window)
        let secondOrigin = visibleY(second, in: window)
        let initialPixels = try pixelPositions(first, second, in: window)
        var maximumDifference: CGFloat = 0
        var maximumGeometryDifference: CGFloat = 0
        var originalAnimated = false
        var sawIntermediate = false
        var samples: [String] = []

        withAnimation(.smooth(duration: 0.9)) {
            original.y = -170
            shared.y = -170
        }
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(25))
            let positions = try pixelPositions(first, second, in: window)
            let a = positions.0 - initialPixels.0
            let b = positions.1 - initialPixels.1
            maximumDifference = max(maximumDifference, abs(a - b))
            maximumGeometryDifference = max(maximumGeometryDifference, abs(
                (visibleY(first, in: window) - firstOrigin) - (visibleY(second, in: window) - secondOrigin)
            ))
            if a < -1 && a > -169 { originalAnimated = true }
            if b < -1 && b > -169 { sawIntermediate = true }
            samples.append("down original=\(a) shared=\(b)")
        }
        XCTAssertTrue(originalAnimated, "The original control must visibly animate for this comparison to be valid.")
        XCTAssertTrue(sawIntermediate, "Down must animate rather than snap.")

        withAnimation(.smooth(duration: 0.9)) {
            original.y = 0
            shared.y = 0
        }
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertLessThan(try pixelPositions(first, second, in: window).1 - initialPixels.1, -1,
                          "Up must not snap to rest.")
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(25))
            let positions = try pixelPositions(first, second, in: window)
            let a = positions.0 - initialPixels.0
            let b = positions.1 - initialPixels.1
            maximumDifference = max(maximumDifference, abs(a - b))
            maximumGeometryDifference = max(maximumGeometryDifference, abs(
                (visibleY(first, in: window) - firstOrigin) - (visibleY(second, in: window) - secondOrigin)
            ))
            samples.append("up original=\(a) shared=\(b)")
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(visibleY(first, in: window), firstOrigin, accuracy: 0.5)
        XCTAssertEqual(visibleY(second, in: window), secondOrigin, accuracy: 0.5)
        XCTAssertEqual(first.bounds.size, second.bounds.size)
        let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
        attachment.name = "Original and shared position samples"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThanOrEqual(maximumDifference, 1, "The original curve and reversal must be retained.")
        XCTAssertLessThanOrEqual(maximumGeometryDifference, 1, "Reported UIKit geometry must match the original.")
    }

    private func visibleY(_ view: UIView, in window: UIWindow) -> CGFloat {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer).minY
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }

    private func paintedRowPixels(in window: UIWindow) throws -> Int {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let bytes = Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
        return (600..<950).filter { y in
            let offset = y * cg.bytesPerRow + 1000 * 4
            return bytes[offset] > 245 && bytes[offset + 1] > 245 && bytes[offset + 2] > 245
        }.count
    }

    private func pixelPositions(_ first: UIView, _ second: UIView, in window: UIWindow) throws -> (CGFloat, CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let cg = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cg.bitsPerPixel, 32)
        let bytes = Array(try XCTUnwrap(cg.dataProvider?.data) as Data)
        func top(of view: UIView) throws -> CGFloat {
            let x = Int(view.convert(view.bounds, to: window).midX)
            let y = try XCTUnwrap((0..<cg.height).first {
                let offset = $0 * cg.bytesPerRow + x * 4
                return bytes[offset] > 245 && bytes[offset + 1] > 245 && bytes[offset + 2] > 245
            })
            return CGFloat(y)
        }
        return (try top(of: first), try top(of: second))
    }
}

@MainActor @Observable
private final class MotionState {
    var y: CGFloat = 0
}

@MainActor
private final class MotionReferences {
    var original: UIView?
    var shared: UIView?
}

private struct OriginalMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, shared: false)
            .frame(width: 200, height: 120)
            .offset(y: state.y)
    }
}

private struct SharedMotionFixture: View {
    let state: MotionState
    let references: MotionReferences

    var body: some View {
        MotionProbe(references: references, shared: true)
            .frame(width: 200, height: 120)
            .modifier(HomeVerticalMotion(y: state.y))
    }
}

private struct IsolatedShowcaseMotionFixture: View {
    let model: FocusHeroModel
    let references: MotionReferences

    var body: some View {
        FocusHeroColumnMotion(
            content: MotionProbe(references: references, shared: true).frame(width: 200, height: 120),
            model: model
        )
    }
}

private struct MotionProbe: UIViewRepresentable {
    let references: MotionReferences
    let shared: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .white
        if shared { references.shared = view } else { references.original = view }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {}
}
#endif
