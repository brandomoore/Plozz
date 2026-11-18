#if os(tvOS)
import UIKit
import XCTest

/// Includes SwiftUI's virtual native-card focus items, not just UIView-backed controls.
@MainActor
enum DetailTintFocusProbe {
    static func nativeFocusItems(in window: UIWindow) throws -> [any UIFocusItem] {
        var containers: [any UIFocusItemContainer] = [window]
        var seen = Set<ObjectIdentifier>()
        var items: [ObjectIdentifier: any UIFocusItem] = [:]
        while let container = containers.popLast() {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            let region = container.coordinateSpace.convert(window.bounds, from: window)
            for item in container.focusItems(in: region) {
                if let child = item.focusItemContainer { containers.append(child) }
                if let view = item as? UIView { containers.append(view) }
                if item.canBecomeFocused, !(item is UIScrollView),
                   !String(describing: type(of: item)).contains("Filler") {
                    items[ObjectIdentifier(item)] = item
                }
            }
        }
        let positioned = try items.values.map { item in
            (item: item, frame: try nativeFocusFrame(item, in: window))
        }
        return positioned.sorted {
            abs($0.frame.minY - $1.frame.minY) > 1
                ? $0.frame.minY < $1.frame.minY
                : $0.frame.minX < $1.frame.minX
        }.map(\.item)
    }

    static func nativeFocusFrame(
        _ item: any UIFocusItem, in window: UIWindow
    ) throws -> CGRect {
        if let view = item as? UIView {
            return view.convert(view.bounds, to: window)
        }
        var frame: CGRect?
        var environment: (any UIFocusEnvironment)? = item
        var seen = Set<ObjectIdentifier>()
        while let current = environment,
              seen.insert(ObjectIdentifier(current)).inserted {
            if frame == nil, let container = current.focusItemContainer {
                frame = container.coordinateSpace.convert(item.frame, to: window)
            }
            if let scroll = current as? UIScrollView {
                // SwiftUI virtual items omit the scroll content's horizontal safe area.
                return try XCTUnwrap(frame).offsetBy(dx: scroll.safeAreaInsets.left, dy: 0)
            }
            environment = current.parentFocusEnvironment
        }
        return try XCTUnwrap(frame, "A native focus item must provide its coordinate space.")
    }
}
#endif
