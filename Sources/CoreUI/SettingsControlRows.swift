#if canImport(SwiftUI)
import SwiftUI

#if os(tvOS)
private extension EnvironmentValues {
    @Entry var settingsCardInset: CGFloat? = nil
}

/// The earliest y-coordinate for a divider after a description, even through nested row views.
private enum DescriptionBoundary: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[.bottom] }
    static let alignment = VerticalAlignment(Self.self)
}

private struct SettingsRowBoundaryLayout: Layout {
    let dividerInset: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = subviews[0].dimensions(in: proposal)
        var height = row.height
        if let dividerInset, let boundary = row[explicit: DescriptionBoundary.alignment] {
            // Both the row's existing padding and the divider's focus clearance count toward the gap.
            height = max(height, boundary - dividerInset)
        }
        return CGSize(width: row.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

public extension View {
    func settingsControlGroupPadding() -> some View {
        let inset = SettingsFormMetrics.groupInset
        return padding(inset).environment(\.settingsCardInset, inset)
    }
}
#endif

/// A control and its supporting copy form one row, including for group separators.
public struct SettingsDescribedControl<Control: View, Description: View>: View {
    private let control: Control
    private let description: Description
    #if os(tvOS)
    @Environment(\.settingsCardInset) private var cardInset
    #endif

    public init(@ViewBuilder control: () -> Control, @ViewBuilder description: () -> Description) {
        self.control = control()
        self.description = description()
    }

    public var body: some View {
        #if os(iOS)
        let descriptionSpacing: CGFloat = 0
        #else
        let descriptionSpacing = SettingsFormMetrics.relatedControlSpacing
        #endif
        VStack(alignment: .leading, spacing: descriptionSpacing) {
            control
                #if os(iOS)
                .frame(minHeight: MobileSettingsMetrics.rowMinHeight - 2 * MobileSettingsMetrics.controlVerticalInset)
                #endif
            Group { description }
                .settingsHelperText()
                .fixedSize(horizontal: false, vertical: true)
                #if os(tvOS)
                .alignmentGuide(DescriptionBoundary.alignment) {
                    $0[.bottom] + (cardInset == nil ? 0 : SettingsFormMetrics.descriptionBoundarySpacing)
                }
                .padding(.bottom, cardInset.map { max(0, SettingsFormMetrics.descriptionBoundarySpacing - $0) }
                         ?? PlozzTheme.Spacing.medium)
                #elseif os(iOS)
                .padding(.bottom, MobileSettingsMetrics.descriptionBottomInset - MobileSettingsMetrics.controlVerticalInset)
                #endif
        }
    }
}

/// Rows sharing a Settings container. Keep each control and its helper in one
/// child view so the separator follows both. Conditional rows retain their IDs.
public struct SettingsControlRows<Content: View>: View {
    private let nonTVSpacing: CGFloat
    private let dividerLeadingInset: CGFloat?
    private let content: Content
    @Environment(\.settingsFormTextInset) private var textInset

    public init(
        nonTVSpacing: CGFloat = SettingsFormMetrics.controlSpacing,
        dividerLeadingInset: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.nonTVSpacing = nonTVSpacing
        self.dividerLeadingInset = dividerLeadingInset
        self.content = content()
    }

    public var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    let hasDivider = row.id != rows.last?.id
                    let clearance = SettingsFormMetrics.dividerFocusClearance
                    SettingsRowBoundaryLayout(dividerInset: hasDivider ? clearance : nil) { row }
                    if hasDivider {
                        PlozzDivider()
                            .padding(.leading, dividerLeadingInset ?? textInset)
                            .padding(.trailing, textInset)
                            .padding(.vertical, clearance)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .environment(\.settingsRowsHaveDividers, true)
        #else
        VStack(alignment: .leading, spacing: nonTVSpacing) {
            content
        }
        #endif
    }
}
#endif
