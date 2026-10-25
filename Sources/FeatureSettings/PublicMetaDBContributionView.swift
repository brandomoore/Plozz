#if canImport(SwiftUI)
import CoreUI
import Observation
import PublicMetaDBService
import SwiftUI

@MainActor
@Observable
final class PublicMetaDBReadOperation<Value: Sendable> {
    private(set) var value: Value?
    private(set) var failure: (any Error)?
    private(set) var loading = false
    private(set) var connectionID: UUID?
    private var requestID = UUID()

    func load(
        service: PublicMetaDBService, operation: @MainActor (UUID) async throws -> Value
    ) async {
        let request = UUID()
        let connection = service.connectionID
        requestID = request
        connectionID = connection
        value = nil
        failure = nil
        loading = true
        defer { if requestID == request { loading = false } }
        do {
            guard let connection else { throw PublicMetaDB.Failure.disconnected }
            let result = try await operation(connection)
            try Task.checkCancellation()
            guard requestID == request, service.connectionID == connection else { return }
            value = result
        } catch {
            guard requestID == request, service.connectionID == connection else { return }
            failure = error
        }
    }
}

struct PublicMetaDBReadContent<Value: Sendable, Content: View>: View {
    let service: PublicMetaDBService
    let load: @MainActor (UUID) async throws -> Value
    @ViewBuilder let content: (Value) -> Content
    @State private var operation = PublicMetaDBReadOperation<Value>()
    @State private var reload = 0

    var body: some View {
        Group {
            if operation.loading { ProgressView() }
            if let failure = operation.failure { PublicMetaDBFailureMessage(error: failure) }
            if operation.connectionID == service.connectionID, let value = operation.value {
                content(value)
            }
            Button("Refresh") { reload += 1 }
                .disabled(operation.loading || service.phase != .connected)
        }
        .task(id: "\(service.connectionID?.uuidString ?? ""):\(reload)") {
            await operation.load(service: service, operation: load)
        }
    }
}

