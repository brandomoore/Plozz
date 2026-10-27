#if os(iOS)
import AppRuntime
import CoreModels
import CoreUI
import FeatureHomeCore
import SwiftUI

struct PlozziOSLibrarySelectionView: View {
    let appModel: PlozziOSAppModel
    let accountIDs: [String]

    private var visibility: HomeLibraryVisibilityModel { appModel.settings.homeVisibility }
    private func onContinue() { appModel.completeLibrarySelection() }

    @State private var libraries: [LibraryChoice] = []
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var loadGeneration = 0

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
                                Text("Choose later").frame(maxWidth: .infinity)
                            }
                            .plozzActionButton(role: .primary)
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
                                Text("Continue").frame(maxWidth: .infinity)
                            }
                            .plozzActionButton(role: .primary)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                        } footer: {
                            Text("You can change these choices later in Settings.")
                        }
                    }
                    .settingsPageSurface()
                }
            }
            .navigationTitle("Choose Your Libraries")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var content: some View {
        if libraries.isEmpty {
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

    private var groupedLibraries: [LibraryGroup] {
        var order: [String] = []
        var grouped: [String: [LibraryChoice]] = [:]
        for library in libraries {
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
        loadFailed = false
        let accounts = appModel.accountsProviders.resolvedAccounts(withIDs: accountIDs)
        let discovery = await HomeAggregator().libraryDiscovery(
            from: accounts, expectedAccountIDs: Set(accountIDs)
        )
        guard !Task.isCancelled, generation == loadGeneration, scope == loadID else { return }
        loadFailed = !discovery.unreachableAccountIDs.isEmpty
        libraries = discovery.libraries.filter { !$0.library.isMusic }.map {
            LibraryChoice(accountID: $0.accountID, serverName: $0.serverName, library: $0.library)
        }
        isLoading = false
        if discovery.canSkipSelection(for: accounts) { onContinue() }
    }
}

private struct LibraryChoice: Identifiable {
    let accountID: String
    let serverName: String
    let library: MediaLibrary

    var id: String { key }
    var key: String { "\(accountID):\(library.id)" }
}

private struct LibraryGroup: Identifiable {
    let id: String
    let serverName: String
    let libraries: [LibraryChoice]
}
#endif
