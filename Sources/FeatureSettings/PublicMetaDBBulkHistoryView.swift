#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBBulkHistoryView: View {
    let service: PublicMetaDBService
    @State private var page = 1
    @State private var result: PublicMetaDB.Page<PublicMetaDB.Record<PublicMetaDB.Watch>>?
    @State private var selectedIDs: Set<String> = []
    @State private var failure: (any Error)?
    @State private var loading = false
    @State private var reload = 0
    @State private var requestID = UUID()
    @State private var loadedConnection: UUID?
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let connectionID: UUID
        let records: [PublicMetaDB.Record<PublicMetaDB.Watch>]
    }

    private struct Request: Hashable {
        let connection: UUID?
        let page: Int
        let reload: Int
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Delete multiple plays")
            Text("Select up to 50 plays on this page. Plozz removes only those records on PublicMetaDB, not media-server history or newer plays.")
                .foregroundStyle(.secondary)
            if loading { ProgressView() }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            if operation.succeeded { Text("Selected plays confirmed removed on PublicMetaDB") }
            if let result, loadedConnection == service.connectionID {
                if result.items.isEmpty { Text("No records") }
                PublicMetaDBHistorySelectionRows(records: result.items, selectedIDs: $selectedIDs)
                    .disabled(loading || !operation.permitsWrite)
                Text("Page \(result.page) of \(max(1, result.totalPages))")
                    .foregroundStyle(.secondary)
                HStack {
                    if page > 1 { Button("Previous page") { page -= 1 } }
                    if page < result.totalPages { Button("Next page") { page += 1 } }
                }
                .disabled(loading || operation.running || !selectedIDs.isEmpty)
                Button("Review deletion") {
                    guard let connection = loadedConnection, connection == service.connectionID else { return }
                    draft = Draft(connectionID: connection, records: result.items.filter { selectedIDs.contains($0.id) })
                    confirming = true
                }
                .disabled(loading || !operation.permitsWrite || selectedIDs.isEmpty || service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.history.bulk.review")
            }
            PublicMetaDBMutationStatus(operation: operation)
            Button("Refresh history") { reload += 1 }
                .disabled(loading || operation.running || service.phase != .connected)
        }
        .confirmationDialog("Delete the selected PublicMetaDB plays?", isPresented: $confirming, presenting: draft) { draft in
            Button("Delete \(draft.records.count) plays", role: .destructive) {
                operation.perform {
                    try await service.deleteHistoryPlays(draft.records, expectedConnectionID: draft.connectionID)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Only these \(draft.records.count) selected records will be removed. This cannot be undone by Plozz.")
            Text("Other apps connected to PublicMetaDB may also react to this change.")
        }
        .task(id: Request(connection: service.connectionID, page: page, reload: reload)) {
            let request = UUID()
            let connection = service.connectionID
            requestID = request
            result = nil
            loadedConnection = nil
            selectedIDs = []
            failure = nil
            operation = PublicMetaDBMutationOperation()
            loading = true
            defer { if requestID == request { loading = false } }
            do {
                guard let client = service.client else { throw PublicMetaDB.Failure.disconnected }
                let response = try await client.history(page: page, perPage: 50)
                try Task.checkCancellation()
                guard Set(response.items.map(\.id)).count == response.items.count else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
                guard requestID == request, connection == service.connectionID else { return }
                result = response
                loadedConnection = connection
            } catch {
                if !Task.isCancelled, requestID == request { failure = error }
            }
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
            page = 1
        }
        .onDisappear { operation.cancel() }
    }
}

private struct PublicMetaDBHistorySelectionRows: View {
    let records: [PublicMetaDB.Record<PublicMetaDB.Watch>]
    @Binding var selectedIDs: Set<String>

    var body: some View {
        ForEach(records) { record in
            Toggle(isOn: Binding(
                get: { selectedIDs.contains(record.id) },
                set: { selected in
                    if selected { selectedIDs.insert(record.id) } else { selectedIDs.remove(record.id) }
                }
            )) {
                VStack(alignment: .leading) {
                    PublicMetaDBContentLabel(content: record.value.content, allowsFocus: false)
                    PublicMetaDBWatchDateLabel(date: record.value.watchedAt)
                }
            }
            .accessibilityIdentifier("publicmetadb.history.select.\(record.id)")
        }
    }
}
#endif
