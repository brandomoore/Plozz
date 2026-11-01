#if os(iOS)
import CoreModels
import CoreUI
import FeatureAuth
import ProviderPlex
import SwiftUI

struct ServerOnboardingPage<Content: View>: View {
    let provider: ProviderKind?
    let title: Text
    var subtitle: Text?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 16) {
                    if let provider {
                        ProviderBrandMark(provider: provider, size: 72)
                            .accessibilityHidden(true)
                    }
                    OnboardingHeader(title, subtitle: subtitle)
                }
                .frame(maxWidth: .infinity)
                content()
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .settingsPageSurface(horizontalInset: 20)
    }
}

struct ServerProviderChoices: View {
    let onSelect: (ProviderKind) -> Void

    var body: some View {
        SettingsSectionGroup {
            ForEach([ProviderKind.jellyfin, .plex, .emby, .silo, .mediaShare, .iptv], id: \.self) { provider in
                Button {
                    onSelect(provider)
                } label: {
                    HStack(spacing: 16) {
                        ProviderBrandMark(provider: provider, size: 40)
                            .accessibilityHidden(true)
                        Text(verbatim: provider.displayName)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityIdentifier("add-server-provider-\(provider.rawValue)")
            }
        }
    }
}

struct ServerConnectionCode: View {
    @Environment(\.themePalette) private var palette
    let code: String
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        VStack(spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    codePanel
                    countdown
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 20) {
                    codePanel
                    countdown
                }
            }
            Text("Waiting for approval…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var codePanel: some View {
        ConnectionCodeView(code)
            .textSelection(.enabled)
    }

    private var countdown: some View {
        LinkCodeExpiryCountdown(
            expiresAt: expiresAt, lifetime: lifetime, size: 56,
            tint: palette.secondaryText
        )
    }
}

struct PlexServerSelection: View {
    let servers: [PlexServerCandidate]
    @Binding var selected: Set<String>

    var body: some View {
        SettingsSectionGroup {
            ForEach(servers) { server in
                Button {
                    if !selected.insert(server.id).inserted {
                        selected.remove(server.id)
                    }
                } label: {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: server.name).font(.headline)
                            Text(server.isOwned ? "Owned" : "Shared")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Image(systemName: selected.contains(server.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                }
                .accessibilityAddTraits(selected.contains(server.id) ? .isSelected : [])
                .accessibilityIdentifier("plex-server-\(server.id)")
            }
        }
    }
}
#endif
