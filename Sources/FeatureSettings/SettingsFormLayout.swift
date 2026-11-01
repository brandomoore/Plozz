#if os(tvOS)
import CoreUI
import SwiftUI

struct SettingsFormLayout: View {
    let title: Text
    let rows: [SettingsSplitRow]
    var showsBack = false
    @Environment(SettingsNavigationModel.self) private var navigation: SettingsNavigationModel?
    @Environment(SettingsSearchRequest.self) private var searchRequest: SettingsSearchRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsFormHeader(title: title, showsBack: showsBack)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        SettingsFormRow(row: row, isEntry: index == 0)
                            .disabled(index > 0 && navigation?.focusInDetail == false && searchRequest == nil)
                            .padding(.top, rowSpacing(at: index))
                            .id(row.id)
                    }
                }
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
        .toggleStyle(SettingsSwitchToggleStyle())
        .toolbar(.hidden, for: .tabBar)
    }

    private func rowSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if rows[index].sectionStart != nil { return SettingsFormMetrics.sectionSpacing }
        return rows[(index - 1)...index].allSatisfy { $0.route != nil || $0.presentation == .page }
            ? SettingsFormMetrics.navigationRowSpacing : SettingsFormMetrics.sectionSpacing
    }
}

private struct SettingsFormHeader: View {
    let title: Text
    let showsBack: Bool
    var route: SettingsRoute?
    @SettingsPageDismiss private var dismiss
    @Environment(\.settingsPageBackButton) private var inheritedBackButton

    var body: some View {
        SettingsPageHeader(title)
            .environment(\.settingsPageBackButton, backButton)
            .padding(.bottom, 8)
    }

    private var backButton: AnyView? {
        guard showsBack else { return inheritedBackButton }
        return AnyView(
            SettingsBackButton { dismiss() }
                .settingsWorkspaceEntry(route: route)
                .settingsPageEntryFocus()
                .accessibilityIdentifier("settings-workspace-back")
        )
    }
}

private struct SettingsFormRow: View {
    let row: SettingsSplitRow
    let isEntry: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            switch row.sectionStart {
            case .heading(let title):
                title
                    .font(.headline)
                    .padding(.horizontal, SettingsFormMetrics.headingInset)
                    .accessibilityAddTraits(.isHeader)
            case .divider:
                Divider()
            case nil:
                EmptyView()
            }
            content
        }
        .settingsWorkspaceEntry(isEntry)
    }

    @ViewBuilder private var content: some View {
        if let route = row.route {
            SettingsRouteLink(value: route) {
                SettingsFormLinkLabel(row: row)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .navigation))
            .accessibilityIdentifier("settings-page-\(row.id)")
        } else if row.presentation == .page {
            SettingsPageLink {
                SettingsFormRowPage(row: row)
            } label: {
                SettingsFormLinkLabel(row: row)
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .navigation))
            .accessibilityIdentifier("settings-page-\(row.id)")
        } else if row.presentation == .labeledControl {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
                SettingsControlGroup { row.detail() }
                if let description = row.description {
                    description
                        .settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                }
            }
            .accessibilityIdentifier("settings-group-\(row.id)")
        } else if row.presentation == .compactRow {
            HStack(spacing: 24) {
                row.title.font(SettingsRowMetrics.titleFont)
                Spacer(minLength: 16)
                row.detail()
            }
            .padding(.horizontal, SettingsFormMetrics.headingInset)
            .padding(.vertical, SettingsFormMetrics.groupInset)
            .settingsGroupSurface(cornerRadius: SettingsFormMetrics.groupCornerRadius)
            .accessibilityIdentifier("settings-group-\(row.id)")
        } else {
            SettingsFormGroup(
                title: row.title, description: row.description,
                illustrated: row.hasIllustratedContent, hasGroupedContent: row.hasGroupedContent
            ) {
                row.detail()
            }
            .accessibilityIdentifier("settings-group-\(row.id)")
        }
    }
}

