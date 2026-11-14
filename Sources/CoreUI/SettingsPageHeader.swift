#if canImport(SwiftUI)
import SwiftUI

/// Place this heading inside ordinary pages' scrollable content. Full-screen
/// editors may keep it outside their independently scrolling tool pane.
/// Add a subtitle only when the title cannot communicate the scope of the page.
public struct SettingsPageHeader<Trailing: View>: View {
    private let title: Text
    private let subtitle: Text?
    private let trailing: Trailing
    #if os(tvOS)
    @Environment(\.settingsPageBackButton) private var backButton
    #endif

    public init(_ title: Text, subtitle: Text? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: SettingsFormMetrics.controlSpacing) {
            #if os(tvOS)
            if let backButton {
                backButton.fixedSize()
            }
            #endif
            heading
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                subtitle
                    #if os(tvOS)
                    .font(SettingsRowMetrics.helperFont)
                    #else
                    .font(.subheadline)
                    #endif
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension SettingsPageHeader where Trailing == EmptyView {
    public init(_ title: Text, subtitle: Text? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }

    public init(_ title: LocalizedStringResource, subtitle: LocalizedStringResource? = nil) {
        self.init(Text(title), subtitle: subtitle.map(Text.init))
    }

    public init(verbatim title: String, subtitle: LocalizedStringResource? = nil) { // l10n:content
        self.init(Text(verbatim: title), subtitle: subtitle.map(Text.init))
    }
}

public struct SettingsBackButton: View {
    private let action: () -> Void
    private let usesGlass: Bool
    #if os(tvOS)
    @Environment(\.settingsPageContext) private var page
    #endif

    public init(usesGlass: Bool = false, action: @escaping () -> Void) {
        self.action = action
        self.usesGlass = usesGlass
    }

    public var body: some View {
        #if os(tvOS)
        if page?.requestsEntryFocus == true {
            SettingsBackEntryPlaceholder {
                control
            }
            .fixedSize()
        } else {
            control
        }
        #else
        control
        #endif
    }

    private var control: some View {
        styledButton
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .fixedSize()
    }

    @ViewBuilder
    private var styledButton: some View {
        if usesGlass {
            button.plozzGlassPillButton()
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) {
            Label("Back", systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
        }
    }
}

#if os(tvOS)
import UIKit

/// Keep the native button enabled visually while excluding its subtree from entry focus.
private struct SettingsBackEntryPlaceholder<Content: View>: UIViewControllerRepresentable {
    @ViewBuilder var content: () -> Content
    @Environment(\.self) private var environment

    func makeUIViewController(context: Context) -> UIHostingController<AnyView> {
        let host = UIHostingController(rootView: hostedContent)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        return host
    }

    func updateUIViewController(_ host: UIHostingController<AnyView>, context: Context) {
        host.rootView = hostedContent
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, uiViewController: UIHostingController<AnyView>, context: Context
    ) -> CGSize? {
        uiViewController.sizeThatFits(in: .zero)
    }

    private var hostedContent: AnyView {
        AnyView(content().environment(\.self, environment))
    }
}
#endif
#endif
