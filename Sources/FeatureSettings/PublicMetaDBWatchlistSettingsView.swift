#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBWatchlistSettingsView: View {
    let service: PublicMetaDBService

    var body: some View {
        GroupedSettingsPage(title: "Watchlist destination", backIdentifier: "publicmetadb.watchlist.back") {
            SettingsSectionGroup {
                NavigationLink {
                    PublicMetaDBWatchlistPicker(service: service)
                } label: {
                    HStack {
                        Text("PublicMetaDB list")
                        Spacer()
                        if let selection = service.watchlistSelection {
                            Text(verbatim: selection.listName).settingsRowSecondary()
                        } else {
                            Text("None").settingsRowSecondary()
                        }
                    }
                }
                .disabled(service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.watchlist.choose")
            } footer: {
                Text("Sync this profile’s watchlist with one PublicMetaDB list on this device.")
            }
            if service.watchlistSelection != nil {
                SettingsSectionGroup {
                    Button("Stop syncing") { service.disableWatchlist() }
                        .settingsActionRow()
                        .accessibilityIdentifier("publicmetadb.watchlist.disable")
                } footer: {
                    Text("Keeps the items in both lists.")
                }
            }
        }
    }
}

private struct PublicMetaDBWatchlistPicker: View {
    let service: PublicMetaDBService
    @Environment(\.dismiss) private var dismiss
    @State private var choice: Choice?
    @State private var confirming = false
    @State private var failure: (any Error)?
    @State private var operation: Task<Void, Never>?
    @State private var saving = false

    private struct Choice {
        let list: PublicMetaDB.List
        let connectionID: UUID
    }

    var body: some View {
        PublicMetaDBPagedRecords(
            service: service, title: "Choose a list", load: { try await $0.lists(page: $1) }
        ) { list in
            Button {
                guard let connectionID = service.connectionID else { return }
                choice = Choice(list: list, connectionID: connectionID)
                confirming = true
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: list.name)
                    Text(list.isPublic ? "Public" : "Private").foregroundStyle(.secondary)
                }
            }
            .disabled(saving)
        }
        .confirmationDialog("Use this watchlist destination?", isPresented: $confirming, presenting: choice) { choice in
            Button("Use this list") { enable(choice) }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            PublicMetaDBWatchlistConsent(name: choice.list.name, isPublic: choice.list.isPublic)
        }
        .alert("PublicMetaDB", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            if let failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            choice = nil
            operation?.cancel()
        }
        .onDisappear { operation?.cancel() }
    }

    private func enable(_ choice: Choice) {
        saving = true
        operation = Task {
            defer { saving = false }
            do {
                try await service.enableWatchlist(choice.list, expectedConnectionID: choice.connectionID)
                dismiss()
            } catch {
                if !Task.isCancelled { failure = error }
            }
        }
    }
}

private struct PublicMetaDBWatchlistConsent: View {
    let name: String
    let isPublic: Bool
    var body: some View {
        publicMetaDBConfirmationMessage(
            Text("“\(name)” and your Plozz watchlist will share additions and removals, including existing items. Changes can reach other synced lists. Adding a show may clear its dropped status."),
            isPublic ? Text("This list is public. Others can see its contents.")
                : Text("This list is private.")
        )
    }
}
#endif
