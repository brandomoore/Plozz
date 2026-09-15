import CoreModels
import CoreUI
import SwiftUI

/// Sources-page section for peer descriptors that cannot be transferred safely.
/// Entering the address locally keeps the portable source ID, so its saved
/// channel preferences are not detached by a second, newly minted source.
public struct LiveTVPortablePendingSources: View {
    private let directory: URL
    private let sourceStore: any LiveTVSourcesStoring
    private let onChange: () -> Void
    @Environment(ProfilesModel.self) private var profiles: ProfilesModel?
    @State private var pending: [String: LiveTVPortableSource] = [:]
    @State private var localFiles: [String: LiveTVPortableSource] = [:]
    @State private var unavailable = false
    @State private var reloadRevision: UInt64 = 0
    @State private var loadedIdentity: Identity?

    private struct Identity: Hashable {
        let profileID: String
        let namespace: String?
        let epoch: String
        let consentRevision: String?
        let cloudEnabled: Bool
    }

    private struct Request: Hashable {
        let identity: Identity
        let revision: UInt64
    }

    public init(
        directory: URL, sourceStore: any LiveTVSourcesStoring,
        onChange: @escaping () -> Void = {}
    ) {
        self.directory = directory
        self.sourceStore = sourceStore
        self.onChange = onChange
    }

    public var body: some View {
        if let profiles {
            let identity = identity(for: profiles)
            let isCurrent = loadedIdentity == identity
            let visiblePending = isCurrent ? pending : [:]
            let visibleFiles = isCurrent ? localFiles : [:]
            VStack(spacing: 0) {
                if (isCurrent && unavailable) || !visiblePending.isEmpty || !visibleFiles.isEmpty {
                    SettingsSectionGroup {
                        if isCurrent && unavailable {
                            Text("Synced sources are unavailable.").settingsRowSecondary()
                        }
                        ForEach(visiblePending.keys.sorted(), id: \.self) { sourceID in
                            if let source = visiblePending[sourceID] {
                                NavigationLink {
                                    LiveTVPortablePlaylistSetup(
                                        sourceID: sourceID, descriptor: source, profiles: profiles,
                                        sourceStore: sourceStore, directory: directory
                                    ) {
                                        reloadRevision &+= 1
                                        onChange()
                                    }
                                } label: {
                                    SettingsRowLabel(icon: "icloud.and.arrow.down", title: "Set up IPTV source", trailing: {
                                        Text(source.name).settingsRowSecondary()
                                    })
                                }
                                .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                                .accessibilityIdentifier("live-tv-setup-synced-source-\(sourceID)")
                            }
                        }
                        if !visiblePending.isEmpty {
                            Text("Playlist addresses stay on each device. Enter the address here to use this source.")
                                .settingsRowSecondary()
                        }
                        ForEach(visibleFiles.keys.sorted(), id: \.self) { sourceID in
                            if let source = visibleFiles[sourceID] {
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text("This playlist file is stored on another device.")
                                        .settingsRowSecondary()
                                }
                            }
                        }
                    }
                }
            }
            .task(id: Request(identity: identity, revision: reloadRevision)) {
                await reload(identity: identity)
            }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidChange).receive(on: DispatchQueue.main)) { _ in
                reloadRevision &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .plozzLiveTVPortableStateDidApply).receive(on: DispatchQueue.main)) { notification in
                guard notification.object as? String == profiles.activeProfileID else { return }
                reloadRevision &+= 1
            }
        }
    }

    private func identity(for profiles: ProfilesModel) -> Identity {
        let profileID = profiles.activeProfileID
        let namespace = profileID == profiles.rootNamespaceOwnerID ? nil : profileID
        return Identity(
            profileID: profileID, namespace: namespace,
            epoch: LiveTVPortableSyncPreferenceStore.storageEpoch(),
            consentRevision: LiveTVPortableSyncPreferenceStore(
                profileID: profileID, namespace: namespace
            ).consentRevision,
            cloudEnabled: SyncSetupFeatureFlag().isEnabled
        )
    }

    private func reload(identity: Identity) async {
        let adapter = LiveTVPortableSyncAdapter(
            directory: directory, profileID: identity.profileID, namespace: identity.namespace,
            requiresPreparedJournal: true
        )
        defer { adapter.discardPreparedJournal() }
        do {
            if adapter.isEnabled { try await adapter.prepareForOperation() }
            guard !Task.isCancelled, let profiles,
                  self.identity(for: profiles) == identity else { return }
            let report = adapter.isEnabled
                ? try adapter.pending(sourceStore: sourceStore, includeLibrarySnapshots: false)
                : LiveTVPortableImport()
            pending = report.pendingPlaylists
            localFiles = report.localFileSources
            unavailable = false
            loadedIdentity = identity
        } catch {
            guard !Task.isCancelled, let profiles,
                  self.identity(for: profiles) == identity else { return }
            pending = [:]
            localFiles = [:]
            unavailable = true
            loadedIdentity = identity
        }
    }
}

