#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBSeasonRatingsView: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    @State private var seasonText: String
    @State private var selectedSeason: Int?

    init(service: PublicMetaDBService, tmdbID: Int, initialSeason: Int?) {
        self.service = service
        self.tmdbID = tmdbID
        _seasonText = State(initialValue: initialSeason.map(String.init) ?? "")
        _selectedSeason = State(initialValue: initialSeason)
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Season ratings")
            TextField("TMDB season number", text: $seasonText)
            Text("Use TMDB numbering, which may differ from your server. Season 0 contains specials.")
                .foregroundStyle(.secondary)
            Button("Load season") { selectedSeason = Int(seasonText) }
                .disabled(Int(seasonText).map { $0 < 0 } ?? true)
            if let season = selectedSeason {
                NavigationLink("Rate multiple episodes") {
                    PublicMetaDBEpisodeRatingsEditor(service: service, tmdbID: tmdbID, season: season)
                }
                NavigationLink("Delete selected episode ratings") {
                    PublicMetaDBEpisodeRatingsDeletionView(service: service, tmdbID: tmdbID, season: season)
                }
                PublicMetaDBReadContent(service: service, load: {
                    try await service.seasonRatingsForManagement(tmdbID: tmdbID, season: season, expectedConnectionID: $0)
                }) { result in
                    if result.episodes.isEmpty { Text("No episode ratings") }
                    Text("Episodes shown have community ratings; this is not a complete episode list.")
                        .foregroundStyle(.secondary)
                    ForEach(result.episodes.sorted(by: { $0.episode < $1.episode }), id: \.episode) { episode in
                        if let identity = try? PublicMetaDB.Content(tmdbID: tmdbID, mediaType: .tv, season: season, episode: episode.episode) {
                            NavigationLink {
                                PublicMetaDBContentRatingsView(service: service, content: identity)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text("Episode \(episode.episode)")
                                    ForEach(episode.aggregates.keys.sorted(), id: \.self) { key in
                                        if let score = episode.aggregates[key] {
                                            Text("\(score.label): \(score.average.formatted()) / 100 (\(score.count) ratings)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .id(season)
            }
        }
    }
}

struct PublicMetaDBEpisodeRatingDraft: Identifiable {
    let id = UUID()
    var episode = ""
    var score = 50

    static func inputs(_ drafts: [Self]) throws -> [PublicMetaDB.EpisodeRatingInput] {
        guard (1...50).contains(drafts.count) else { throw PublicMetaDB.Failure.invalidInput }
        let result = try drafts.map { draft in
            guard let episode = Int(draft.episode.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw PublicMetaDB.Failure.invalidInput
            }
            return try PublicMetaDB.EpisodeRatingInput(episode: episode, score: Double(draft.score))
        }
        guard Set(result.map(\.episode)).count == result.count else { throw PublicMetaDB.Failure.invalidInput }
        return result
    }
}

private struct PublicMetaDBEpisodeRatingsEditor: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    let season: Int
    @State private var label = "Overall"
    @State private var entries = [PublicMetaDBEpisodeRatingDraft()]
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var failure: (any Error)?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let ratings: [PublicMetaDB.EpisodeRatingInput]
        let label: String
        let connection: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Rate multiple episodes")
            Text("Season \(season)")
            if operation.succeeded {
                Text("All selected episode ratings were confirmed on PublicMetaDB")
            } else {
                TextField("Rating label", text: $label)
                ForEach($entries) { $entry in
                    Section {
                        TextField("TMDB episode number", text: $entry.episode)
                        Picker("Score out of 100", selection: $entry.score) {
                            ForEach(0...100, id: \.self) { score in Text(score, format: .number).tag(score) }
                        }
                        Button("Remove row", role: .destructive) { entries.removeAll { $0.id == entry.id } }
                    }
                }
                .disabled(!operation.permitsWrite)
                Button("Add an episode") { entries.append(.init()) }
                    .disabled(!operation.permitsWrite || entries.count >= 50)
                Text("Up to 50 episodes per request. Use TMDB numbering, not a different server order. Ratings and your contributor name will be public.")
                    .foregroundStyle(.secondary)
                Button("Review ratings") {
                    do {
                        guard let connection = service.connectionID else { throw PublicMetaDB.Failure.disconnected }
                        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !label.isEmpty else { throw PublicMetaDB.Failure.invalidInput }
                        draft = Draft(ratings: try PublicMetaDBEpisodeRatingDraft.inputs(entries), label: label, connection: connection)
                        failure = nil
                        confirming = true
                    } catch { failure = error }
                }
                .disabled(!operation.permitsWrite || service.phase != .connected)
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Publish these episode ratings?", isPresented: $confirming, presenting: draft) { draft in
            Button("Publish ratings") {
                operation.perform {
                    try await service.submitManagedEpisodeRatings(
                        tmdbID: tmdbID, season: season, label: draft.label,
                        ratings: draft.ratings, expectedConnectionID: draft.connection
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Publish \(draft.ratings.count) “\(draft.label)” ratings for TMDB season \(season). A partial result is not a full success and will not be automatically retried.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

private struct PublicMetaDBEpisodeRatingsDeletionView: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    let season: Int
    @State private var selected: [String: PublicMetaDB.Record<PublicMetaDB.Rating>] = [:]
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let records: [PublicMetaDB.Record<PublicMetaDB.Rating>]
        let connection: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Delete selected episode ratings")
            Text("Select up to 50 exact contributions. PublicMetaDB permits deletion only of your own records; contributor names do not prove ownership.")
                .foregroundStyle(.secondary)
            if operation.succeeded {
                Text("All selected ratings were confirmed removed")
            } else {
                PublicMetaDBReadContent(service: service, load: {
                    selected.removeAll()
                    return try await service.seasonRatingsForManagement(tmdbID: tmdbID, season: season, expectedConnectionID: $0)
                }) { result in
                    ForEach(result.episodes.flatMap(\.ratings)) { record in
                        Toggle(isOn: Binding(
                            get: { selected[record.id] != nil },
                            set: { if $0 { selected[record.id] = record } else { selected[record.id] = nil } }
                        )) {
                            VStack(alignment: .leading) {
                                PublicMetaDBContentLabel(content: record.value.content, allowsFocus: false)
                                Text("\(record.value.label): \(record.value.score.formatted()) / 100")
                                if let contributor = record.contributor { Text(verbatim: contributor) }
                            }
                        }
                        .disabled(!operation.permitsWrite || (selected.count >= 50 && selected[record.id] == nil))
                    }
                }
                Button("Delete selected ratings", role: .destructive) {
                    guard let connection = service.connectionID else { return }
                    draft = Draft(records: selected.values.sorted { $0.id < $1.id }, connection: connection)
                    confirming = true
                }
                .disabled(selected.isEmpty || !operation.permitsWrite || service.phase != .connected)
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete these exact ratings?", isPresented: $confirming, presenting: draft) { draft in
            Button("Delete selected ratings", role: .destructive) {
                operation.perform { try await service.deleteManagedEpisodeRatings(draft.records, expectedConnectionID: draft.connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Requests removal of \(draft.records.count) exact contributions, not all ratings for the season. PublicMetaDB verifies ownership. Server ratings and history are unchanged.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            selected.removeAll()
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}
#endif