struct PublicMetaDBContentRatingsView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Community and personal ratings")
            PublicMetaDBContentLabel(content: content)
            Text("Ratings are public contributions. Contributor names do not establish which records belong to this API key.")
                .foregroundStyle(.secondary)
            NavigationLink("Submit a rating") { PublicMetaDBSubmitRatingView(service: service, content: content) }
            PublicMetaDBReadContent(service: service, load: {
                try await service.ratingsForManagement(content, expectedConnectionID: $0)
            }) { ratings in
                if ratings.items.isEmpty { Text("No ratings") }
                ForEach(ratings.items) { record in
                    NavigationLink {
                        PublicMetaDBRatingRecordView(service: service, record: record)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: record.value.label)
                            Text("\(record.value.score.formatted()) / 100")
                            if let contributor = record.contributor {
                                Text(verbatim: contributor).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PublicMetaDBSubmitRatingView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var label = "Overall"
    @State private var score = 50
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var failure: (any Error)?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let rating: PublicMetaDB.Rating
        let connection: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Submit a rating")
            PublicMetaDBContentLabel(content: content)
            if operation.succeeded {
                Text("Rating confirmed on PublicMetaDB")
            } else {
                TextField("Rating label", text: $label)
                    .accessibilityIdentifier("publicmetadb.rating.label")
                Picker("Score out of 100", selection: $score) {
                    ForEach(0...100, id: \.self) { value in Text(value, format: .number).tag(value) }
                }
                .accessibilityIdentifier("publicmetadb.rating.score")
                Text("The rating and your PublicMetaDB contributor name will be public. This does not change your media server's rating.")
                    .foregroundStyle(.secondary)
                Button("Submit rating") {
                    do {
                        guard let connection = service.connectionID else { throw PublicMetaDB.Failure.disconnected }
                        draft = Draft(
                            rating: try .init(
                                content: content, score: Double(score),
                                label: label.trimmingCharacters(in: .whitespacesAndNewlines)
                            ), connection: connection
                        )
                        failure = nil
                        confirming = true
                    } catch { failure = error }
                }
                .disabled(!operation.permitsWrite || service.phase != .connected
                          || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("publicmetadb.rating.submit")
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Publish this rating?", isPresented: $confirming, presenting: draft) { draft in
            Button("Publish rating") {
                operation.perform {
                    try await service.submitManagedRating(draft.rating, expectedConnectionID: draft.connection)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Publish “\(draft.rating.label)”: \(draft.rating.score.formatted()) / 100 on PublicMetaDB.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

private struct PublicMetaDBRatingRecordView: View {
    let service: PublicMetaDBService
    let record: PublicMetaDB.Record<PublicMetaDB.Rating>
    @State private var confirming = false
    @State private var connection: UUID?
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(verbatim: record.value.label)
            PublicMetaDBContentLabel(content: record.value.content)
            Text("\(record.value.score.formatted()) / 100")
            if let contributor = record.contributor { Text(verbatim: contributor) }
            if operation.succeeded {
                Text("Rating removed from PublicMetaDB")
            } else {
                NavigationLink("Vote on this contribution") {
                    PublicMetaDBVoteView(
                        service: service,
                        category: record.value.content.episode == nil ? .ratings : .episodeRatings,
                        recordID: record.id
                    )
                }
                Text("Only the author can delete a rating. PublicMetaDB verifies ownership using your API key.")
                    .foregroundStyle(.secondary)
                Button("Delete rating", role: .destructive) {
                    connection = service.connectionID
                    confirming = true
                }
                .disabled(!operation.permitsWrite || service.phase != .connected)
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete this rating?", isPresented: $confirming) {
            Button("Delete rating", role: .destructive) {
                guard let connection else { return }
                operation.perform { try await service.deleteManagedRating(record, expectedConnectionID: connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests deletion of this exact contribution. PublicMetaDB rejects the request if it is not yours. Server ratings and watched history are unchanged.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBVoteView: View {
    let service: PublicMetaDBService
    let category: PublicMetaDB.Contribution
    let recordID: String
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let vote: PublicMetaDB.Vote?
        let observed: PublicMetaDB.Vote?
        let connection: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Vote on this contribution")
            if operation.succeeded {
                Text("Your vote was confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, load: {
                    try await service.contributionVotes(category, recordID: recordID, expectedConnectionID: $0)
                }) { votes in
                    Text("\(votes.summary.upvotes) upvotes, \(votes.summary.downvotes) downvotes")
                    LabeledContent("Your vote") { voteLabel(votes.userVote) }
                    ForEach(PublicMetaDB.Vote.allCases, id: \.self) { vote in
                        Button { prepare(vote, observed: votes.userVote) } label: { voteLabel(vote) }
                            .disabled(!operation.permitsWrite || vote == votes.userVote)
                    }
                    Button("Remove my vote", role: .destructive) { prepare(nil, observed: votes.userVote) }
                        .disabled(!operation.permitsWrite || votes.userVote == nil)
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Change your PublicMetaDB vote?", isPresented: $confirming, presenting: draft) { draft in
            Button("Confirm vote") {
                operation.perform {
                    try await service.changeContributionVote(
                        draft.vote, category: category, recordID: recordID, observedVote: draft.observed,
                        expectedConnectionID: draft.connection
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            voteLabel(draft.vote)
            Text("This affects only your vote on this community contribution.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }

    private func prepare(_ vote: PublicMetaDB.Vote?, observed: PublicMetaDB.Vote?) {
        guard let connection = service.connectionID else { return }
        draft = Draft(vote: vote, observed: observed, connection: connection)
        confirming = true
    }

    @ViewBuilder private func voteLabel(_ vote: PublicMetaDB.Vote?) -> some View {
        switch vote {
        case .up: Text("Upvote")
        case .down: Text("Downvote")
        case .neutral: Text("Neutral")
        case nil: Text("No vote")
        }
    }
}
#endif
