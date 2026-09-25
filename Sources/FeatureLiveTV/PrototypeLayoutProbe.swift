#if DEBUG
import SwiftUI

/// Actual mounted bounds used by layout-transition regressions.
struct PrototypeHeroBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}
#endif
