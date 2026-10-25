#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBWatchlistSettingsView: View {
    let service: PublicMetaDBService

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Watchlist destination")
            Text("Choose one of your PublicMetaDB lists to join your Plozz watchlist. This choice applies only to this profile on this device.")
                .foregroundStyle(.secondary)
            if let selection = service.watchlistSelection {
                Text(verbatim: selection.listName)
                Button("Stop syncing this list") { service.disableWatchlist() }
                    .accessibilityIdentifier("publicmetadb.watchlist.disable")
                Text("Stopping sync leaves existing records unchanged.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Not syncing a list")
            }
            NavigationLink("Choose a list") { PublicMetaDBWatchlistPicker(service: service) }
                .disabled(service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.watchlist.choose")
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
        Text("Your existing and future Plozz watchlist choices can add or remove movies and shows in “\(name)”. Its items appear in Plozz, and changes can propagate to your other enabled watchlist destinations. PublicMetaDB also undrops shows when added. Watched history and progress are not imported.")
        if isPublic {
            Text("This list is public. Other people can see its contents.")
        } else {
            Text("This list is currently private on PublicMetaDB.")
        }
    }
}
#endif
