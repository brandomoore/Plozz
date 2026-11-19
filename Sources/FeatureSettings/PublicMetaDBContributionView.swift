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
    private(set) var selectionID: AnyHashable?
    private(set) var revision = 0
    private var requestID = UUID()

    func refresh() { revision += 1 }

    func reset() {
        requestID = UUID()
        connectionID = nil
        selectionID = nil
        value = nil
        failure = nil
        loading = false
    }

    func load(
        service: PublicMetaDBService, id: AnyHashable = 0, operation: @MainActor (UUID) async throws -> Value
    ) async {
        let request = UUID()
        let connection = service.connectionID
        requestID = request
        connectionID = connection
        selectionID = id
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

private struct PublicMetaDBReadRequest<ID: Hashable>: Hashable {
    let connection: UUID?
    let selection: ID
    let enabled: Bool
    let revision: Int
}

extension View {
    // Apply to the page, not its lazy rows: row appearance must never restart a read.
    func publicMetaDBRead<Value: Sendable, ID: Hashable>(
        _ operation: PublicMetaDBReadOperation<Value>, service: PublicMetaDBService,
        id: ID = 0, enabled: Bool = true,
        load: @escaping @MainActor (UUID) async throws -> Value
    ) -> some View {
        modifier(PublicMetaDBReadModifier(operation: operation, service: service, id: id, enabled: enabled, load: load))
    }
}

private struct PublicMetaDBReadModifier<Value: Sendable, ID: Hashable>: ViewModifier {
    let operation: PublicMetaDBReadOperation<Value>
    let service: PublicMetaDBService
    let id: ID
    let enabled: Bool
    let load: @MainActor (UUID) async throws -> Value

    func body(content: Content) -> some View {
        content.task(id: PublicMetaDBReadRequest(
            connection: service.connectionID, selection: id, enabled: enabled, revision: operation.revision
        )) {
            if enabled { await operation.load(service: service, id: id, operation: load) }
            else { operation.reset() }
        }
    }
}

struct PublicMetaDBReadContent<Value: Sendable, Content: View>: View {
    let service: PublicMetaDBService
    let operation: PublicMetaDBReadOperation<Value>
    var id: AnyHashable = 0
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        Group {
            if operation.loading { ProgressView() }
            if let failure = operation.failure { PublicMetaDBFailureMessage(error: failure) }
            if operation.connectionID == service.connectionID, operation.selectionID == id, let value = operation.value {
                content(value)
            }
            SettingsSectionGroup {
                Button("Refresh") { operation.refresh() }
                    .settingsActionRow()
                    .disabled(operation.loading || service.phase != .connected)
            }
        }
    }
}

