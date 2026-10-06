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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .settingsRowSecondary()
            TextField(text: $text, prompt: Text(verbatim: example ?? "")) { Text(title) }
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
        HStack(alignment: .bottom, spacing: 8) {
            addressField
            Button("Remove guide", systemImage: "minus.circle", role: .destructive, action: remove)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .accessibilityIdentifier("live-tv-remove-guide")
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

struct LiveTVGuideFields: View {
    @Binding var guides: [LiveTVPlaylistEditorModel.GuideAddress]

    var body: some View {
        SettingsSectionGroup("Program guide") {
            ForEach($guides) { $guide in
                LiveTVGuideAddressEditor(address: $guide.address) {
                    let id = guide.id
                    guides.removeAll { $0.id == id }
                }
                .contextMenu {
                    Button("Move guide earlier") { move(guide.id, by: -1) }
                        .disabled(guides.first?.id == guide.id)
                    Button("Move guide later") { move(guide.id, by: 1) }
                        .disabled(guides.last?.id == guide.id)
                }
            }
            Button { guides.append(.init()) } label: {
                LiveTVSetupActionLabel(
                    title: guides.isEmpty ? "Add guide" : "Add another guide", symbol: "plus"
                )
            }
            .buttonStyle(SettingsFocusButtonStyle(size: .contained))
            .disabled(guides.count >= 32)
            .accessibilityIdentifier("live-tv-add-guide")
        } footer: {
            Text("Optional XMLTV or .xml.gz. List preferred guides first.")
        }
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = guides.firstIndex(where: { $0.id == id }),
              guides.indices.contains(index + offset) else { return }
        guides.swapAt(index, index + offset)
    }
}

struct LiveTVSettingsPage<Content: View>: View {
    let title: LocalizedStringResource
    var sourceName: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(tvOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let sourceName { SettingsPageHeader(verbatim: sourceName) }
                else { SettingsPageHeader(title) }
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
        SettingsPageScroll {
            content()
        }
        .navigationTitle(sourceName.map { Text(verbatim: $0) } ?? Text(title))
        #endif
    }
}
