#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ViewPreferenceChoiceGroup<Content: View>: View {
    var rowSize: SettingsRowSize = .standard
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(tvOS)
        SettingsCheckGroup(rowSize: rowSize) {
            SettingsControlRows(content: content)
        }
        .environment(\.settingsFormRowsFlushLeading, false)
        #else
        if rowSize == .contained {
            Section(content: content)
        } else {
            SettingsSectionGroup(content: content)
        }
        #endif
    }
}

struct ViewPreferenceChoiceRow: View {
    let title: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        #if os(tvOS)
        SettingsCheckableRow(
            title: Text(title),
            subtitle: isFocused ? detail.map { Text($0) } : nil,
            titleLineLimit: nil, subtitleLineLimit: nil,
            isChecked: isSelected,
            flushLeading: false, action: action
        )
        .focused($isFocused)
        #else
        Button(action: action) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .multilineTextAlignment(.leading)
                    if isSelected, let detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        #endif
    }
}

struct ViewCustomizationLink<Destination: View>: View {
    let isCustomized: Bool
    var title: LocalizedStringResource = "Customize by view"
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        SettingsDetailLink(destination: destination) {
            ViewCustomizationLinkLabel(isCustomized: isCustomized, title: title)
        }
        #if os(tvOS)
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        #endif
    }
}

private struct ViewCustomizationLinkLabel: View {
    let isCustomized: Bool
    let title: LocalizedStringResource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout())
            layout {
                Text(title)
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if isCustomized {
                    Text("Custom")
                        .font(.caption.weight(.medium))
                        .settingsRowSecondary()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
            #if os(tvOS)
            Image(systemName: "chevron.right").accessibilityHidden(true)
            #endif
        }
        #if os(tvOS)
        .settingsFormRowLayout()
        #endif
    }
}

struct ViewCustomizationList<Content: View>: View {
    let title: LocalizedStringResource
    let initialRowID: String
    var focusedHelp: (String) -> ViewCustomizationHelp? = { _ in nil }
    var pinsFocusedHelp = true
    var inlineHelpAfterSection: Int?
    var sectionSpacing: CGFloat = SettingsRowMetrics.formRowSpacing
    var hasGroupedContent = false
    @ViewBuilder var content: () -> Content
    @SettingsPageDismiss private var dismiss
    @Environment(SettingsDetailNavigation.self) private var detailNavigation: SettingsDetailNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themePalette) private var palette
    @FocusState private var focusedRow: String?
    @State private var hasEnteredList = false
    @State private var topFadeStrength: CGFloat = 0
    @Namespace private var focusScope

    var body: some View {
        #if os(tvOS)
        let help = focusedHelp(focusedRow ?? initialRowID)
        VStack(spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SettingsPageHeader(title)
                        .environment(\.settingsPageBackButton, AnyView(
                            SettingsBackButton {
                                if let detailNavigation {
                                    detailNavigation.pop(animated: !reduceMotion)
                                } else {
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier("view-customization-back")
                            .disabled(!hasEnteredList && initialRowID != "view-customization-back")
                            .modifier(ViewCustomizationRowFocus(id: "view-customization-back"))
                        ))
                    VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
                        Group(sections: content()) { sections in
                            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                                VStack(alignment: .leading, spacing: sectionSpacing) {
                                    section.header
                                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                                    if hasGroupedContent {
                                        VStack(alignment: .leading, spacing: SettingsFormMetrics.controlSpacing) {
                                            section.content
                                        }
                                    } else {
                                        SettingsControlGroup { section.content }
                                    }
                                    section.footer
                                        .settingsHelperText()
                                        .padding(.horizontal, SettingsFormMetrics.headingInset)
                                }
                                if !pinsFocusedHelp, inlineHelpAfterSection == index, let help {
                                    ViewCustomizationHelpCard(help: help)
                                }
                            }
                            if !pinsFocusedHelp, inlineHelpAfterSection == nil, let help {
                                ViewCustomizationHelpCard(help: help)
                            }
                        }
                    }
                }
                .environment(\.viewCustomizationFocus, $focusedRow)
                .focusScope(focusScope)
                .defaultFocus($focusedRow, initialRowID)
                .task(id: initialRowID) { focusedRow = initialRowID }
                .onChange(of: focusedRow) { _, row in
                    if row != nil {
                        hasEnteredList = true
                        detailNavigation?.focusArrived()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, SettingsFormMetrics.pageTopInset)
                .padding(.bottom, SettingsFormMetrics.pageBottomInset)
                .padding(.horizontal, SettingsFormMetrics.pageInset)
            }
            .contentMargins(.bottom, pinsFocusedHelp && help != nil ? 40 : 0, for: .scrollContent)
            .scrollClipDisabled()
            .mask {
                // Keep mask geometry stable while native focus scrolls the controls.
                VerticalEdgeFadeMask(
                    fadeHeight: 40, topStrength: topFadeStrength,
                    bottomStrength: pinsFocusedHelp && help != nil ? 1 : 0, horizontalOverhang: 20
                )
                .ignoresSafeArea(.container, edges: pinsFocusedHelp && help != nil ? .top : .vertical)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(1, max(0, (geometry.contentOffset.y + geometry.contentInsets.top) / 40))
            } action: { _, strength in
                topFadeStrength = strength
            }
            .accessibilityIdentifier("view-customization-scroll")
            if pinsFocusedHelp, let help {
                ViewCustomizationHelpCard(help: help)
                    .padding(.horizontal, SettingsFormMetrics.pageInset)
                    .padding(.bottom, 24)
            }
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .navigationTitle(Text(verbatim: ""))
        #else
        List {
            content()
                .listRowBackground(palette.surface(.raised).fill)
                .listRowSeparatorTint(palette.separator)
        }
        .listStyle(.insetGrouped)
        .toggleStyle(SettingsSwitchToggleStyle())
        .scrollContentBackground(.hidden)
        .background { palette.settingsBackground.ignoresSafeArea() }
        .toolbarBackground(palette.settingsBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarTitleDisplayMode(.inline)
        .navigationTitle(Text(title))
        #endif
    }
}