struct PublicMetaDBContentRatingsView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var ratings = PublicMetaDBReadOperation<PublicMetaDB.Ratings>()

    var body: some View {
        GroupedSettingsPage(title: "Community and personal ratings", backIdentifier: "publicmetadb.ratings.back") {
            PublicMetaDBContentLabel(content: content)
            SettingsSectionGroup {
                PublicMetaDBDetailLink("Submit a rating") { PublicMetaDBSubmitRatingView(service: service, content: content) }
            }
            PublicMetaDBReadContent(service: service, operation: ratings, id: content) { ratings in
                SettingsSectionGroup {
                    if ratings.isComplete && ratings.items.isEmpty { Text("No ratings") }
                    ForEach(ratings.items) { record in
                        NavigationLink {
                            PublicMetaDBRatingRecordView(service: service, record: record)
                        } label: {
                            SettingsDisclosureLabel {
                                VStack(alignment: .leading) {
                                    Text(verbatim: record.value.label)
                                    if let contributor = record.contributor {
                                        Text(verbatim: contributor).font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
                                    }
                                }
                            } value: {
                                Text("\(record.value.score.formatted()) / 100")
                            }
                        }
                        .settingsActionRow()
                        .accessibilityIdentifier("publicmetadb.rating.record.\(record.id)")
                    }
                } footer: {
                    if !ratings.isComplete {
                        Text("Showing \(ratings.items.count) of \(ratings.total) ratings. Changes require a complete result.")
                    }
                }
            }
        }
        .publicMetaDBRead(ratings, service: service, id: content) {
            try await service.ratingsForBrowsing(content, expectedConnectionID: $0)
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
        GroupedSettingsPage(title: "Submit a rating", backIdentifier: "publicmetadb.rating.submit.back") {
            PublicMetaDBContentLabel(content: content)
            if operation.succeeded {
                Text("Rating confirmed on PublicMetaDB")
            } else {
                SettingsSectionGroup {
                    SettingsInputRow("Rating label", axis: .horizontal) {
                        TextField("Overall", text: $label)
                            .accessibilityIdentifier("publicmetadb.rating.label")
                    }
                    Picker("Score out of 100", selection: $score) {
                        ForEach(0...100, id: \.self) { value in Text(value, format: .number).tag(value) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Score out of 100")
                    .accessibilityValue(Text(score, format: .number))
                    .accessibilityIdentifier("publicmetadb.rating.score")
                } footer: {
                    Text("Your score and contributor name will be public. Your server rating stays the same.")
                }
                SettingsSectionGroup {
                    Button("Submit rating") {
                        do {
                            guard let connection = service.connectionID else { throw PublicMetaDB.Failure.disconnected }
                            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            try PublicMetaDB.Rating.validateSubmissionLabel(label)
                            draft = Draft(
                                rating: try .init(
                                    content: content, score: Double(score),
                                    label: label
                                ), connection: connection
                            )
                            failure = nil
                            confirming = true
                        } catch { failure = error }
                    }
                    .settingsActionRow()
                    .disabled(!operation.permitsWrite || service.phase != .connected
                              || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("publicmetadb.rating.submit")
                }
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
        GroupedSettingsPage(title: "\(record.value.label)", backIdentifier: "publicmetadb.rating.record.back") {
            PublicMetaDBContentLabel(content: record.value.content)
            SettingsSectionGroup {
                LabeledContent("Score") { Text("\(record.value.score.formatted()) / 100") }
                if let contributor = record.contributor {
                    LabeledContent("Contributor") { Text(verbatim: contributor) }
                }
            }
            if operation.succeeded {
                Text("Rating removed from PublicMetaDB")
            } else {
                SettingsSectionGroup {
                    PublicMetaDBDetailLink("Vote on this contribution") {
                        PublicMetaDBVoteView(
                            service: service,
                            category: record.value.content.episode == nil ? .ratings : .episodeRatings,
                            recordID: record.id
                        )
                    }
                    Button("Delete rating", role: .destructive) {
                        connection = service.connectionID
                        confirming = true
                    }
                    .settingsActionRow()
                    .disabled(!operation.permitsWrite || service.phase != .connected)
                } footer: {
                    Text("You can delete only your own ratings.")
                }
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

struct PublicMetaDBContributionRecordView<Detail: View>: View {
    let service: PublicMetaDBService
    let category: PublicMetaDB.Contribution
    let recordID: String
    let delete: @MainActor (UUID) async throws -> Void
    @ViewBuilder let detail: () -> Detail
    @State private var operation = PublicMetaDBMutationOperation()
    @State private var confirming = false
    @State private var connection: UUID?

    var body: some View {
        GroupedSettingsPage(title: "Community contribution", backIdentifier: "publicmetadb.contribution.back") {
            SettingsSectionGroup { detail() }
            if operation.succeeded {
                Text("Contribution removed from PublicMetaDB")
            } else {
                SettingsSectionGroup {
                    PublicMetaDBDetailLink("Vote on this contribution") {
                        PublicMetaDBVoteView(service: service, category: category, recordID: recordID)
                    }
                    Button("Delete contribution", role: .destructive) {
                        connection = service.connectionID
                        confirming = true
                    }
                    .settingsActionRow()
                    .disabled(!operation.permitsWrite || service.phase != .connected)
                } footer: {
                    Text("You can delete only your own contributions.")
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete this contribution?", isPresented: $confirming) {
            Button("Delete contribution", role: .destructive) {
                guard let connection else { return }
                operation.perform { try await delete(connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if category == .animeSeasons {
                Text("Deletes only this chunk of your public mapping, not the whole logical season. Other contributors’ mappings and server episode numbering stay unchanged.")
            } else {
                Text("Deletes only this external ID contribution if it belongs to you. Other mappings and server IDs stay unchanged.")
            }
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
    @State private var votes = PublicMetaDBReadOperation<PublicMetaDB.Votes>()

    private struct Draft {
        let vote: PublicMetaDB.Vote?
        let observed: PublicMetaDB.Vote?
        let connection: UUID
    }

    var body: some View {
        GroupedSettingsPage(title: "Vote on this contribution", backIdentifier: "publicmetadb.vote.back") {
            if operation.succeeded {
                Text("Your vote was confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, operation: votes) { votes in
                    SettingsSectionGroup {
                        Text("\(votes.summary.upvotes) upvotes, \(votes.summary.downvotes) downvotes")
                        LabeledContent("Your vote") { voteLabel(votes.userVote) }
                    }
                    SettingsSectionGroup {
                        ForEach(PublicMetaDB.Vote.allCases, id: \.self) { vote in
                            Button { prepare(vote, observed: votes.userVote) } label: { voteLabel(vote) }
                                .settingsActionRow()
                                .disabled(!operation.permitsWrite || vote == votes.userVote)
                        }
                        Button("Remove my vote", role: .destructive) { prepare(nil, observed: votes.userVote) }
                            .settingsActionRow()
                            .disabled(!operation.permitsWrite || votes.userVote == nil)
                    }
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .publicMetaDBRead(votes, service: service, enabled: !operation.succeeded) {
            try await service.contributionVotes(category, recordID: recordID, expectedConnectionID: $0)
        }
        .confirmationDialog("Change your PublicMetaDB vote?", isPresented: $confirming, presenting: draft) { draft in
            Button("Confirm vote", role: draft.vote == nil ? .destructive : nil) {
                operation.perform {
                    try await service.changeContributionVote(
                        draft.vote, category: category, recordID: recordID, observedVote: draft.observed,
                        expectedConnectionID: draft.connection
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            publicMetaDBConfirmationMessage(
                voteLabel(draft.vote), Text("This affects only your vote on this community contribution.")
            )
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

    private func voteLabel(_ vote: PublicMetaDB.Vote?) -> Text {
        switch vote {
        case .up: Text("Upvote")
        case .down: Text("Downvote")
        case .neutral: Text("Neutral")
        case nil: Text("No vote")
        }
    }
}
#endif
