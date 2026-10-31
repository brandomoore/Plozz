#if canImport(SwiftUI)
import SwiftUI

public struct SettingsMenuLabel: View {
    private let title: LocalizedStringResource
    private let value: Text

    public init(_ title: LocalizedStringResource, value: LocalizedStringResource) {
        self.title = title
        self.value = Text(value)
    }

    public init(_ title: LocalizedStringResource, value: Text) {
        self.title = title
        self.value = value
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                value
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
        } label: {
            Text(title)
        }
    }
}

/// A drill-in label inside a settings group; the group owns its content insets.
public struct SettingsDisclosureLabel<Title: View, Value: View>: View {
    private let title: Title
    private let value: Value

    public init(
        @ViewBuilder title: () -> Title,
        @ViewBuilder value: () -> Value = { EmptyView() }
    ) {
        self.title = title()
        self.value = value()
    }

    public var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                value
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
            .settingsRowSecondary()
        } label: {
            title
        }
    }
}

/// A group occupies one native List cell. On iOS, navigation beside other
/// controls must use a Button and navigationDestination: a NavigationLink can
/// claim the cell's primary action, including taps on a sibling picker's label.
public struct SettingsSectionGroup<Content: View, Footer: View>: View {
    @Environment(\.themePalette) private var palette
    private let title: Text?
    private let content: Content
    private let footer: Footer
    /// Optional control shown at the trailing edge of the header row.
    ///
    /// Type-erased so adding one doesn't change this type's generic signature,
    /// which would touch every call site in the app. A header accessory is a
    /// single small control, so the cost is irrelevant here.
    private let accessory: AnyView?

    /// Section header that is app COPY — the common case, so literals still work.
    public init(
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title.map(Text.init)
        self.content = content()
        self.footer = footer()
        self.accessory = nil
    }

    /// A section whose header carries an action — "Manage", "Edit", "See All".
    ///
    /// Sitting the control ON the header keeps it next to the rows it acts on.
    /// The same button in the navigation bar is easy to miss, especially on iPad
    /// where it ends up an entire pane away from its list.
    public init<Accessory: View>(
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title.map(Text.init)
        self.content = content()
        self.footer = footer()
        self.accessory = AnyView(accessory())
    }

    /// Section header that is verbatim CONTENT — e.g. the legal/trademark
    /// attribution sections, whose wording is deliberately not translated.
    public init(
        verbatim title: String,   // l10n:content — deliberately verbatim (legal/attribution headings)
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = Text(verbatim: title)
        self.content = content()
        self.footer = footer()
        self.accessory = nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        title
                            .font(.footnote.weight(.semibold))
                            .plozzForeground(.secondary)
                            .textCase(.uppercase)
                    }
                    Spacer(minLength: 12)
                    if let accessory {
                        accessory
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.top, 8)
            }

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { subview in
                        subview
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        if subview.id != subviews.last?.id {
                            Rectangle()
                                .fill(palette.separator)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .buttonStyle(SettingsSectionButtonStyle())
            .labelStyle(SettingsIconLabelStyle())
            #if os(tvOS)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            #else
            .toggleStyle(SettingsSwitchToggleStyle())
            // A group is one List cell. Automatic pickers can claim the whole
            // cell's primary action, stealing taps from sibling controls.
            .pickerStyle(.menu)
            #endif
            .settingsGroupSurface(cornerRadius: 18)

            footer
                #if os(tvOS)
                .font(SettingsRowMetrics.helperFont)
                #else
                .font(.footnote)
                #endif
                .plozzForeground(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.top, 8)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .listRowSeparator(.hidden)
        #endif
    }
}

private struct SettingsSectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

public extension SettingsSectionGroup where Footer == EmptyView {
    init(
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, content: content, footer: { EmptyView() })
    }

    init(
        verbatim title: String,   // l10n:content — deliberately verbatim (legal/attribution headings)
        @ViewBuilder content: () -> Content
    ) {
        self.init(verbatim: title, content: content, footer: { EmptyView() })
    }

    /// Header-accessory variant for a section with no footer.
    init<Accessory: View>(
        _ title: LocalizedStringResource? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, accessory: accessory, content: content, footer: { EmptyView() })
    }
}
#endif