#if os(iOS)
struct ViewCustomizationMenu<Selection: Hashable, Options: View>: View {
    let id: String
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    @Binding var selection: Selection
    @ViewBuilder var options: () -> Options

    var body: some View {
        ViewCustomizationMenuLabel(id: id, title: title) {
            Menu {
                Picker(selection: $selection) {
                    options()
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            } label: {
                ViewCustomizationMenuValue(value: value)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value))
            .accessibilityHint(Text(detail ?? "Select to change."))
            .accessibilityIdentifier(id)
        }
    }
}

private struct ViewCustomizationMenuLabel<Control: View>: View {
    let id: String
    let title: LocalizedStringResource
    @ViewBuilder var control: () -> Control
    @Environment(\.themePalette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedLabel
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        Text(title)
                            .accessibilityIdentifier("\(id)-title")
                            .fixedSize()
                        Spacer(minLength: 8)
                        control().fixedSize()
                    }
                    stackedLabel
                }
            }
        }
        .font(.body)
        .foregroundStyle(palette.primaryText)
        .multilineTextAlignment(.leading)
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var stackedLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .accessibilityIdentifier("\(id)-title")
            control()
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ViewCustomizationMenuValue: View {
    let value: LocalizedStringResource
    @Environment(\.themePalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(value)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .accessibilityHidden(true)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif

struct ViewCustomizationRow: View {
    let id: String
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    var detail: LocalizedStringResource? = nil
    let cycle: () -> Void

    var body: some View {
        Button(action: cycle) {
            ViewCustomizationRowLabel(title: title, value: value)
        }
        #if os(tvOS)
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        #else
        .buttonStyle(.plain)
        #endif
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityHint(Text(detail ?? "Select to change."))
        .accessibilityIdentifier(id)
        .modifier(ViewCustomizationRowFocus(id: id))
    }
}

private struct ViewCustomizationFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<String?>.Binding? = nil
}

private extension EnvironmentValues {
    var viewCustomizationFocus: FocusState<String?>.Binding? {
        get { self[ViewCustomizationFocusKey.self] }
        set { self[ViewCustomizationFocusKey.self] = newValue }
    }
}

struct ViewCustomizationRowFocus: ViewModifier {
    let id: String
    @Environment(\.viewCustomizationFocus) private var focus

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: id)
        } else {
            content
        }
    }
}

private struct ViewCustomizationRowLabel: View {
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedLabel
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) {
                        titleText.fixedSize()
                        Spacer(minLength: 12)
                        valueText.fixedSize()
                    }
                    stackedLabel
                }
            }
        }
        .frame(minHeight: 44)
        #if os(tvOS)
        .settingsFormRowLayout()
        #endif
        .contentShape(Rectangle())
    }

    private var stackedLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleText
            valueText
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(title)
            #if os(tvOS)
            .font(SettingsRowMetrics.titleFont)
            #else
            .font(.body.weight(.medium))
            #endif
            .multilineTextAlignment(.leading)
    }

    private var valueText: some View {
        Text(value)
            .multilineTextAlignment(.leading)
            .settingsRowSecondary()
    }
}

#endif
