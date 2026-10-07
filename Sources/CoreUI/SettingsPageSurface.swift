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
    private let titleDisplayMode: ToolbarTitleDisplayMode
    private let horizontalInset: CGFloat

    public init(titleDisplayMode: ToolbarTitleDisplayMode = .inline, horizontalInset: CGFloat = 24) {
        self.titleDisplayMode = titleDisplayMode
        self.horizontalInset = horizontalInset
    }

    public func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 24, for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.horizontal, horizontalInset)
            .background { SettingsPageBackground() }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarTitleDisplayMode(titleDisplayMode)
    }
}

public extension View {
    func settingsPageSurface(
        titleDisplayMode: ToolbarTitleDisplayMode = .inline, horizontalInset: CGFloat = 24
    ) -> some View {
        modifier(SettingsPageSurface(
            titleDisplayMode: titleDisplayMode, horizontalInset: horizontalInset))
    }
}
#endif
