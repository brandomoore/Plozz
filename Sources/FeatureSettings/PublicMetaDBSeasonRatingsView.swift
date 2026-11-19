#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBSeasonRatingsView: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    @State private var seasonText: String
    @State private var selectedSeason: Int?
    @State private var ratings = PublicMetaDBReadOperation<PublicMetaDB.SeasonRatings>()

    init(service: PublicMetaDBService, tmdbID: Int, initialSeason: Int?) {
        self.service = service
        self.tmdbID = tmdbID
        _seasonText = State(initialValue: initialSeason.map(String.init) ?? "")
        _selectedSeason = State(initialValue: initialSeason)
    }

    var body: some View {
        GroupedSettingsPage(title: "Season ratings", backIdentifier: "publicmetadb.season.back") {
            SettingsSectionGroup {
                SettingsInputRow("TMDB season number", axis: .horizontal) {
                    TextField("Season", text: $seasonText)
                }
                Button("Load season") { selectedSeason = Int(seasonText) }
                    .settingsActionRow()
                    .disabled(Int(seasonText).map { $0 < 0 } ?? true)
            } footer: {
                Text("Use TMDB numbering; season 0 is for specials.")
            }
            if let season = selectedSeason {
                SettingsSectionGroup("Season \(season)") {
                    PublicMetaDBDetailLink("Rate multiple episodes") {
                        PublicMetaDBEpisodeRatingsEditor(service: service, tmdbID: tmdbID, season: season)
                    }
                    PublicMetaDBDetailLink("Delete selected episode ratings") {
                        PublicMetaDBEpisodeRatingsDeletionView(service: service, tmdbID: tmdbID, season: season)
                    }
                }
                PublicMetaDBReadContent(service: service, operation: ratings, id: selectedSeason) { result in
                    SettingsSectionGroup("Rated episodes") {
                        if result.episodes.isEmpty { Text("No episode ratings") }
                        ForEach(result.episodes.sorted(by: { $0.episode < $1.episode }), id: \.episode) { episode in
                            if let identity = try? PublicMetaDB.Content(tmdbID: tmdbID, mediaType: .tv, season: season, episode: episode.episode) {
                                NavigationLink {
                                    PublicMetaDBContentRatingsView(service: service, content: identity)
                                } label: {
                                    SettingsDisclosureLabel {
                                        VStack(alignment: .leading) {
                                            Text("Episode \(episode.episode)")
                                            ForEach(episode.aggregates.keys.sorted(), id: \.self) { key in
                                                if let score = episode.aggregates[key] {
                                                    Text("\(score.label): \(score.average.formatted()) / 100 (\(score.count) ratings)")
                                                        .font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
                                                }
                                            }
                                        }
                                    }
                                }
                                .settingsActionRow()
                            }
                        }
                    }
                }
                .id(season)
            }
        }
        .publicMetaDBRead(ratings, service: service, id: selectedSeason, enabled: selectedSeason != nil) { connection in
            guard let selectedSeason else { throw PublicMetaDB.Failure.invalidInput }
            return try await service.seasonRatingsForManagement(
                tmdbID: tmdbID, season: selectedSeason, expectedConnectionID: connection
            )
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
        GroupedSettingsPage(title: "Rate multiple episodes", backIdentifier: "publicmetadb.episode-rating.edit.back") {
            if operation.succeeded {
                Text("All selected episode ratings were confirmed on PublicMetaDB")
            } else {
                SettingsSectionGroup("Season \(season)") {
                    SettingsInputRow("Rating label", axis: .horizontal) {
                        TextField("Overall", text: $label)
                    }
                }
                ForEach($entries) { $entry in
                    SettingsSectionGroup {
                        SettingsInputRow("TMDB episode number", axis: .horizontal) {
                            TextField("Episode", text: $entry.episode)
                        }
                        Picker("Score out of 100", selection: $entry.score) {
                            ForEach(0...100, id: \.self) { score in Text(score, format: .number).tag(score) }
                        }
                        .pickerStyle(.menu)
                        .accessibilityLabel("Score out of 100")
                        .accessibilityValue(Text(entry.score, format: .number))
                        .accessibilityIdentifier("publicmetadb.episode-rating.score.\(entry.id)")
                        Button("Remove row", role: .destructive) { entries.removeAll { $0.id == entry.id } }
                            .settingsActionRow()
                    }
                }
                .disabled(!operation.permitsWrite)
                SettingsSectionGroup {
                    Button("Add an episode") { entries.append(.init()) }
                        .settingsActionRow()
                        .disabled(!operation.permitsWrite || entries.count >= 50)
                    Button("Review ratings") {
                        do {
                            guard let connection = service.connectionID else { throw PublicMetaDB.Failure.disconnected }
                            let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                            try PublicMetaDB.Rating.validateSubmissionLabel(label)
                            draft = Draft(ratings: try PublicMetaDBEpisodeRatingDraft.inputs(entries), label: label, connection: connection)
                            failure = nil
                            confirming = true
                        } catch { failure = error }
                    }
                    .settingsActionRow()
                    .disabled(!operation.permitsWrite || service.phase != .connected)
                } footer: {
                    Text("Publish up to 50 episode ratings under your contributor name.")
                }
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
            Text("Your name and \(draft.ratings.count) “\(draft.label)” ratings for TMDB season \(season) will be public. Unconfirmed ratings won’t be retried automatically.")
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
    @State private var ratings = PublicMetaDBReadOperation<PublicMetaDB.SeasonRatings>()

    private struct Draft {
        let records: [PublicMetaDB.Record<PublicMetaDB.Rating>]
        let connection: UUID
    }

    var body: some View {
        GroupedSettingsPage(title: "Delete selected episode ratings", backIdentifier: "publicmetadb.episode-rating.delete.back") {
            if operation.succeeded {
                Text("All selected ratings were confirmed removed")
            } else {
                PublicMetaDBReadContent(service: service, operation: ratings) { result in
                    SettingsSectionGroup("Season \(season)") {
                        let records = result.episodes.flatMap(\.ratings)
                        if records.isEmpty {
                            Text("No episode ratings")
                        } else {
                            PublicMetaDBCatalogRows {
                                ForEach(records) { record in
                                    Toggle(isOn: Binding(
                                        get: { selected[record.id] != nil },
                                        set: { if $0 { selected[record.id] = record } else { selected[record.id] = nil } }
                                    )) {
                                        VStack(alignment: .leading) {
                                            PublicMetaDBContentLabel(content: record.value.content, allowsFocus: false)
                                            Text("\(record.value.label): \(record.value.score.formatted()) / 100")
                                            if let contributor = record.contributor {
                                                Text(verbatim: contributor).font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
                                            }
                                        }
                                    }
                                    .accessibilityIdentifier("publicmetadb.episode-rating.record.\(record.id)")
                                    .disabled(!operation.permitsWrite || (selected.count >= 50 && selected[record.id] == nil))
                                }
                            }
                        }
                    } footer: {
                        Text("Select up to 50 of your own ratings. PublicMetaDB checks ownership.")
                    }
                }
                SettingsSectionGroup {
                    Button("Delete selected ratings", role: .destructive) {
                        guard let connection = service.connectionID else { return }
                        draft = Draft(records: selected.values.sorted { $0.id < $1.id }, connection: connection)
                        confirming = true
                    }
                    .settingsActionRow()
                    .disabled(selected.isEmpty || !operation.permitsWrite || service.phase != .connected)
                } footer: {
                    if !selected.isEmpty { Text("\(selected.count) selected") }
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .publicMetaDBRead(ratings, service: service, enabled: !operation.succeeded) {
            selected.removeAll()
            return try await service.seasonRatingsForManagement(tmdbID: tmdbID, season: season, expectedConnectionID: $0)
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
