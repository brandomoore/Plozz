#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

struct ViewPreferenceChoiceGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if os(tvOS)
        SettingsCheckGroup {
            VStack(alignment: .leading, spacing: 8, content: content)
        }
        #else
        SettingsSectionGroup(content: content)
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
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        SettingsDetailLink(destination: destination) {
            ViewCustomizationLinkLabel(isCustomized: isCustomized)
        }
        #if os(tvOS)
        .buttonStyle(SettingsFocusButtonStyle())
        #endif
    }
}

private struct ViewCustomizationLinkLabel: View {
    let isCustomized: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout())
            layout {
                Text("Customize by view")
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
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
    }
}

struct ViewCustomizationList<Content: View>: View {
    let title: LocalizedStringResource
    let initialRowID: String
    var focusedHelp: (String) -> ViewCustomizationHelp? = { _ in nil }
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsDetailNavigation.self) private var detailNavigation: SettingsDetailNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.themePalette) private var palette
    @FocusState private var focusedRow: String?
    @State private var hasEnteredList = false
    @Namespace private var focusScope

    var body: some View {
        #if os(tvOS)
        let help = focusedHelp(focusedRow ?? initialRowID)
        VStack(spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Button {
                        if let detailNavigation {
                            detailNavigation.pop(animated: !reduceMotion)
                        } else {
                            dismiss()
                        }
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .accessibilityIdentifier("view-customization-back")
                    .disabled(!hasEnteredList)
                    Text(title).settingsFeatureTitle()
                    VStack(alignment: .leading, spacing: 8, content: content)
                }
                .environment(\.viewCustomizationFocus, $focusedRow)
                .focusScope(focusScope)
                .defaultFocus($focusedRow, initialRowID)
                .task { focusedRow = initialRowID }
                .onChange(of: focusedRow) { _, row in
                    if row != nil {
                        hasEnteredList = true
                        detailNavigation?.focusArrived()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 40)
                .padding(.bottom, 24)
                .padding(.horizontal, 48)
            }
            .contentMargins(.bottom, help == nil ? 0 : 40, for: .scrollContent)
            .verticalEdgeFadeMask(topFade: 0, bottomFade: help == nil ? 0 : 40, horizontalOverhang: 20)
            .accessibilityIdentifier("view-customization-scroll")
            if let help {
                ViewCustomizationHelpCard(help: help)
                    .padding(.horizontal, 48)
                    .padding(.bottom, 24)
            }
        }
        .navigationTitle(Text(verbatim: ""))
        #else
        List {
            content()
                .listRowBackground(palette.surface(.raised).fill)
                .listRowSeparatorTint(palette.separator)
        }
        .listStyle(.insetGrouped)
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
        .buttonStyle(SettingsFocusButtonStyle())
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

private struct ViewCustomizationRowFocus: ViewModifier {
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
            .font(.body.weight(.medium))
            .multilineTextAlignment(.leading)
    }

    private var valueText: some View {
        Text(value)
            .multilineTextAlignment(.leading)
            .settingsRowSecondary()
    }
}

#endif
