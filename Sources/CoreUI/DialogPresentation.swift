#if canImport(SwiftUI)
import SwiftUI

#if os(tvOS)
public struct PlozzDialogHeading: View {
    private let title: Text
    @Environment(\.themePalette) private var palette

    public init(_ title: Text) {
        self.title = title
    }

    public var body: some View {
        title
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(palette.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}
#endif

private struct DialogBackgroundOwnedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var plozzDialogBackgroundOwned: Bool {
        get { self[DialogBackgroundOwnedKey.self] }
        set { self[DialogBackgroundOwnedKey.self] = newValue }
    }
}

struct PlozzDialogBackgroundStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        let palette = environment.themePalette
        if environment.gradientBackgroundsEnabled {
            return AnyShapeStyle(AmbientGradientBackground.mesh(
                colors: AmbientGradientBackground.meshColors(tint: nil, palette: palette)
            ))
        }
        return AnyShapeStyle(palette.overlay.fill)
    }
}

/// One opaque surface for the entire dialog, including native presentation insets.
struct PlozzDialogBackground: View {
    var body: some View {
        Rectangle()
            .fill(PlozzDialogBackgroundStyle())
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct PlozzDialogContent<Content: View>: View {
    let content: Content
    let style: PlozzSheetStyle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        ZStack {
            if style == .standard {
                PlozzDialogBackdrop()
                content
                    .environment(\.plozzDialogBackgroundOwned, true)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .plozzSurface(.overlay, cornerRadius: 32)
                    .padding(32)
            } else {
                content.environment(\.plozzDialogBackgroundOwned, false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationBackground(.clear)
        .onExitCommand { dismiss() }
        #else
        content
            #if os(iOS)
            .plozzOpaqueNavigationChrome()
            #endif
            .scrollContentBackground(.hidden)
            .environment(\.plozzDialogBackgroundOwned, style == .standard)
            .presentationBackground(style == .standard
                ? AnyShapeStyle(PlozzDialogBackgroundStyle()) : AnyShapeStyle(Color.clear))
        #endif
    }
}

public enum PlozzSheetStyle {
    case standard
    /// Content supplies its own dimming and a shared `.overlay` card surface.
    case floatingCard
}

public extension View {
    /// The existing sheet surface when several flows share one native presenter.
    func plozzDialogSurface(style: PlozzSheetStyle = .standard) -> some View {
        PlozzDialogContent(content: self, style: style)
    }

    func plozzSheet<SheetContent: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        style: PlozzSheetStyle = .standard,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            PlozzDialogContent(content: content(), style: style)
                .environment(\.settingsPageContext, nil)
        }
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            PlozzDialogContent(content: content(), style: style)
        }
        #endif
    }

    func plozzSheet<Item: Identifiable, SheetContent: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        style: PlozzSheetStyle = .standard,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item, onDismiss: onDismiss) { item in
            PlozzDialogContent(content: content(item), style: style)
                .environment(\.settingsPageContext, nil)
        }
        #else
        sheet(item: item, onDismiss: onDismiss) { item in
            PlozzDialogContent(content: content(item), style: style)
        }
        #endif
    }

    #if os(iOS) || os(tvOS)
    /// Full-screen flows own their own page background, even when opened from a sheet.
    func plozzFullScreenCover<CoverContent: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> CoverContent
    ) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            content().environment(\.plozzDialogBackgroundOwned, false)
                #if os(iOS)
                .plozzOpaqueNavigationChrome()
                #endif
                #if os(tvOS)
                .environment(\.settingsPageContext, nil)
                #endif
        }
    }

    func plozzFullScreenCover<Item: Identifiable, CoverContent: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> CoverContent
    ) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { item in
            content(item).environment(\.plozzDialogBackgroundOwned, false)
                #if os(iOS)
                .plozzOpaqueNavigationChrome()
                #endif
                #if os(tvOS)
                .environment(\.settingsPageContext, nil)
                #endif
        }
    }
    #endif
}
#endif
