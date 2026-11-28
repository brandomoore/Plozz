#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import FeatureLiveTV
import FeatureLiveTVCore
import FeatureSettings
import SwiftUI

struct PlozziOSLibrarySelectionView: View {
    let appModel: PlozziOSAppModel
    let accountIDs: [String]
    var hostsGuideProgress = true
    @Environment(\.themePalette) private var palette

    private var visibility: HomeLibraryVisibilityModel { appModel.settings.homeVisibility }
    private func onContinue() { appModel.completeLibrarySelection() }

    @State private var libraries: [AggregatedLibrary] = []
    @State private var isLoading = true
    @State private var failures: [String: AppError] = [:]
    private var loadFailed: Bool { !failures.isEmpty }
    @State private var loadGeneration = 0

    private var guides: [LiveTVGuidePreparationModel.Status] {
        accountIDs.compactMap { appModel.guidePreparation.statuses[$0] }
    }

    var body: some View {
        Group {
            if let request = appModel.plexHomeUsers.pendingPlexPINRequest {
                PlozziOSPlexPINView(
                    model: appModel.plexHomeUsers, request: request, dismissOnSuccess: false
                )
            } else {
                librarySelection
            }
        }
        .guidePreparationOverlay(
            model: appModel.guidePreparation, presenter: appModel.transientStatusPresenter,
            palette: palette, isEnabled: hostsGuideProgress
        )
        .offlineStatusOverlay(appModel: appModel, palette: palette, isEnabled: hostsGuideProgress)
        .task(id: loadID) {
            guard appModel.plexHomeUsers.pendingPlexPINRequest == nil else { return }
            await loadLibraries()
        }
        .interactiveDismissDisabled()
    }

    private var loadID: [String] {
        [appModel.profiles.activeProfileID, String(appModel.plexHomeUsers.plexIdentityGeneration)]
            + accountIDs
            + appModel.accountsProviders.accounts.map { "\($0.id):\($0.credentialRevision.rawValue)" }
    }

    private var librarySelection: some View {
        NavigationStack {
            Group {
                if isLoading {
                    SettingsPageScroll {
                        SetupProgressCard(
                            title: "Finding your libraries",
                            detail: "Checking your connected sources for available libraries.",
                            symbol: "rectangle.stack"
                        )
                        VStack(spacing: 12) {
                            Button(action: onContinue) {
                                Text("Choose later").plozzPageActionLabel()
                            }
                            .plozzPageActionButton()
                            Text("You can change these choices later in Settings.")
                                .font(.footnote)
                                .plozzForeground(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    Form {
                        content
                        Section {
                            Button(action: onContinue) {
                                Text("Continue").plozzPageActionLabel()
                            }
                            .plozzPageActionButton()
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        } footer: {
                            if !libraries.isEmpty || guides.isEmpty {
                                Text("You can change these choices later in Settings.")
                            }
                        }
                    }
                    .settingsPageSurface()
                }
            }
            .navigationTitle(libraries.isEmpty && !guides.isEmpty ? Text("Live TV") : Text("Choose Your Libraries"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !guides.isEmpty {
            Section {
                if libraries.isEmpty { Label("Playlist added", systemImage: "checkmark.circle") }
            } footer: {
                Text("You can start watching while the guide loads.")
            }
        }
        if libraries.isEmpty && guides.isEmpty {
            Section {
                ContentUnavailableView(
                    loadFailed ? "Couldn’t Load Libraries" : "No Video Libraries",
                    systemImage: loadFailed
                        ? "exclamationmark.triangle"
                        : "rectangle.stack"
                )
                if loadFailed {
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        Task { await loadLibraries() }
                    }
                }
            }
        } else {
            ForEach(smbGroups, id: \.serverKey) { group in
                SMBProfileLibrarySection(
                    group: group, libraries: Dictionary(grouping: libraries, by: \.accountID),
                    visibility: visibility,
                    included: { appModel.activeAccountIDs(for: appModel.profiles.activeProfileID).contains($0) },
                    setIncluded: { appModel.setAccount($0, enabled: $1, for: appModel.profiles.activeProfileID) },
                    failures: failures, retry: { await loadLibraries() }, first: false
                )
            }
            ForEach(groupedLibraries) { group in
                Section(group.serverName) {
                    ForEach(group.libraries) { library in
                        Toggle(
                            library.library.title,
                            isOn: Binding(
                                get: {
                                    visibility.isVisibleOnHome(library.key, library: library.library)
                                },
                                set: {
                                    visibility.setEnabled($0, for: library.key)
                                }
                            )
                        )
                    }
                }
            }

            if loadFailed {
                Section {
                    Label(
                        "Some servers could not be reached. Their libraries can be configured later in Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .plozzForeground(.secondary)
                }
            }
        }
    }

    private var smbGroups: [ServerAccountGroup] {
        libraryPickerGroups(from: appModel.accounts.filter { accountIDs.contains($0.id) })
            .filter { $0.transportKind == .smb }
    }

    private var groupedLibraries: [LibraryGroup] {
        var order: [String] = []
        var grouped: [String: [AggregatedLibrary]] = [:]
        for library in libraries where library.transportKind != .smb {
            if grouped[library.accountID] == nil {
                order.append(library.accountID)
            }

            grouped[library.accountID, default: []].append(library)
        }
        return order.compactMap { accountID in
            guard let choices = grouped[accountID],
                  let first = choices.first else { return nil }
            return LibraryGroup(
                id: accountID,
                serverName: first.serverName,
                libraries: choices
            )
        }
    }

    @MainActor
    private func loadLibraries() async {
        let scope = loadID
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        failures = [:]
        let accounts = appModel.accountsProviders.resolvedAccounts(withIDs: accountIDs)
        let discovery = await HomeAggregator().libraryDiscovery(
            from: accounts, expectedAccountIDs: Set(accountIDs)
        )
        guard !Task.isCancelled, generation == loadGeneration, scope == loadID else { return }
        failures = discovery.failures
        libraries = discovery.libraries.filter { !$0.library.isMusic }
        isLoading = false
        if discovery.canSkipSelection(for: accounts), guides.isEmpty { onContinue() }
    }
}

private struct LibraryGroup: Identifiable {
    let id: String
    let serverName: String
    let libraries: [AggregatedLibrary]
}
#endif
