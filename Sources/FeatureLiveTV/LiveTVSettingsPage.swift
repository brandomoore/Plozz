import CoreUI
import SwiftUI

struct LiveTVSetupActionLabel: View {
    let title: LocalizedStringResource
    let symbol: String

    var body: some View {
        SettingsRowLabel(icon: symbol, title: title)
        #if os(tvOS)
        .padding(.vertical, 4)
        #endif
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
    }

    private var minimumHeight: CGFloat {
        #if os(tvOS)
        64
        #else
        44
        #endif
    }
}

struct LiveTVSetupField: View {
    let title: LocalizedStringResource
    @Binding var text: String
    var isAddress = false
    var identifier = ""
    var example: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .settingsRowSecondary()
            TextField(text: $text, prompt: example.map { Text(verbatim: $0) }) { Text(title) }
                .font(.body)
                .frame(minHeight: minimumHeight)
                .textInputAutocapitalization(isAddress ? .never : .words)
                .autocorrectionDisabled(isAddress)
                .privacySensitive()
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(Text(title))
                #if os(iOS)
                .keyboardType(isAddress ? .URL : .default)
                #endif
        }
    }

    private var minimumHeight: CGFloat {
        #if os(tvOS)
        64
        #else
        44
        #endif
    }
}

struct LiveTVGuideAddressEditor: View {
    @Binding var address: String
    let remove: () -> Void

    var body: some View {
        #if os(tvOS)
        HStack(alignment: .bottom, spacing: 24) {
            addressField
                .frame(maxWidth: .infinity)
            removeButton
                .frame(width: 320)
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            addressField
            removeButton
        }
        #endif
    }

    private var addressField: some View {
        LiveTVSetupField(
            title: "XMLTV guide URL (optional)", text: $address, isAddress: true,
            example: "https://example.com/guide.xml"
        )
    }

    private var removeButton: some View {
        Button(action: remove) {
            LiveTVSetupActionLabel(title: "Remove guide", symbol: "minus.circle")
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
        .accessibilityIdentifier("live-tv-remove-guide")
    }
}

struct LiveTVSettingsPage<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsPageHeader(title)
                content()
            }
            .frame(maxWidth: PlozzTheme.Metrics.settingsContentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 24)
        }
        .scrollClipDisabled()
        .background { SettingsPageBackground() }
        #else
        SettingsPageList {
            content()
        }
        .navigationTitle(Text(title))
        #endif
    }
}
