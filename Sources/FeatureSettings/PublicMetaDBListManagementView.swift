#if canImport(SwiftUI)
import CoreUI
import Observation
import PublicMetaDBService
import SwiftUI

@MainActor
@Observable
final class PublicMetaDBMutationOperation {
    private(set) var running = false
    private(set) var succeeded = false
    private(set) var failure: (any Error)?
    private var task: Task<Void, Never>?
    var permitsWrite: Bool {
        !running && !succeeded && (failure as? PublicMetaDB.Failure) != .uncertainWrite
            && !(failure is PublicMetaDB.HistoryDeletionFailure)
            && !(failure is PublicMetaDB.RatingBatchFailure)
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard permitsWrite else { return }
        running = true
        failure = nil
        task = Task {
            defer { running = false }
            do {
                try Task.checkCancellation()
                try await operation()
                try Task.checkCancellation()
                succeeded = true
            } catch {
                failure = error
            }
        }
    }

    func cancel() { task?.cancel() }
}

struct PublicMetaDBMutationStatus: View {
    let operation: PublicMetaDBMutationOperation
    var body: some View {
        if operation.running { ProgressView() }
        if let failure = operation.failure { PublicMetaDBFailureMessage(error: failure) }
    }
}

struct PublicMetaDBCreateListView: View {
    let service: PublicMetaDBService
    @State private var name = ""
    @State private var description = ""
    @State private var isPublic = false
    @State private var kind: PublicMetaDB.ListKind = .custom
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let name: String
        let description: String?
        let isPublic: Bool
        let kind: PublicMetaDB.ListKind
        let connectionID: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Create a list")
            if operation.succeeded {
                Text("List created on PublicMetaDB")
            } else {
                TextField("List name", text: $name)
                    .accessibilityIdentifier("publicmetadb.list.name")
                TextField("Description (optional)", text: $description)
                Toggle("Public list", isOn: $isPublic)
                Picker("List type", selection: $kind) {
                    Text("Custom list").tag(PublicMetaDB.ListKind.custom)
                    Text("Watchlist").tag(PublicMetaDB.ListKind.watchlist)
                }
                Text("Creating a list does not select it as a Plozz watchlist destination.")
                    .foregroundStyle(.secondary)
                Button("Create list") {
                    guard let connection = service.connectionID else { return }
                    let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft = Draft(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        description: detail.isEmpty ? nil : detail, isPublic: isPublic,
                        kind: kind, connectionID: connection
                    )
                    confirming = true
                }
                .disabled(!operation.permitsWrite || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.list.create")
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Create this PublicMetaDB list?", isPresented: $confirming, presenting: draft) { draft in
            Button("Create list") {
                operation.perform {
                    _ = try await service.createOwnedList(
                        name: draft.name, description: draft.description, isPublic: draft.isPublic,
                        type: draft.kind, expectedConnectionID: draft.connectionID
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            if draft.isPublic {
                Text("“\(draft.name)” will be public. Other people can see the list and items you add.")
            } else {
                Text("“\(draft.name)” will be private on PublicMetaDB.")
            }
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBOwnedListView: View {
    let service: PublicMetaDBService
    let list: PublicMetaDB.List
    @State private var confirming = false
    @State private var connection: UUID?
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(verbatim: list.name)
            Text(list.isPublic ? "Public" : "Private").foregroundStyle(.secondary)
            if let description = list.description { Text(verbatim: description) }
            if operation.succeeded {
                Text("List deleted from PublicMetaDB")
            } else {
                NavigationLink("Browse items") {
                    PublicMetaDBPagedRecords(
                        service: service, title: "List items",
                        load: { try await $0.listItems(id: list.id, page: $1).page }
                    ) { record in
                        NavigationLink {
                            PublicMetaDBListItemActionsView(service: service, list: list, record: record)
                        } label: {
                            PublicMetaDBContentLabel(content: record.value, allowsFocus: false)
                        }
                    }
                }
                Button("Delete list", role: .destructive) {
                    connection = service.connectionID
                    confirming = true
                }
                .disabled(!operation.permitsWrite || service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.list.delete")
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete this PublicMetaDB list?", isPresented: $confirming) {
            Button("Delete list", role: .destructive) {
                guard let connection else { return }
                operation.perform { try await service.deleteOwnedList(list, expectedConnectionID: connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes “\(list.name)” and its list entries on PublicMetaDB. If selected as a Plozz watchlist destination, syncing stops. Watched history and server files are not deleted.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

private struct PublicMetaDBListItemActionsView: View {
    let service: PublicMetaDBService
    let list: PublicMetaDB.List
    let record: PublicMetaDB.Record<PublicMetaDB.Content>
    @State private var confirming = false
    @State private var connection: UUID?
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("List item")
            PublicMetaDBContentLabel(content: record.value)
            NavigationLink("Title controls") { PublicMetaDBContentView(service: service, content: record.value) }
            if operation.succeeded {
                Text("Item removed from this list")
            } else {
                Button("Remove from list", role: .destructive) {
                    connection = service.connectionID
                    confirming = true
                }
                .disabled(!operation.permitsWrite || service.phase != .connected)
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Remove this item?", isPresented: $confirming) {
            Button("Remove from list", role: .destructive) {
                guard let connection else { return }
                operation.perform {
                    try await service.removeFromOwnedList(record, list: list, expectedConnectionID: connection)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes this entry from “\(list.name)”. If this list is a watchlist destination, the change can propagate to other enabled destinations. It does not delete watched history or server files.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBAddToListView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var choice: PublicMetaDB.List?
    @State private var connection: UUID?
    @State private var confirming = false
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPagedRecords(
            service: service, title: "Add to a list", load: { try await $0.lists(page: $1) }
        ) { list in
            Button {
                choice = list
                connection = service.connectionID
                confirming = true
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: list.name)
                    Text(list.isPublic ? "Public" : "Private").foregroundStyle(.secondary)
                }
            }
            .disabled(!operation.permitsWrite)
        }
        .confirmationDialog("Add to this list?", isPresented: $confirming, presenting: choice) { list in
            Button("Add to list") {
                guard let connection else { return }
                operation.perform {
                    try await service.addToOwnedList(content, list: list, expectedConnectionID: connection)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { list in
            Text("Adds this title to “\(list.name)”. PublicMetaDB also undrops shows when added. Changes to a watchlist destination can propagate to other enabled destinations.")
            if list.isPublic { Text("This list is public. Other people can see its contents.") }
        }
        .alert("PublicMetaDB", isPresented: Binding(
            get: { operation.succeeded || operation.failure != nil },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) { dismiss() }
        } message: {
            if operation.succeeded { Text("Added to list") }
            else if let failure = operation.failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            choice = nil
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }

    @Environment(\.dismiss) private var dismiss
}

struct PublicMetaDBOpenListView: View {
    let service: PublicMetaDBService
    @State private var url = ""
    @State private var address: PublicMetaDB.ListAddress?
    @State private var showing = false
    @State private var failure: (any Error)?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Open a public list")
            TextField("PublicMetaDB list URL", text: $url)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Open list") {
                do {
                    guard let link = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw PublicMetaDB.Failure.invalidInput
                    }
                    address = try PublicMetaDB.ListAddress(url: link)
                    failure = nil
                    showing = true
                } catch { failure = error }
            }
            .disabled(service.phase != .connected)
            if let failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .navigationDestination(isPresented: $showing) {
            if let address {
                PublicMetaDBPagedRecords(
                    service: service, title: "Public list",
                    load: { try await $0.listItems(address: address, page: $1).page }
                ) { record in
                    PublicMetaDBContentLabel(content: record.value)
                }
            }
        }
        .onChange(of: service.connectionID) { _, _ in
            showing = false
            address = nil
        }
    }
}
#endif
