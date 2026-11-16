#if canImport(SwiftUI)
import SwiftUI

extension ContainerValues {
    @Entry var settingsContentOwnsInsets = false
}

#if os(iOS)
private extension EnvironmentValues {
    @Entry var settingsUsesSignInFields = false
}

private struct SettingsSignInTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .frame(minHeight: 44)
            .padding(.vertical, MobileSettingsMetrics.rowVerticalInset - MobileSettingsMetrics.controlVerticalInset)
    }
}

public enum MobileSettingsMetrics {
    public static let pageInset: CGFloat = 16
    public static let sectionSpacing: CGFloat = 28
    public static let groupCornerRadius: CGFloat = 26
    public static let rowInset: CGFloat = 16
    public static let rowVerticalInset: CGFloat = 10
    public static let descriptionBottomInset: CGFloat = 12
    public static let controlVerticalInset: CGFloat = 4
    public static let rowMinHeight: CGFloat = 52
    public static let previewGridInset: CGFloat = 8
    public static let previewCardInset: CGFloat = 8
    public static let previewCardCornerRadius = groupCornerRadius - previewGridInset
    public static let previewContentCornerRadius = previewCardCornerRadius - previewCardInset
}

struct SettingsRowTitleAnchorKey: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value += nextValue()
    }
}

