import SwiftUI

struct PortraitPlaybackHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PortraitPlaybackReflectionHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct PlaybackReflectionColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme = .dark
}

public extension EnvironmentValues {
    /// The surrounding page's appearance, independent of dark video controls.
    var playbackReflectionColorScheme: ColorScheme {
        get { self[PlaybackReflectionColorSchemeKey.self] }
        set { self[PlaybackReflectionColorSchemeKey.self] = newValue }
    }
}

extension EnvironmentValues {
    var portraitPlaybackReflectionHeight: CGFloat {
        get { self[PortraitPlaybackReflectionHeightKey.self] }
        set { self[PortraitPlaybackReflectionHeightKey.self] = newValue }
    }
}

private struct PortraitPlaybackReflection: ViewModifier {
    let enabled: Bool
    let scale: CGFloat
    @State private var contentHeight: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            content
                .environment(\.portraitPlaybackReflectionHeight, contentHeight * scale)
                .onPreferenceChange(PortraitPlaybackHeightKey.self) { contentHeight = $0 }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func fittingPortraitPlaybackReflection(_ enabled: Bool, scale: CGFloat = 1) -> some View {
        #if os(iOS)
        modifier(PortraitPlaybackReflection(enabled: enabled, scale: scale))
        #else
        self
        #endif
    }
}
