#if DEBUG
import SwiftUI
import UIKit

/// Actual mounted bounds used by layout-transition regressions.
struct PrototypeHeroBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension EnvironmentValues {
    @Entry var observesPrototypeLayout = false
}

struct PrototypeHeroLayoutObservation: ViewModifier {
    let phase: String
    @Environment(\.observesPrototypeLayout) private var observesLayout

    func body(content: Content) -> some View {
        content
            .anchorPreference(key: PrototypeHeroBoundsKey.self, value: .bounds) { [phase: $0] }
            .background {
                if observesLayout { PrototypeHeroLayoutMarker(phase: phase) }
            }
    }
}

private struct PrototypeHeroLayoutMarker: UIViewRepresentable {
    let phase: String
    func makeUIView(context: Context) -> PrototypeHeroLayoutView {
        let view = PrototypeHeroLayoutView()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: PrototypeHeroLayoutView, context: Context) { view.phase = phase }
}

final class PrototypeHeroLayoutView: UIView {
    var phase = ""
}
#endif
