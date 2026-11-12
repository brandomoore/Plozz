#if DEBUG
import FeatureLiveTVCore
import SwiftUI
import XCTest
@testable import FeatureLiveTV

final class LiveTVMultiviewGeometryTests: XCTestCase {
    private let sizes = [
        CGSize(width: 1920, height: 1080), CGSize(width: 1760, height: 960),
        CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
        CGSize(width: 768, height: 1024), CGSize(width: 1440, height: 1080)
    ]

    private func expectedViewingBounds(in size: CGSize) -> CGRect {
        #if os(tvOS)
        CGRect(origin: .zero, size: size).insetBy(dx: 16, dy: 16)
        #else
        CGRect(origin: .zero, size: size)
        #endif
    }

    func testFocusPresentationInsetsEveryPictureWithoutChangingAspectOrSlots() {
        let panes = [UUID(), UUID(), UUID(), UUID()]
        let ratios: [CGFloat] = [16 / 9, 4 / 3, 21 / 9]
        for layout in LiveTVMultiviewLayout.allCases {
            for size in sizes {
                for id in panes {
                    let slot = LiveTVMultiviewGeometry.frame(
                        for: id, panes: panes, primary: panes[0], layout: layout,
                        corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size)
                    for ratio in ratios {
                        let full = LiveTVMultiviewGeometry.contentFrame(in: slot, aspectRatio: ratio)
                        let focused = LiveTVMultiviewGeometry.presentationFrame(
                            in: slot, aspectRatio: ratio, focusActive: true)
                        #if os(tvOS)
                        let inset = LiveTVMultiviewGeometry.focusInset(for: full.width)
                        XCTAssertEqual(focused.width, full.width - inset * 2, accuracy: 0.001)
                        XCTAssertEqual(focused.height, focused.width / ratio, accuracy: 0.001)
                        #else
                        XCTAssertEqual(focused, full)
                        #endif
                        XCTAssertEqual(focused.midX, full.midX, accuracy: 0.001)
                        XCTAssertEqual(focused.midY, full.midY, accuracy: 0.001)
                        XCTAssertEqual(focused.width / focused.height, ratio, accuracy: 0.001)
                        XCTAssertEqual(LiveTVMultiviewGeometry.presentationFrame(
                            in: slot, aspectRatio: ratio, focusActive: false), full)
                    }
                }
            }
        }
    }