private struct SettingsRowSeparator: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.displayScale) private var displayScale
    let titles: [Anchor<CGRect>]

    var body: some View {
        GeometryReader { geometry in
            let inset = titles.map { anchor in
                let rect = geometry[anchor]
                return layoutDirection == .leftToRight ? rect.minX : geometry.size.width - rect.maxX
            }.min() ?? MobileSettingsMetrics.rowInset
            Rectangle()
                .fill(palette.separator)
                .frame(height: 1 / displayScale)
                .padding(.leading, max(MobileSettingsMetrics.rowInset, inset))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SettingsActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MobileSettingsMetrics.rowInset)
            .padding(.vertical, MobileSettingsMetrics.rowVerticalInset)
            .frame(minHeight: MobileSettingsMetrics.rowMinHeight)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
#endif

public extension View {
    /// Simple credential forms keep native placeholders and persistent accessible names.
    @ViewBuilder func settingsSignInFields() -> some View {
        #if os(iOS)
        environment(\.settingsUsesSignInFields, true)
            .textFieldStyle(SettingsSignInTextFieldStyle())
        #else
        self
        #endif
    }

    /// A single action owns its padded hit area; the containing group adds no second inset.
    @ViewBuilder func settingsActionRow() -> some View {
        #if os(iOS)
        buttonStyle(SettingsActionRowStyle())
            .containerValue(\.settingsContentOwnsInsets, true)
        #else
        self
        #endif
    }

    @ViewBuilder func settingsPreviewRow() -> some View {
        #if os(iOS)
        padding(MobileSettingsMetrics.previewGridInset)
            .containerValue(\.settingsContentOwnsInsets, true)
        #else
        self
        #endif
    }

    /// Use inside a control's label when it shares a row with other controls.
    @ViewBuilder func settingsControlTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Keeps the minimum target inside the native menu trigger, including its empty space.
public struct SettingsControlMenu<Content: View, Label: View>: View {
    private let content: Content
    private let label: Label

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        Menu { content } label: {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsControlTarget()
        }
        .buttonStyle(.plain)
    }
}
#endif

public struct SettingsMenuValue: View {
    private let value: Text

    public init(_ value: Text) { self.value = value }

    public var body: some View {
        HStack(spacing: 8) {
            value
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(.primary)
    }
}

/// A persistent label for a native settings input. The surrounding group owns its surface and insets.
public struct SettingsInputRow<Input: View>: View {
    private let title: LocalizedStringResource
    private let status: Text?
    private let axis: Axis
    private let input: Input
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.settingsUsesSignInFields) private var usesSignInFields
    #endif

    public init(
        _ title: LocalizedStringResource, status: Text? = nil, axis: Axis = .vertical,
        @ViewBuilder input: () -> Input
    ) {
        self.title = title
        self.status = status
        self.axis = axis
        self.input = input()
    }

    public var body: some View {
        #if os(iOS)
        if usesSignInFields {
            VStack(alignment: .leading, spacing: 4) {
                input
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(title))
                if let status { status.font(SettingsRowMetrics.descriptionFont) }
            }
        } else {
            labeledInput
        }
        #else
        labeledInput
        #endif
    }

    @ViewBuilder private var labeledInput: some View {
        if axis == .horizontal && !dynamicTypeSize.isAccessibilitySize {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    input
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textFieldStyle(.plain)
                        #endif
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityLabel(Text(title))
                    if let status { status.font(SettingsRowMetrics.descriptionFont) }
                }
            } label: {
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            .settingsFormRowLayout()
        } else {
            stackedInput
        }
    }

    private var stackedInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .plozzForeground(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                if let status {
                    Spacer()
                    status
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(SettingsRowMetrics.descriptionFont)
            input
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityLabel(Text(title))
        }
    }
}

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
            SettingsMenuValue(value)
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
        #if os(tvOS)
        let cornerRadius = SettingsFormMetrics.groupCornerRadius
        let horizontalInset = SettingsFormMetrics.groupInset
        let verticalInset = SettingsFormMetrics.groupInset
        let captionSpacing: CGFloat = 4
        #elseif os(iOS)
        let cornerRadius = MobileSettingsMetrics.groupCornerRadius
        let horizontalInset = MobileSettingsMetrics.rowInset
        let verticalInset = MobileSettingsMetrics.controlVerticalInset
        let captionSpacing: CGFloat = 8
        #else
        let cornerRadius: CGFloat = 18
        let horizontalInset: CGFloat = 16
        let verticalInset: CGFloat = 12
        let captionSpacing: CGFloat = 4
        #endif
        VStack(alignment: .leading, spacing: captionSpacing) {
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
                #if os(iOS)
                .padding(.horizontal, horizontalInset)
                #else
                .padding(.top, 8)
                #endif
            }

            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(subviews) { subview in
                        subview
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, subview.containerValues.settingsContentOwnsInsets ? 0 : horizontalInset)
                            .padding(.vertical, subview.containerValues.settingsContentOwnsInsets ? 0 : verticalInset)
                            #if os(iOS)
                            .frame(minHeight: MobileSettingsMetrics.rowMinHeight)
                            #endif
                            .contentShape(Rectangle())
                            #if os(iOS)
                            .modifier(SettingsSearchRowHighlight(
                                isFirst: subview.id == subviews.first?.id,
                                isLast: subview.id == subviews.last?.id,
                                cornerRadius: cornerRadius
                            ))
                            .overlayPreferenceValue(SettingsRowTitleAnchorKey.self) { titles in
                                if subview.id != subviews.last?.id {
                                    SettingsRowSeparator(titles: titles)
                                }
                            }
                            .transformPreference(SettingsRowTitleAnchorKey.self) { $0.removeAll() }
                            #endif
                        #if !os(iOS)
                        if subview.id != subviews.last?.id {
                            Rectangle()
                                .fill(palette.separator)
                                .frame(height: 1)
                                .padding(.horizontal, horizontalInset)
                        }
                        #endif
                    }
                }
            }
            #if os(iOS)
            // Subviews resolve their environment before the per-row modifiers are applied.
            .environment(\.settingsSearchRowOwnsHighlight, true)
            #endif
            .labelStyle(SettingsIconLabelStyle())
            #if os(tvOS)
            .buttonStyle(SettingsFormButtonStyle())
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            .environment(\.settingsFormRowsFlushLeading, false)
            #else
            .buttonStyle(SettingsSectionButtonStyle())
            .toggleStyle(SettingsSwitchToggleStyle())
            // A group is one List cell. Automatic pickers can claim the whole
            // cell's primary action, stealing taps from sibling controls.
            .pickerStyle(.menu)
            #endif
            .settingsGroupSurface(cornerRadius: cornerRadius)

            footer
                .font(SettingsRowMetrics.helperFont)
                .plozzForeground(.secondary)
                .padding(.horizontal, 16)
        }
        #if !os(iOS)
        .padding(.top, 8)
        #endif
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
