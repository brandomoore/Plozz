#if os(iOS)
import CoreModels
import CoreUI
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

struct ServerLinkCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? min(1, remaining / lifetime) : 0
            let tint: Color = remaining <= 15 ? .orange : .accentColor
            ZStack {
                Circle().stroke(tint.opacity(0.16), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Int(remaining.rounded(.up)), format: .number)
                    .font(.title3.monospacedDigit().bold())
                    .minimumScaleFactor(0.25)
                    .padding(12)
                    .foregroundStyle(tint)
            }
            .frame(width: 76, height: 76)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code expires in \(Int(remaining.rounded(.up))) seconds")
        }
    }
}

struct ServerConnectionCode: View {
    let code: String
    let expiresAt: Date
    let lifetime: TimeInterval

    var body: some View {
        VStack(spacing: 20) {
            ConnectionCodeView(code, size: 64)
                .textSelection(.enabled)
            ServerLinkCountdown(expiresAt: expiresAt, lifetime: lifetime)
            Text("Waiting for approval…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
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
