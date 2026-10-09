#if canImport(SwiftUI)
import SwiftUI

public enum NavigationEntryFocusPreference: Equatable, Sendable {
    case pending
    case content
    case fallback
}

public extension View {
    /// Declares a page's entry target without changing ordinary directional focus.
    @ViewBuilder
    func navigationEntryFocus(_ preference: NavigationEntryFocusPreference?) -> some View {
        #if os(tvOS)
        background { NavigationEntryFocusRegion(preference: preference) }
        #else
        self
        #endif
    }
}

#if os(tvOS)
import UIKit

private struct NavigationEntryFocusRegion: UIViewRepresentable {
    let preference: NavigationEntryFocusPreference?

    func makeUIView(context: Context) -> NavigationEntryFocusRegionView {
        NavigationEntryFocusRegionView()
    }

    func updateUIView(_ view: NavigationEntryFocusRegionView, context: Context) {
        view.preference = preference
    }

    static func dismantleUIView(_ view: NavigationEntryFocusRegionView, coordinator: ()) {
        view.preference = nil
    }
}

public final class NavigationEntryFocusRegionView: UIView {
    public static let didChange = Notification.Name("Plozz.NavigationEntryFocusRegionChanged")

    public var preference: NavigationEntryFocusPreference? {
        didSet {
            guard preference != oldValue else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
#endif
#endif
