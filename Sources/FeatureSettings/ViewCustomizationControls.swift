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
                    Text(title).font(.body.weight(.medium))
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationLink(destination: destination) {
            HStack {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                    : AnyLayout(HStackLayout())
                layout {
                    Text("Customize by view")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Group {
                        if count == 0 {
                            Text("Using defaults")
                        } else {
                            Text("\(count) customized")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                #if os(tvOS)
                Image(systemName: "chevron.right").accessibilityHidden(true)
                #endif
            }
        }
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
