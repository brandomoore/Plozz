#if os(iOS)
import CoreModels
import CoreUI
import SwiftUI

/// Full-page "we found your setup" screen — the promoted, full-screen version of the
/// mid-session new-server drawer. Shown on a fresh launch ONLY when we detected
/// household servers that genuinely need bringing over (see
/// `PlozziOSAppModel.pendingServersNeedingSetup` — in practice Apple-TV-origin
/// servers, since iOS→iOS logins auto-connect silently and never reach here).
///
/// The app leads with what it already knows: instead of the plain provider chooser,
/// a returning user sees their own setup and one tap to bring it over. A quiet
/// "Later in Settings" defers these offers on this device. Adaptive: two columns when
/// wide (iPad landscape), stacked when narrow (iPhone / iPad portrait).
@MainActor
struct PlozziOSDetectedSetupView: View {
    @Environment(\.themePalette) private var palette
    @Environment(\.horizontalSizeClass) private var hSize
    let appModel: PlozziOSAppModel
    let servers: [SyncedAccountDescriptor]
    /// Bring everything over from the detected device (runs the receive/pairing flow,
    /// seamless on the same iCloud account).
    let onSetUpFromDevice: () -> Void
    /// Keep setup available in Settings without prompting again.
    let onSetUpLater: () -> Void

    private var serverGroups: [SyncedServerAccountGroup] {
        SyncedServerAccountGroup.groups(
            from: servers,
            localAccounts: appModel.accountsProviders.accounts
        )
    }
    private var localServerKeys: Set<String> {
        Set(appModel.accountsProviders.accounts.map {
            SyncedServerAccountGroup.physicalServerKey(
                provider: $0.server.provider,
                serverID: $0.server.id,
                fallbackURL: $0.server.baseURL
            )
        })
    }
    private var existingServerGroups: [SyncedServerAccountGroup] {
        serverGroups.filter { localServerKeys.contains($0.id) }
    }
    private var newServerGroups: [SyncedServerAccountGroup] {
        serverGroups.filter { !localServerKeys.contains($0.id) }
    }
    private var originName: String? {
        servers.compactMap { descriptor in
            let name = descriptor.originDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return name?.isEmpty == false ? name : nil
        }.first
    }

    /// SF Symbol for the origin device kind, matching the new-server drawer's mapping.
    private var originIcon: String {
        switch servers.compactMap(\.originDeviceKind).first {
        case "tv": return "appletv.fill"
        case "pad": return "ipad"
        case "phone": return "iphone"
        case "mac": return "desktopcomputer"
        default: return "display"
        }
    }

    private var isWide: Bool { hSize == .regular }

    var body: some View {
        ZStack {
            AppBackground(palette: palette)
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if isWide {
                            HStack(alignment: .center, spacing: 64) {
                                branding
                                    .frame(maxWidth: .infinity)
                                card
                                    .frame(maxWidth: .infinity)
                            }
                            .frame(minHeight: geo.size.height)
                        } else {
                            VStack(spacing: 32) {
                                Spacer(minLength: geo.size.height * 0.06)
                                branding
                                card
                                Spacer(minLength: 24)
                            }
                            .frame(maxWidth: 500)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: geo.size.height)
                        }
                    }
                    .padding(.horizontal, isWide ? 56 : 24)
                }
            }
        }
    }

    private var branding: some View {
        Image("PlozzLogo")
            .resizable().scaledToFit()
            .frame(width: 88, height: 88)
            .accessibilityHidden(true)
    }

    private var card: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 0) {
                ForEach(Array(serverGroups.prefix(4))) { group in
                    serverRow(group)
                    if group.id != serverGroups.prefix(4).last?.id { divider }
                }
                if serverGroups.count > 4 {
                    divider
                    Text("+ \(serverGroups.count - 4) more")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                }
            }
            .background(palette.cardSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.cardBorder, lineWidth: 1)
            )
            .padding(.top, 22)

            actions
                .padding(.top, 24)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(detectionTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            subtitle
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var detectionTitle: LocalizedStringResource {
        if newServerGroups.isEmpty {
            return servers.count == 1
                ? "We found another user"
                : "We found more users"
        }
        if !existingServerGroups.isEmpty {
            return "We found more of your setup"
        }
        return serverGroups.count == 1
            ? "We found your server"
            : "We found your servers"
    }

    private var subtitle: Text {
        if let originName {
            return Text("From \(Image(systemName: originIcon)) \(originName)")
        }
        return Text("From another device")
    }

    private func serverRow(_ group: SyncedServerAccountGroup) -> some View {
        HStack(spacing: 14) {
            ProviderBrandMark(provider: group.provider, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.serverName)
                    .font(.headline)
                    .foregroundStyle(palette.primaryText)
                    .lineLimit(1)
                userSummary(for: group)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    /// Returns `Text`, not a `String`: this is app copy wrapped around provider
    /// content, and a concatenated `String` reaching `Text` renders verbatim and
    /// is never translated. Names are joined with a list format style so the
    /// separator and final conjunction follow the reader's language.
    private func userSummary(for group: SyncedServerAccountGroup) -> Text {
        let names = group.userNames
        guard !names.isEmpty else { return Text(verbatim: group.provider.displayName) }
        let joined = names.formatted(.list(type: .and))
        return localServerKeys.contains(group.id)
            ? Text("Add \(joined)")
            : Text("Sign in as \(joined)")
    }

    private var divider: some View {
        Rectangle().fill(palette.cardBorder).frame(height: 1)
            .padding(.horizontal, 1)
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: onSetUpFromDevice) {
                Text("Set Up")
                .fontWeight(.semibold)
                .foregroundStyle(palette.onAccent)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(action: onSetUpLater) {
                Text("Later in Settings")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .tint(palette.accent)
    }
}
#endif