    func testSideBySideAndPortraitPicturesUseTheAvailableCanvas() {
        let panes = [UUID(), UUID()]
        #if os(tvOS)
        let gap: CGFloat = 8
        #else
        let gap: CGFloat = 0
        #endif
        for size in sizes {
            let pictures = panes.map {
                LiveTVMultiviewGeometry.frame(
                    for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                    corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size
                )
            }
            XCTAssertTrue(pictures[0].intersection(pictures[1]).isEmpty)
            #if os(tvOS)
            let bounds = pictures[0].union(pictures[1])
            let canvas = expectedViewingBounds(in: size)
            XCTAssertEqual(bounds.midX, size.width / 2, accuracy: 0.001)
            XCTAssertEqual(bounds.midY, size.height / 2, accuracy: 0.001)
            XCTAssertTrue(abs(bounds.width - canvas.width) < 0.001 || abs(bounds.height - canvas.height) < 0.001)
            XCTAssertTrue(canvas.insetBy(dx: -0.001, dy: -0.001).contains(bounds))
            XCTAssertEqual(size.width >= size.height
                ? pictures[1].minX - pictures[0].maxX : pictures[1].minY - pictures[0].maxY,
                           gap, accuracy: 0.001)
            for picture in pictures {
                XCTAssertEqual(picture.width / picture.height, 16 / 9, accuracy: 0.001)
            }
            #else
            XCTAssertEqual(pictures[0].union(pictures[1]), CGRect(origin: .zero, size: size))
            for (id, picture) in zip(panes, pictures) {
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(picture))
                XCTAssertEqual(picture.width, size.width >= size.height ? (size.width - gap) / 2 : size.width, accuracy: 0.001)
                XCTAssertEqual(picture.height, size.width >= size.height ? size.height : (size.height - gap) / 2, accuracy: 0.001)
                XCTAssertEqual(LiveTVMultiviewGeometry.focusFrame(
                    for: id, panes: panes, primary: panes[0], layout: .sideBySide,
                    corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                    chromeVisible: false
                ), LiveTVMultiviewGeometry.contentFrame(in: picture, aspectRatio: nil))
            }
            if size.width >= size.height {
                XCTAssertEqual(pictures[0].minX, 0, accuracy: 0.001)
                XCTAssertEqual(pictures[1].minX - pictures[0].maxX, gap, accuracy: 0.001)
                XCTAssertEqual(pictures[1].maxX, size.width, accuracy: 0.001)
                XCTAssertEqual(pictures[0].minY, 0)
                XCTAssertEqual(pictures[1].maxY, size.height)
            } else {
                XCTAssertEqual(pictures[0].minY, 0, accuracy: 0.001)
                XCTAssertEqual(pictures[1].minY - pictures[0].maxY, gap, accuracy: 0.001)
                XCTAssertEqual(pictures[1].maxY, size.height, accuracy: 0.001)
                XCTAssertEqual(pictures[0].minX, 0)
                XCTAssertEqual(pictures[1].maxX, size.width)
            }
            #endif
        }
    }

    #if os(tvOS)
    func testNativeFocusClearancePreservesPackedRestingPictureSizeAndPosition() {
        let widths: [CGFloat] = [80, 441, 924, 1407]
        let ratios: [CGFloat] = [4 / 3, 16 / 9, 21 / 9]
        for layout in [LiveTVMultiviewLayout.sideBySide, .mainAndStack] {
            for width in widths {
                for ratio in ratios {
                    let picture = CGRect(x: 24, y: 73, width: width, height: width / ratio)
                    let inset = LiveTVMultiviewGeometry.focusInset(for: width)
                    let container = LiveTVMultiviewGeometry.focusContainerFrame(
                        for: picture, horizontalInset: inset, layout: layout)
                    XCTAssertGreaterThan(container.width, picture.width)
                    let resting = container.insetBy(dx: inset, dy: inset * container.height / container.width)
                    XCTAssertEqual(resting.minX, picture.minX, accuracy: 0.001)
                    XCTAssertEqual(resting.minY, picture.minY, accuracy: 0.001)
                    XCTAssertEqual(resting.width, picture.width, accuracy: 0.001)
                    XCTAssertEqual(resting.height, picture.height, accuracy: 0.001)
                    XCTAssertEqual(LiveTVMultiviewGeometry.focusContainerFrame(
                        for: picture, horizontalInset: 0, layout: layout), picture)
                    XCTAssertEqual(LiveTVMultiviewGeometry.focusContainerFrame(
                        for: picture, horizontalInset: inset, layout: .corner), picture)
                }
            }
        }
    }

    func testEditingReservesOnlyMeasuredBottomControlsAndNativeFocusClearance() {
        let size = CGSize(width: 1920, height: 1080)
        let insets = EdgeInsets(top: 24, leading: 24, bottom: 82 + 60 + 24, trailing: 24)
        let area = LiveTVMultiviewGeometry.viewport(in: size, isEditing: true, editingInsets: insets)
        XCTAssertEqual(area, CGRect(x: 24, y: 24, width: 1872, height: 890))
        let panes = [UUID(), UUID()]
        let pictures = panes.map {
            LiveTVMultiviewGeometry.frame(
                for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                isEditing: true, editingInsets: insets)
        }
        XCTAssertEqual(pictures[0].width, 924, accuracy: 0.001)
        XCTAssertEqual(pictures[1].minX - pictures[0].maxX, 24, accuracy: 0.001)
        XCTAssertEqual(pictures[0].minX, area.minX, accuracy: 0.001)
        XCTAssertEqual(pictures[1].maxX, area.maxX, accuracy: 0.001)
    }

    func testMainAndStackPacksActualPictureEdgesWithEqualGapsAndMixedAspects() {
        let panes = (0..<4).map { _ in UUID() }
        let ratioSets: [[CGFloat]] = [Array(repeating: 16 / 9, count: 4), [16 / 9, 4 / 3, 21 / 9, 16 / 9]]
        for ratios in ratioSets {
            let aspects = Dictionary(uniqueKeysWithValues: zip(panes, ratios))
            for primary in panes {
                for editing in [false, true] {
                    let size = CGSize(width: 1920, height: 1080)
                    let ordered = [primary] + panes.filter { $0 != primary }
                    let area = LiveTVMultiviewGeometry.viewport(in: size, isEditing: editing)
                    let pictures = ordered.map { id in
                        let slot = LiveTVMultiviewGeometry.frame(
                            for: id, panes: panes, primary: primary, layout: .mainAndStack,
                            corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                            isEditing: editing, aspectRatio: aspects[id], aspectRatios: aspects)
                        return LiveTVMultiviewGeometry.presentationFrame(
                            in: slot, aspectRatio: aspects[id], focusActive: editing, layout: .mainAndStack)
                    }
                    let gap: CGFloat = editing ? 24 : 8
                    for index in pictures.indices {
                        XCTAssertEqual(pictures[index].width / pictures[index].height, aspects[ordered[index]]!, accuracy: 0.001)
                        XCTAssertTrue(area.insetBy(dx: -0.001, dy: -0.001).contains(pictures[index]))
                        if index > 0 {
                            XCTAssertEqual(pictures[index].minX - pictures[0].maxX, gap, accuracy: 0.001)
                        }
                        if index > 1 {
                            XCTAssertEqual(pictures[index].minY - pictures[index - 1].maxY, gap, accuracy: 0.001)
                        }
                    }
                    XCTAssertEqual(pictures[0].minY, pictures[1].minY, accuracy: 0.001)
                    XCTAssertEqual(pictures[0].maxY, pictures[3].maxY, accuracy: 0.001)
                    let bounds = pictures.reduce(CGRect.null) { $0.union($1) }
                    XCTAssertTrue(abs(bounds.width - area.width) < 0.001 || abs(bounds.height - area.height) < 0.001)
                }
            }
        }
    }

    func testEditingGridKeepsTheSameHorizontalAndVerticalPictureGap() {
        for count in [3, 4] {
            let panes = (0..<count).map { _ in UUID() }
            let size = CGSize(width: 1920, height: 1080)
            let pictures = panes.map {
                LiveTVMultiviewGeometry.frame(
                    for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                    corner: .bottomTrailing, insetSize: .medium, expanded: nil,
                    size: size, isEditing: true)
            }
            XCTAssertEqual(pictures[1].minX - pictures[0].maxX, 24, accuracy: 0.001)
            XCTAssertEqual(pictures[2].minY - pictures[0].maxY, 24, accuracy: 0.001)
            XCTAssertGreaterThan(pictures[0].width, 750)
            for picture in pictures {
                XCTAssertEqual(picture.width / picture.height, 16 / 9, accuracy: 0.001)
            }
        }
    }

    func testWidenedGridHasEqualEightPointPictureGapsAtEverySizeAndAspect() {
        for count in [3, 4] {
            let panes = (0..<count).map { _ in UUID() }
            let mixed: [CGFloat] = [16 / 9, 4 / 3, 21 / 9, 16 / 9]
            for ratios in [Array(repeating: CGFloat(16) / 9, count: count),
                           Array(mixed.prefix(count))] {
                let aspects = Dictionary(uniqueKeysWithValues: zip(panes, ratios))
                for size in sizes {
                    let canvas = expectedViewingBounds(in: size)
                    let pictures = panes.map {
                        LiveTVMultiviewGeometry.frame(
                            for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                            corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                            aspectRatio: aspects[$0], aspectRatios: aspects)
                    }
                    let bounds = pictures.reduce(CGRect.null) { $0.union($1) }
                    XCTAssertEqual(bounds.midX, canvas.midX, accuracy: 0.001)
                    XCTAssertEqual(bounds.midY, canvas.midY, accuracy: 0.001)
                    XCTAssertTrue(abs(bounds.width - canvas.width) < 0.001 || abs(bounds.height - canvas.height) < 0.001)
                    XCTAssertTrue(canvas.insetBy(dx: -0.001, dy: -0.001).contains(bounds))
                    for (picture, ratio) in zip(pictures, ratios) {
                        XCTAssertEqual(picture.width / picture.height, ratio, accuracy: 0.001)
                    }
                    XCTAssertEqual(pictures[1].minX - pictures[0].maxX, 8, accuracy: 0.001)
                    XCTAssertEqual(pictures[2].minY - pictures[0].maxY, 8, accuracy: 0.001)
                    if count == 4 {
                        XCTAssertEqual(pictures[3].minX - pictures[2].maxX, 8, accuracy: 0.001)
                    }
                    for id in panes {
                        XCTAssertEqual(LiveTVMultiviewGeometry.frame(
                            for: id, panes: panes, primary: panes[0], layout: .sideBySide,
                            corner: .bottomTrailing, insetSize: .medium, expanded: id, size: size), canvas)
                    }
                }
            }
        }
    }
    #endif

    func testCornerPrimaryUsesPaddedCanvasWhileInsetKeepsPresentationAspect() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            let canvas = expectedViewingBounds(in: size)
            for corner in LiveTVMultiviewCorner.allCases {
                for insetSize in LiveTVMultiviewInsetSize.allCases {
                    let main = LiveTVMultiviewGeometry.frame(
                        for: panes[0], panes: panes, primary: panes[0], layout: .corner,
                        corner: corner, insetSize: insetSize, expanded: nil, size: size
                    )
                    let inset = LiveTVMultiviewGeometry.frame(
                        for: panes[1], panes: panes, primary: panes[0], layout: .corner,
                        corner: corner, insetSize: insetSize, expanded: nil, size: size
                    )
                    XCTAssertEqual(main, canvas)
                    XCTAssertTrue(main.contains(inset))
                    let insetCanvasWidth = min(canvas.width, canvas.height * 16 / 9)
                    XCTAssertEqual(inset.width, insetCanvasWidth * CGFloat(insetSize.fraction), accuracy: 0.001)
                    XCTAssertEqual(inset.width / inset.height, 16 / 9, accuracy: 0.001)
                }
            }
        }
    }

    func testPhysicalBoundsRetainNegativeSafeAreaOriginForVideoAndOverlay() {
        let id = UUID()
        let layout = PrototypePreviewLayout(
            size: CGSize(width: 1760, height: 960),
            safeAreaInsets: EdgeInsets(top: 60, leading: 80, bottom: 60, trailing: 80)
        )
        let picture = LiveTVMultiviewGeometry.frame(
            for: id, panes: [id], primary: id, layout: .sideBySide,
            corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: layout.bounds.size
        ).offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY)
        XCTAssertEqual(layout.bounds, CGRect(x: -80, y: -60, width: 1920, height: 1080))
        XCTAssertEqual(picture, expectedViewingBounds(in: layout.bounds.size)
            .offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY))
        XCTAssertEqual(
            LiveTVMultiviewGeometry.viewport(in: layout.bounds.size)
                .offsetBy(dx: layout.bounds.minX, dy: layout.bounds.minY),
            picture
        )
    }

    func testVisibleChromeReservesFocusBandsWithinViewingMargins() {
        for size in sizes {
            let canvas = expectedViewingBounds(in: size)
            let focusArea = LiveTVMultiviewGeometry.focusViewport(in: size, chromeVisible: true)
            XCTAssertEqual(LiveTVMultiviewGeometry.viewport(in: size), canvas)
            XCTAssertEqual(LiveTVMultiviewGeometry.focusViewport(in: size, chromeVisible: false), canvas)
            XCTAssertTrue(canvas.contains(focusArea))
            XCTAssertEqual(focusArea.minX, canvas.minX)
            XCTAssertEqual(focusArea.maxX, canvas.maxX)
            XCTAssertGreaterThan(focusArea.minY, canvas.minY)
            XCTAssertLessThan(focusArea.maxY, canvas.maxY)
            #if os(tvOS)
            if size.height >= 960 {
                let header = CGRect(x: 80, y: 60, width: size.width - 160, height: 74)
                let toolbar = CGRect(x: 80, y: size.height - 142, width: size.width - 160, height: 90)
                XCTAssertFalse(focusArea.intersects(header))
                XCTAssertFalse(focusArea.intersects(toolbar))
            }
            #endif
        }
    }

    func testCornerFocusAndCaptionRegionsRemainDisjointWithChromeShownOrHidden() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            for primary in panes {
                let secondary = panes.first { $0 != primary }!
                for corner in LiveTVMultiviewCorner.allCases {
                    for insetSize in LiveTVMultiviewInsetSize.allCases {
                        let main = LiveTVMultiviewGeometry.frame(
                            for: primary, panes: panes, primary: primary, layout: .corner,
                            corner: corner, insetSize: insetSize, expanded: nil, size: size
                        )
                        let inset = LiveTVMultiviewGeometry.frame(
                            for: secondary, panes: panes, primary: primary, layout: .corner,
                            corner: corner, insetSize: insetSize, expanded: nil, size: size
                        )
                        for chromeVisible in [false, true] {
                            let mainFocus = LiveTVMultiviewGeometry.focusFrame(
                                for: primary, panes: panes, primary: primary, layout: .corner,
                                corner: corner, insetSize: insetSize, expanded: nil, size: size,
                                chromeVisible: chromeVisible
                            )
                            let insetFocus = LiveTVMultiviewGeometry.focusFrame(
                                for: secondary, panes: panes, primary: primary, layout: .corner,
                                corner: corner, insetSize: insetSize, expanded: nil, size: size,
                                chromeVisible: chromeVisible
                            )
                            let context = "\(size), \(corner), \(insetSize), chrome \(chromeVisible)"
                            XCTAssertGreaterThan(mainFocus.width, 0, context)
                            XCTAssertGreaterThan(mainFocus.height, 0, context)
                            XCTAssertGreaterThan(insetFocus.width, 0, context)
                            XCTAssertGreaterThan(insetFocus.height, 0, context)
                            XCTAssertTrue(main.insetBy(dx: -0.001, dy: -0.001).contains(mainFocus), context)
                            XCTAssertTrue(inset.insetBy(dx: -0.001, dy: -0.001).contains(insetFocus), context)
                            XCTAssertFalse(mainFocus.intersects(insetFocus), context)
                            XCTAssertLessThan(mainFocus.minY, insetFocus.maxY, context)
                            XCTAssertGreaterThan(mainFocus.maxY, insetFocus.minY, context)
                            if corner == .topLeading || corner == .bottomLeading {
                                XCTAssertEqual(mainFocus.minX - insetFocus.maxX, 16, accuracy: 0.001, context)
                            } else {
                                XCTAssertEqual(insetFocus.minX - mainFocus.maxX, 16, accuracy: 0.001, context)
                            }
                        }
                    }
                }
            }
        }
    }

    func testSingleAndExpandedMultiviewPicturesReceivePaddedCanvasAndHiddenChromeFocusRegion() {
        let panes = [UUID(), UUID()]
        for size in sizes {
            let canvas = expectedViewingBounds(in: size)
            for layout in LiveTVMultiviewLayout.allCases {
                XCTAssertEqual(LiveTVMultiviewGeometry.frame(
                    for: panes[0], panes: [panes[0]], primary: panes[0], layout: layout,
                    corner: .bottomTrailing, insetSize: .large, expanded: nil, size: size
                ), canvas)
                for expanded in panes {
                    let picture = LiveTVMultiviewGeometry.frame(
                        for: expanded, panes: panes, primary: panes[0], layout: layout,
                        corner: .bottomTrailing, insetSize: .large, expanded: expanded, size: size
                    )
                    XCTAssertEqual(picture, canvas)
                    let focus = LiveTVMultiviewGeometry.focusFrame(
                        for: expanded, panes: panes, primary: panes[0], layout: layout,
                        corner: .bottomTrailing, insetSize: .large, expanded: expanded, size: size,
                        chromeVisible: false
                    )
                    let content = LiveTVMultiviewGeometry.contentFrame(in: picture, aspectRatio: nil)
                    XCTAssertEqual(focus.minX, content.minX, accuracy: 0.001)
                    XCTAssertEqual(focus.minY, content.minY, accuracy: 0.001)
                    XCTAssertEqual(focus.width, content.width, accuracy: 0.001)
                    XCTAssertEqual(focus.height, content.height, accuracy: 0.001)
                }
            }
        }
    }

    func testChromeEditingLatchSurvivesNativeMenuActivityUntilPaneFocus() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.activity(at: 1)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        chrome.editing(at: 2)
        chrome.activity(at: 20)
        XCTAssertTrue(chrome.isVisible)
        XCTAssertTrue(chrome.isEditing)
        #if os(tvOS)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        #else
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
        #endif
        chrome.watching(at: 21)
        XCTAssertFalse(chrome.isEditing)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        XCTAssertEqual(chrome.inactivity.remainingDelay(startedAt: 21, now: 24), 1)
        chrome.hide()
        XCTAssertFalse(chrome.isVisible)
        XCTAssertFalse(chrome.isEditing)
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
        chrome.activity(at: 30)
        XCTAssertTrue(chrome.isVisible)
    }

    func testVoiceOverPickerAndErrorBlockingPreventsChromeAutoHide() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.watching(at: 1)
        XCTAssertFalse(chrome.canAutoHide(blocked: true))
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        chrome.editing(at: 2)
        XCTAssertFalse(chrome.canAutoHide(blocked: true))
        #if os(tvOS)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
        #else
        XCTAssertFalse(chrome.canAutoHide(blocked: false))
        #endif
    }

    func testNativeMenuFocusActivityDoesNotPublishAnyStateChangesWhileEditing() {
        var chrome = LiveTVMultiviewChromeState()
        chrome.editing(at: 1)
        let pinned = chrome
        for event in 2...1_000 {
            chrome.activity(at: TimeInterval(event), blocked: true)
            chrome.editing(at: TimeInterval(event), blocked: true)
            XCTAssertEqual(chrome, pinned, "Native menu focus must not redraw its own anchor")
        }
        chrome.watching(at: 1_001)
        XCTAssertEqual(chrome.inactivity.lastInteractionAt, 1_001)
        XCTAssertTrue(chrome.canAutoHide(blocked: false))
    }

    func testThreeAndFourChannelGridsFitCanvasWithoutOverlap() {
        for count in 3...4 {
            let panes = (0..<count).map { _ in UUID() }
            for size in sizes {
                let frames = panes.map {
                    LiveTVMultiviewGeometry.frame(
                        for: $0, panes: panes, primary: panes[0], layout: .sideBySide,
                        corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size)
                }
                let canvas = CGRect(origin: .zero, size: size)
                let bounds = frames.reduce(CGRect.null) { $0.union($1) }
                #if os(tvOS)
                XCTAssertTrue(canvas.insetBy(dx: -0.001, dy: -0.001).contains(bounds))
                #else
                XCTAssertEqual(bounds, canvas)
                #endif
                for index in frames.indices {
                    XCTAssertGreaterThan(frames[index].width, 0)
                    for other in frames.indices where other > index {
                        XCTAssertFalse(frames[index].intersects(frames[other]))
                    }
                }
            }
        }
    }

    func testFourCornerPicturesAndFocusTargetsStayReachableWithoutOverlapping() {
        let panes = (0..<4).map { _ in UUID() }
        for size in sizes {
            for corner in LiveTVMultiviewCorner.allCases {
                for editing in [true, false] {
                    let frames = panes.map {
                        LiveTVMultiviewGeometry.frame(
                            for: $0, panes: panes, primary: panes[0], layout: .corner,
                            corner: corner, insetSize: .large, expanded: nil, size: size, isEditing: editing)
                    }
                    let focus = panes.map {
                        LiveTVMultiviewGeometry.focusFrame(
                            for: $0, panes: panes, primary: panes[0], layout: .corner,
                            corner: corner, insetSize: .large, expanded: nil, size: size,
                            chromeVisible: false, isEditing: editing)
                    }
                    for index in focus.indices {
                        XCTAssertFalse(focus[index].isEmpty)
                        XCTAssertTrue(frames[index].insetBy(dx: -0.01, dy: -0.01).contains(focus[index]))
                        for other in focus.indices where other > index {
                            XCTAssertFalse(focus[index].intersects(focus[other]))
                        }
                    }
                }
            }
        }
    }

    func testSetupFocusHugsActualVideoAspectInsteadOfTheFullScreenSlot() {
        let panes = [UUID(), UUID()]
        let size = CGSize(width: 1920, height: 1080)
        for ratio in [CGFloat(4) / 3, CGFloat(16) / 9, CGFloat(21) / 9] {
            let frame = LiveTVMultiviewGeometry.frame(
                for: panes[0], panes: panes, primary: panes[0], layout: .sideBySide,
                corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                isEditing: true, aspectRatio: ratio)
            let focus = LiveTVMultiviewGeometry.focusFrame(
                for: panes[0], panes: panes, primary: panes[0], layout: .sideBySide,
                corner: .bottomTrailing, insetSize: .medium, expanded: nil, size: size,
                chromeVisible: true, isEditing: true, aspectRatio: ratio)
            XCTAssertEqual(frame.width / frame.height, ratio, accuracy: 0.001)
            XCTAssertEqual(focus.minX, frame.minX, accuracy: 0.001)
            XCTAssertEqual(focus.minY, frame.minY, accuracy: 0.001)
            XCTAssertEqual(focus.width, frame.width, accuracy: 0.001)
            XCTAssertEqual(focus.height, frame.height, accuracy: 0.001)
            XCTAssertGreaterThan(frame.minX, 0)
            XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertLessThan(frame.maxY, size.height)
        }
    }

    func testMainAndStackHasOneLargeLeftPictureAndThreeNonoverlappingRightPictures() {
        let panes = (0..<4).map { _ in UUID() }
        for size in sizes {
            for editing in [false, true] {
                let frames = panes.map {
                    LiveTVMultiviewGeometry.frame(
                        for: $0, panes: panes, primary: panes[0], layout: .mainAndStack,
                        corner: .bottomTrailing, insetSize: .medium, expanded: nil,
                        size: size, isEditing: editing)
                }
                XCTAssertGreaterThan(frames[0].width, frames[1].width * 2)
                for index in 1..<4 {
                    XCTAssertGreaterThan(frames[index].minX, frames[0].maxX)
                    XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frames[index]))
                    if index > 1 {
                        XCTAssertGreaterThan(frames[index].minY, frames[index - 1].maxY)
                    }
                }
                for index in frames.indices {
                    for other in frames.indices where other > index {
                        XCTAssertFalse(frames[index].intersects(frames[other]))
                    }
                }
            }
        }
    }
}
#endif
