#if os(tvOS)
import XCTest
import UIKit
import CoreUI
@testable import AppShell

@MainActor
final class NavigationContentFocusRequesterTests: XCTestCase {
    func testNativeEntrySkipsGlobalFocusQueriesAndRevalidatesTargets() {
        let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.isHidden = false
        defer { window.isHidden = true }
        let marker = UIView(frame: window.bounds)
        window.addSubview(marker)
        let cards = (0..<3).map { index in
            let card = UIButton(frame: CGRect(x: 500 + index * 300, y: 300, width: 250, height: 350))
            let region = NavigationEntryFocusRegionView(frame: card.bounds)
            region.preference = .content
            region.nativeFocusItem = card
            card.addSubview(region)
            window.addSubview(card)
            return card
        }
        for (rtl, expected) in [(false, 0), (true, 2)] {
            XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
                in: window, relativeTo: marker, isRightToLeft: rtl
            ) === cards[expected])
        }
        let clipped = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 1080))
        clipped.clipsToBounds = true
        window.addSubview(clipped)
        clipped.addSubview(cards[0])
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === cards[1], "A card clipped by its scroll container is not an entry target.")
        clipped.clipsToBounds = false
        clipped.isUserInteractionEnabled = false
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === cards[1])
        window.addSubview(cards[0])
        cards[0].isEnabled = false
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === cards[1])
        cards[1].isHidden = true
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === cards[2])
        XCTAssertEqual(window.queryCount, 0, "Known native cards must not enumerate the whole page or navigation.")
    }

    func testMixedNativeAndVirtualRegionsRetainFullDiscovery() {
        let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.isHidden = false
        defer { window.isHidden = true }
        let marker = UIView(frame: window.bounds)
        window.addSubview(marker)
        let native = UIButton(frame: CGRect(x: 900, y: 300, width: 250, height: 350))
        let nativeRegion = NavigationEntryFocusRegionView(frame: native.bounds)
        nativeRegion.preference = .content
        nativeRegion.nativeFocusItem = native
        native.addSubview(nativeRegion)
        window.addSubview(native)
        window.extraItems = [native]
        window.page.frame = CGRect(x: 500, y: 300, width: 250, height: 350)
        window.addSubview(window.page)
        let virtualRegion = NavigationEntryFocusRegionView(frame: window.page.frame)
        virtualRegion.preference = .content
        window.addSubview(virtualRegion)
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === window.page, "A later native item must not hide an earlier virtual focus target.")
        XCTAssertEqual(window.queryCount, 1)
    }

    func testContentInNestedControllerIsNotOmittedByWindowQuery() {
        let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.includesPage = false
        let root = UIViewController()
        window.rootViewController = root
        root.view.frame = window.bounds
        window.addSubview(root.view)
        window.isHidden = false
        defer { window.isHidden = true }
        let child = UIViewController()
        let content = ContentFocusContainer(frame: window.bounds)
        content.page.frame = CGRect(x: 100, y: 65, width: 200, height: 70)
        content.addSubview(content.page)
        child.view = content
        root.addChild(child)
        let wrapper = UIView(frame: window.bounds)
        root.view.addSubview(wrapper)
        wrapper.addSubview(content)
        child.didMove(toParent: root)
        let marker = UIView(frame: window.bounds)
        root.view.addSubview(marker)
        root.view.addSubview(NavigationRowFocusRequester.RequestView(
            frame: CGRect(x: 48, y: 60, width: 404, height: 44)
        ))
        let target = NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        )
        XCTAssertTrue(target === content.page)
        XCTAssertEqual(window.queryCount, 1)
        XCTAssertEqual(content.queryCount, 1)
        let direct = NavigationEntryFocusRegionView(frame: content.page.bounds)
        direct.preference = .content
        direct.nativeFocusItem = content.page
        content.page.addSubview(direct)
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ) === content.page, "Expanded rail overlap must not exclude the declared native page target.")
        XCTAssertEqual(window.queryCount, 1)
        XCTAssertEqual(content.queryCount, 1)
        wrapper.isHidden = true
        XCTAssertNil(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: marker, isRightToLeft: false
        ), "Retained native controllers inside a hidden page must remain ineligible.")
        XCTAssertEqual(content.queryCount, 1)
    }

    func testEntryPrefersContentThenDeclaredFallbackAndWaitsForLoading() {
        let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.isHidden = false
        defer { window.isHidden = true }
        let page = UIView(frame: window.bounds)
        window.addSubview(page)
        window.page.frame = CGRect(x: 700, y: 100, width: 200, height: 70)
        window.addSubview(window.page)
        let recent = UIButton(frame: CGRect(x: 700, y: 350, width: 200, height: 250))
        window.addSubview(recent)
        window.extraItems = [recent]
        let content = NavigationEntryFocusRegionView(frame: recent.frame)
        content.preference = .content
        window.addSubview(content)
        let fallback = NavigationEntryFocusRegionView(frame: window.page.frame)
        fallback.preference = .fallback
        window.addSubview(fallback)
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: page, isRightToLeft: false
        ) === recent)
        recent.isEnabled = false
        XCTAssertTrue(NavigationContentFocusRequester.firstTarget(
            in: window, relativeTo: page, isRightToLeft: false
        ) === window.page)
        let pending = NavigationEntryFocusRegionView(frame: window.bounds)
        pending.preference = .pending
        window.addSubview(pending)
        let waiting = NavigationContentFocusRequester.entrySelection(
            in: window, relativeTo: page, isRightToLeft: false
        )
        XCTAssertTrue(waiting.isPending)
        XCTAssertNil(waiting.target)
        pending.preference = nil
        XCTAssertFalse(NavigationContentFocusRequester.entrySelection(
            in: window, relativeTo: page, isRightToLeft: false
        ).isPending)
    }

    func testScrolledRowsOverlappingProfileAreAllExcluded() throws {
        let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.isHidden = false
        defer { window.isHidden = true }
        window.profileFrame = CGRect(x: 74, y: 90, width: 318, height: 64)
        window.scrolledRow = UIButton(frame: CGRect(x: 46, y: 96.5, width: 318, height: 64))
        window.addSubview(try XCTUnwrap(window.scrolledRow))
        window.page.frame = CGRect(x: 700, y: 150, width: 200, height: 70)
        window.addSubview(window.page)
        let content = UIView(frame: window.bounds)
        window.addSubview(content)
        for frame in [
            CGRect(x: 85, y: 100, width: 296, height: 44),
            CGRect(x: 85, y: 106.5, width: 296, height: 44)
        ] {
            window.addSubview(NavigationRowFocusRequester.RequestView(frame: frame))
        }
        for pageEnabled in [true, false] {
            window.page.isEnabled = pageEnabled
            let target = NavigationContentFocusRequester.firstTarget(
                in: window, relativeTo: content, isRightToLeft: false
            )
            if pageEnabled {
                XCTAssertTrue(target === window.page)
            } else {
                XCTAssertNil(target, "No page candidate must not turn into a Profile request.")
            }
        }
    }

    func testRailExclusionUsesTheSameFocusSnapshotAsContentSelection() {
        for overlapsRail in [false, true] {
            let window = RecreatedFocusItemsWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            window.isHidden = false
            defer { window.isHidden = true }
            window.page.frame = overlapsRail
                ? CGRect(x: 20, y: 45, width: 1400, height: 80)
                : CGRect(x: 700, y: 150, width: 200, height: 70)
            window.addSubview(window.page)
            let content = UIView(frame: window.bounds)
            window.addSubview(content)
            let rail = NavigationRowFocusRequester.RequestView(
                frame: CGRect(x: 48, y: 60, width: 404, height: 44)
            )
            window.addSubview(rail)

            let target = NavigationContentFocusRequester.firstTarget(
                in: window, relativeTo: content, isRightToLeft: false
            )
            XCTAssertTrue(target === window.page,
                          "Recreated Profile focus items must not be mistaken for page content.")
            XCTAssertEqual(window.queryCount, 1, "Do not re-enumerate the window for every rail row.")
        }
    }

    func testExpandedLaterCardDoesNotOutrankTheLeadingCard() {
        let frames = [
            CGRect(x: 80, y: 400, width: 240, height: 160),
            CGRect(x: 350, y: 390, width: 260, height: 180),
            CGRect(x: 640, y: 400, width: 240, height: 160),
            CGRect(x: 80, y: 650, width: 240, height: 160)
        ]
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: false), 0)
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: true), 2)
    }

    func testPageTopControlOutranksCardsBelowIt() {
        let frames = [
            CGRect(x: 80, y: 500, width: 240, height: 160),
            CGRect(x: 700, y: 150, width: 180, height: 70)
        ]
        XCTAssertEqual(NavigationContentFocusRequester.firstFrameIndex(frames, isRightToLeft: false), 1)
        XCTAssertNil(NavigationContentFocusRequester.firstFrameIndex([], isRightToLeft: false))
    }
}

@MainActor
private final class RecreatedFocusItemsWindow: UIWindow {
    let page = UIButton()
    var profileFrame = CGRect(x: 36, y: 50, width: 428, height: 64)
    var scrolledRow: UIButton?
    var includesPage = true
    var extraItems: [UIButton] = []
    private(set) var queryCount = 0

    override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
        queryCount += 1
        let profile = UIButton(frame: profileFrame)
        addSubview(profile)
        return (scrolledRow.map { [$0] } ?? []) + [profile] + (includesPage ? [page] : []) + extraItems
    }
}

@MainActor
private final class ContentFocusContainer: UIView {
    let page = UIButton()
    private(set) var queryCount = 0

    override func focusItems(in rect: CGRect) -> [any UIFocusItem] {
        queryCount += 1
        return [page]
    }
}
#endif