struct SettingsFormGroup<Content: View>: View {
    let title: Text
    var description: Text?
    var illustrated = false
    var hasGroupedContent = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            title
                .font(.headline)
                .padding(.horizontal, SettingsFormMetrics.headingInset)
                .accessibilityAddTraits(.isHeader)
            if hasGroupedContent {
                content()
            } else {
                SettingsControlGroup(illustrated: illustrated, content: content)
            }
            if let description {
                description
                    .settingsHelperText()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsFormMetrics.headingInset)
            }
        }
    }
}

struct SettingsControlGroup<Content: View>: View {
    var illustrated = false
    var dividerLeadingInset: CGFloat? = nil
    var cornerRadii = RectangleCornerRadii(
        topLeading: SettingsFormMetrics.groupCornerRadius,
        bottomLeading: SettingsFormMetrics.groupCornerRadius,
        bottomTrailing: SettingsFormMetrics.groupCornerRadius,
        topTrailing: SettingsFormMetrics.groupCornerRadius
    )
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsControlRows(dividerLeadingInset: dividerLeadingInset) {
            if illustrated {
                VStack(alignment: .leading, spacing: SettingsFormMetrics.illustratedGroupSpacing, content: content)
            } else {
                content()
            }
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(SettingsFormMetrics.groupInset)
            .settingsGroupSurface(cornerRadii: cornerRadii)
            .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
            .environment(\.settingsFormRowsFlushLeading, false)
            .environment(\.settingsFormTextInset, SettingsRowMetrics.horizontalPadding)
    }
}

struct SettingsConnectedControlGroups<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.connectedGroupSpacing) {
            Group(subviews: content()) { groups in
                ForEach(groups) { group in
                    SettingsControlGroup(cornerRadii: .init(
                        topLeading: group.id == groups.first?.id
                            ? SettingsFormMetrics.groupCornerRadius : SettingsFormMetrics.connectedGroupInnerCornerRadius,
                        bottomLeading: group.id == groups.last?.id
                            ? SettingsFormMetrics.groupCornerRadius : SettingsFormMetrics.connectedGroupInnerCornerRadius,
                        bottomTrailing: group.id == groups.last?.id
                            ? SettingsFormMetrics.groupCornerRadius : SettingsFormMetrics.connectedGroupInnerCornerRadius,
                        topTrailing: group.id == groups.first?.id
                            ? SettingsFormMetrics.groupCornerRadius : SettingsFormMetrics.connectedGroupInnerCornerRadius
                    )) {
                        group
                    }
                }
            }
        }
    }
}

private struct SettingsFormLinkLabel: View {
    let row: SettingsSplitRow

    var body: some View {
        HStack(spacing: 16) {
            row.title
                .font(SettingsRowMetrics.titleFont)
            Spacer(minLength: 16)
            row.summary?.font(.callout).settingsRowSecondary()
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .settingsRowSecondary()
        }
        .padding(.horizontal, SettingsFormMetrics.headingInset)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGroupSurface(cornerRadius: SettingsRowMetrics.navigationCornerRadius)
    }
}

struct SettingsFormRowPage: View {
    let row: SettingsSplitRow
    var showsBack = true
    var route: SettingsRoute?
    @State private var navigation = SettingsDetailNavigation()

    var body: some View {
        if let children = row.childRows {
            SettingsFormLayout(title: row.title, rows: children(), showsBack: showsBack)
        } else if let subpage = row.subpage {
            SettingsDetailPages(navigation: navigation) {
                SettingsFormRowContent(row: row, showsBack: showsBack, route: route)
            } detail: {
                subpage.content()
            }
        } else {
            SettingsFormRowContent(row: row, showsBack: showsBack, route: route)
        }
    }
}

private struct SettingsFormRowContent: View {
    let row: SettingsSplitRow
    let showsBack: Bool
    let route: SettingsRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsFormHeader(title: row.title, showsBack: showsBack, route: route)
                Group {
                    if row.hasGroupedContent {
                        row.detail()
                    } else {
                        SettingsControlGroup(illustrated: row.hasIllustratedContent) { row.detail() }
                    }
                }
                    .environment(\.settingsPageBackButton, nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let description = row.description {
                    description.settingsHelperText()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                }
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
        }
        .scrollClipDisabled()
        .toggleStyle(SettingsSwitchToggleStyle())
        .toolbar(.hidden, for: .tabBar)
    }
}
#endif
