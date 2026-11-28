#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

/// Each switch changes profile membership for one root, not a server identity.
public struct SMBProfileLibrarySection: View {
    let group: ServerAccountGroup
    let libraries: [String: [AggregatedLibrary]]
    let visibility: HomeLibraryVisibilityModel
    let included: (String) -> Bool
    let setIncluded: (String, Bool) -> Void
    let failures: [String: AppError]
    let retry: () async -> Void
    let first: Bool

    public init(group: ServerAccountGroup, libraries: [String: [AggregatedLibrary]],
                visibility: HomeLibraryVisibilityModel, included: @escaping (String) -> Bool,
                setIncluded: @escaping (String, Bool) -> Void, failures: [String: AppError],
                retry: @escaping () async -> Void, first: Bool) {
        self.group = group
        self.libraries = libraries
        self.visibility = visibility
        self.included = included
        self.setIncluded = setIncluded
        self.failures = failures
        self.retry = retry
        self.first = first
    }

    public var body: some View {
        SettingsSectionGroup {
            HStack {
                ProviderBrandMark(provider: .mediaShare, size: 32, mediaShareTransport: .smb)
                Text(verbatim: group.serverName)
                Spacer()
                if let name = group.accounts.first?.userName, !name.isEmpty {
                    Text(verbatim: name).plozzForeground(.secondary)
                }
            }
            ForEach(group.accounts) { account in
                let name = account.server.mediaShareLibraryConfiguration?.name ?? account.server.name
                Toggle(isOn: Binding(get: { included(account.id) }, set: { setIncluded(account.id, $0) })) {
                    Text(verbatim: name)
                }
                .settingsWorkspaceEntry(first && account.id == group.accounts.first?.id)
                .settingsSearchAnchor(first && account.id == group.accounts.first?.id
                    ? "profile-source-inclusion" : "profile-source-\(account.id)",
                    fallbackFor: first && account.id == group.accounts.first?.id ? ["profile-library-inclusion"] : [])
                if included(account.id) {
                    let choices = AggregatedLibrary.smbPickerChoices(libraries[account.id] ?? [], rootName: name)
                    ForEach(choices) { choice in
                        // Keep disabled legacy selections recoverable. A single
                        // enabled category needs no duplicate row beneath its root.
                        if choices.count > 1 || !visibility.isEnabled(choice.key) {
                            SettingsCheckableRow(title: choice.library.displayName,
                                                 isChecked: visibility.isEnabled(choice.key),
                                                 prominence: .secondary, flushLeading: false) {
                                visibility.setEnabled(!visibility.isEnabled(choice.key), for: choice.key)
                            }
                        }
                    }
                    if let failure = failures[account.id] {
                        Text(failure.userMessage)
                        Button("Retry") { Task { await retry() } }
                    }
                }
            }
            #if os(tvOS)
            SettingsLibraryUpdateStatus(shareIDs: Set(group.accounts.filter { included($0.id) }.map(\.id)))
            #endif
        }
    }
}
#endif
