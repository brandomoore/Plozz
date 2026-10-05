#if os(iOS) && canImport(SwiftUI)
import SwiftUI

/// Canonical root for an iPhone/iPad settings screen. It pairs the standard
/// settings list behavior with Plozz's theme-aware page surface so new screens
/// cannot accidentally fall back to SwiftUI's system grouped colors.
public struct SettingsPageList<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        List {
            content
        }
        .settingsPageSurface()
    }
}

/// Composite panels can contain several NavigationLinks. Hosting a whole panel
/// in one List cell lets native row activation push all of its destinations.
public struct SettingsPageScroll<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsPageSurface()
    }
}

public struct SettingsPageSurface: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 24, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .background { SettingsPageBackground() }
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

public extension View {
    func settingsPageSurface() -> some View {
        modifier(SettingsPageSurface())
    }
}
#endif