private struct LiveTVPortablePlaylistSetup: View {
    let sourceID: String
    let descriptor: LiveTVPortableSource
    let profiles: ProfilesModel
    let sourceStore: any LiveTVSourcesStoring
    let directory: URL
    let onChange: () -> Void
    @State private var access: LiveTVSourceManagementAccess
    @Environment(\.dismiss) private var dismiss
    private let profileID: String

    init(
        sourceID: String, descriptor: LiveTVPortableSource, profiles: ProfilesModel,
        sourceStore: any LiveTVSourcesStoring, directory: URL, onChange: @escaping () -> Void
    ) {
        self.sourceID = sourceID
        self.descriptor = descriptor
        self.profiles = profiles
        self.sourceStore = sourceStore
        self.directory = directory
        self.onChange = onChange
        profileID = profiles.activeProfileID
        _access = State(initialValue: LiveTVSourceManagementAccess(profiles: profiles))
    }

    var body: some View {
        if access.canManage {
            LiveTVPlaylistEditor(name: descriptor.name) { input in
                guard access.canManage, profiles.activeProfileID == profileID else {
                    throw LiveTVSourceApprovalError.staleAuthority
                }
                let adapter = LiveTVPortableSyncAdapter(
                    directory: directory, profileID: profileID,
                    namespace: profileID == profiles.rootNamespaceOwnerID ? nil : profileID
                )
                guard adapter.isEnabled,
                      try adapter.pendingPlaylistDescriptor(
                          sourceID: sourceID, sourceStore: sourceStore
                      ) == descriptor else {
                    throw LiveTVSourcesStoreError.saveFailed
                }
                var configuration = try sourceStore.load()
                guard !configuration.playlists.contains(where: { $0.id == sourceID }),
                      !configuration.servers.contains(where: { $0.id == sourceID }) else {
                    throw LiveTVSourcesStoreError.saveFailed
                }
                configuration.playlists.append(LiveTVPlaylistSource(
                    id: sourceID, name: input.name, playlistURL: input.playlistURL,
                    guideURLs: input.guideURLs, isEnabled: descriptor.isEnabled,
                    discoversPlaylistGuides: descriptor.discoversPlaylistGuides ?? true,
                    guideLookbackDays: descriptor.guideLookbackDays ?? 1,
                    guideLookaheadDays: descriptor.guideLookaheadDays ?? 7
                ))
                // Explicit setup preserves paused state and never manufactures a
                // parental approval. The source-level approval action remains visible.
                try sourceStore.save(configuration)
                onChange()
            }
        } else {
            PINEntryScaffold(
                title: KidsProfileCopy.parentalPINEnter,
                name: Text(KidsProfileCopy.parentalPIN),
                errorMessage: access.errorMessage,
                onSubmit: { access.unlock($0) },
                onCancel: { dismiss() }
            ) {
                PINBadge {
                    Image(systemName: "figure.and.child.holdinghands")
                        .font(.system(size: PINLayout.badgeSize * 0.45, weight: .semibold))
                }
            }
        }
    }
}
