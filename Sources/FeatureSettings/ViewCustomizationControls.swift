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
        VStack(alignment: .leading, spacing: 20, content: content)
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
    let count: Int
    @ViewBuilder var destination: () -> Destination
    @Environment(SettingsDetailNavigation.self) private var detailNavigation: SettingsDetailNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.settingsDetailRootFocusScope) private var rootFocusScope
    @Environment(\.settingsDetailRootEnabled) private var rootEnabled
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let detailNavigation {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        detailNavigation.push()
                    }
                } label: {
                    ViewCustomizationLinkLabel(count: count)
                }
                .focused($isFocused)
                .modifier(SettingsDetailReturnFocus())
                .environment(\.isEnabled, rootEnabled && !detailNavigation.isPresented)
            } else {
                NavigationLink(destination: destination) {
                    ViewCustomizationLinkLabel(count: count)
                }
                .focused($isFocused)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused { detailNavigation?.focusArrived() }
        }
        .task(id: detailNavigation?.returnFocusGeneration) {
            guard let detailNavigation, detailNavigation.returnFocusGeneration > 0 else { return }
            isFocused = false
            await Task.yield()
            if !Task.isCancelled, !detailNavigation.isPresented {
                isFocused = true
                #if os(tvOS)
                if let rootFocusScope { resetFocus(in: rootFocusScope) }
                #endif
            }
        }
    }
}

private struct SettingsDetailReturnFocus: ViewModifier {
    @Environment(SettingsDetailNavigation.self) private var navigation: SettingsDetailNavigation?
    @Environment(\.settingsDetailRootFocusScope) private var scope

    @ViewBuilder
    func body(content: Content) -> some View {
        if let scope {
            content.tvOSPrefersDefaultFocus(navigation?.awaitingFocus == true, in: scope)
        } else {
            content
        }
    }
}

private struct ViewCustomizationLinkLabel: View {
    let count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout())
            layout {
                Text("Customize by view")
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if count > 0 {
                    Text("\(count) customized")
                        .foregroundStyle(.secondary)
                }
            }
            #if os(tvOS)
            Image(systemName: "chevron.right").accessibilityHidden(true)
            #endif
        }
    }
}

struct ViewCustomizationList<Content: View>: View {
    let title: LocalizedStringResource
    let initialRowID: String
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsDetailNavigation.self) private var detailNavigation: SettingsDetailNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedRow: String?
    @State private var hasEnteredList = false
    @Namespace private var focusScope

    var body: some View {
        #if os(tvOS)
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
            .padding(.bottom, 48)
            .padding(.horizontal, 48)
        }
        .navigationTitle(Text(verbatim: ""))
        #else
        List(content: content)
            .settingsPageSurface()
            .navigationTitle(Text(title))
        #endif
    }
}

struct ViewCustomizationChoice: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let isSelected: Bool
    let action: () -> Void
}

struct ViewCustomizationRow: View {
    let id: String
    let title: LocalizedStringResource
    let value: LocalizedStringResource
    let isCustomized: Bool
    let choices: [ViewCustomizationChoice]
    let reset: () -> Void

    var body: some View {
        Menu {
            Section {
                ForEach(choices) { choice in
                    Button(action: choice.action) {
                        if choice.isSelected {
                            Label {
                                Text(choice.title)
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                        } else {
                            Text(choice.title)
                        }
                    }
                    .accessibilityIdentifier(choice.id)
                }
            }
            if isCustomized {
                Section {
                    Button("Remove customization", action: reset)
                        .accessibilityIdentifier("\(id)-reset")
                }
            }
        } label: {
            ViewCustomizationRowLabel(title: title, value: value, isCustomized: isCustomized)
        }
        #if os(tvOS)
        .buttonStyle(SettingsFocusButtonStyle())
        #else
        .tint(.primary)
        #endif
        .accessibilityLabel(Text(title))
        .accessibilityValue(isCustomized ? Text("\(Text(value)), customized") : Text(value))
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
    let isCustomized: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 16) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 20))
            layout {
                Text(title).font(.body.weight(.medium))
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 12) }
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    Text(value)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                    if isCustomized { Text("Custom").font(.caption) }
                }
                .settingsRowSecondary()
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        #if os(tvOS)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #endif
        .contentShape(Rectangle())
    }
}

struct ViewCustomizationResetButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button("Remove view customizations", action: action)
            .disabled(!isEnabled)
    }
}
#endif
