#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

#if os(tvOS)
struct SettingsLibrariesRow: View {
    let accounts: [Account]
    let isAccountIncluded: (String) -> Bool
    var icon = "externaldrive.connected.to.line.below"

    var body: some View {
        SettingsSectionButton(
            title: Text(SettingsCopy.sources), icon: icon,
            subtitleContent: AnyView(SettingsLibrarySourcesSummary(
                accounts: accounts, isAccountIncluded: isAccountIncluded
            )), route: .myLibraries
        )
    }

    static func watchedServerGroups(
        in accounts: [Account], isAccountIncluded: (String) -> Bool
    ) -> [ServerAccountGroup] {
        SettingsLibrarySourcesSummary.watchedServerGroups(
            in: accounts, isAccountIncluded: isAccountIncluded
        )
    }
}
#endif

/// The added sources this profile watches, independent of library discovery.
public struct SettingsLibrarySourcesSummary: View {
    private let accounts: [Account]
    private let isAccountIncluded: (String) -> Bool
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?

    public init(accounts: [Account], isAccountIncluded: @escaping (String) -> Bool) {
        self.accounts = accounts
        self.isAccountIncluded = isAccountIncluded
    }

    public var body: some View {
        let groups = Self.watchedServerGroups(in: accounts, isAccountIncluded: isAccountIncluded,
                                              names: profiles?.activeProfile.sourceNames)
        if groups.isEmpty {
            Text("No sources yet")
        } else {
            #if os(tvOS)
            HStack(alignment: .center, spacing: 10) {
                let visible = Array(groups.prefix(3))
                let overflow = groups.count - visible.count
                ForEach(Array(visible.enumerated()), id: \.element.serverKey) { index, group in
                    if index > 0 { Text(verbatim: "·") }
                    HStack(spacing: 8) {
                        ProviderIcon(
                            provider: group.providerKind, size: 24,
                            mediaShareTransport: group.transportKind
                        )
                        .scaleEffect(1.3)
                        .padding(.horizontal, 4)
                        Text(verbatim: group.serverName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }
                if overflow > 0 {
                    Text("· +\(overflow) more")
                        .fixedSize()
                }
            }
            .accessibilityElement(children: .combine)
            #else
            ViewThatFits(in: .horizontal) {
                if groups.count >= 3 {
                    MobileLibrarySourcesStrip(groups: groups, visibleCount: 3)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if groups.count >= 2 {
                    MobileLibrarySourcesStrip(groups: groups, visibleCount: 2)
                        .fixedSize(horizontal: true, vertical: false)
                }
                MobileLibrarySourcesStrip(groups: groups, visibleCount: 1)
                    .fixedSize(horizontal: true, vertical: false)
                MobileLibrarySourcesStrip(groups: groups, visibleCount: 1, compactOverflow: true)
            }
            .accessibilityElement(children: .combine)
            #endif
        }
    }

    static func watchedServerGroups(
        in accounts: [Account], isAccountIncluded: (String) -> Bool, names: [String: String]? = nil
    ) -> [ServerAccountGroup] {
        accounts.filter { isAccountIncluded($0.id) }.map { account in
            ServerAccountGroup(serverKey: account.id, serverName: names?[account.id] ?? account.server.name,
                               providerKind: account.server.provider, accounts: [account])
        }
    }
}

#if !os(tvOS)
private struct MobileLibrarySourcesStrip: View {
    let groups: [ServerAccountGroup]
    let visibleCount: Int
    var compactOverflow = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(groups.prefix(visibleCount).enumerated()), id: \.element.serverKey) { index, group in
                if index > 0 { Text(verbatim: "·") }
                HStack(spacing: 6) {
                    ProviderIcon(
                        provider: group.providerKind, size: 16,
                        mediaShareTransport: group.transportKind
                    )
                    .accessibilityHidden(true)
                    Text(verbatim: group.serverName)
                }
            }
            if groups.count > visibleCount {
                Group {
                    if compactOverflow {
                        Text("+\(groups.count - visibleCount)")
                            .accessibilityLabel(Text("+\(groups.count - visibleCount) more"))
                    } else {
                        Text("· +\(groups.count - visibleCount) more")
                    }
                }
                .fixedSize()
            }
        }
        .lineLimit(1)
    }
}
#endif
#endif
