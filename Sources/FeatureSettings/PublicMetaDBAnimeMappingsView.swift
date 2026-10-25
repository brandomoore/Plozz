#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBAnimeMappingsView: View {
    let service: PublicMetaDBService
    let tmdbID: Int

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Anime season mappings")
            Text(verbatim: "TMDB \(tmdbID)")
            Text("Logical anime seasons can span multiple TMDB seasons or shows. These contributions do not change server IDs, episode order or playback matching.")
                .foregroundStyle(.secondary)
            NavigationLink("Publish or replace my mapping") {
                PublicMetaDBAnimeEditor(service: service, tmdbID: tmdbID)
            }
            NavigationLink("Delete my mapping for a logical season") {
                PublicMetaDBAnimeDeleteView(service: service, tmdbID: tmdbID)
            }
            PublicMetaDBReadContent(service: service, load: {
                try await service.animeMappingsForManagement(tmdbID: tmdbID, expectedConnectionID: $0)
            }) { result in
                if result.seasons.isEmpty { Text("No anime season mappings") }
                ForEach(result.seasons) { group in
                    Section {
                        PublicMetaDBAnimeGroupLabel(group: group)
                        ForEach(group.chunks) { record in
                            NavigationLink {
                                PublicMetaDBContributionRecordView(
                                    service: service, category: .animeSeasons, recordID: record.id,
                                    delete: {
                                        try await service.deleteManagedAnimeChunk(record, tmdbID: tmdbID, expectedConnectionID: $0)
                                    }
                                ) {
                                    PublicMetaDBAnimeGroupLabel(group: group)
                                    PublicMetaDBAnimeChunkLabel(chunk: record.value, anchorID: tmdbID)
                                }
                            } label: {
                                PublicMetaDBAnimeChunkLabel(chunk: record.value, anchorID: tmdbID)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PublicMetaDBAnimeGroupLabel: View {
    let group: PublicMetaDB.AnimeSeasons.Group
    var body: some View {
        VStack(alignment: .leading) {
            Text("Logical season \(group.seasonNumber)")
            if let name = group.seasonName { Text(verbatim: name) }
            Text(verbatim: group.contributor)
            Text(group.source == "community" ? "Community-maintained mapping" : "Member contribution")
            if group.recommended { Text("Recommended by PublicMetaDB") }
            Text("Vote score: \(group.votes)")
        }
    }
}

private struct PublicMetaDBAnimeChunkLabel: View {
    let chunk: PublicMetaDB.AnimeChunk
    let anchorID: Int
    var body: some View {
        VStack(alignment: .leading) {
            Text(verbatim: "TMDB \(chunk.chunkTmdbID ?? anchorID)")
            Text("TMDB season \(chunk.tmdbSeason)")
            if let start = chunk.tmdbEpisodeStart { Text("First episode: \(start)") }
            else { Text("First episode unspecified") }
            if let end = chunk.tmdbEpisodeEnd { Text("Last episode: \(end)") }
            else { Text("Last episode unspecified") }
        }
    }
}

struct PublicMetaDBAnimeChunkDraft: Identifiable {
    let id = UUID()
    var season = ""
    var firstEpisode = ""
    var lastEpisode = ""
    var showID = ""

    func chunk() throws -> PublicMetaDB.AnimeChunk {
        guard let season = Int(season.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw PublicMetaDB.Failure.invalidInput
        }
        func optionalNumber(_ text: String) throws -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let number = Int(trimmed) else { throw PublicMetaDB.Failure.invalidInput }
            return number
        }
        return try .init(
            tmdbSeason: season, tmdbEpisodeStart: optionalNumber(firstEpisode),
            tmdbEpisodeEnd: optionalNumber(lastEpisode), chunkTmdbID: optionalNumber(showID)
        )
    }
}

private struct PublicMetaDBAnimeChunkFields: View {
    @Binding var draft: PublicMetaDBAnimeChunkDraft
    var body: some View {
        TextField("TMDB season (0 for specials)", text: $draft.season)
        TextField("First episode (optional)", text: $draft.firstEpisode)
        TextField("Last episode (optional)", text: $draft.lastEpisode)
        TextField("Different TMDB show ID (optional)", text: $draft.showID)
    }
}

private struct PublicMetaDBAnimeEditor: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    @State private var season = ""
    @State private var name = ""
    @State private var chunks = [PublicMetaDBAnimeChunkDraft()]
    @State private var candidate: PublicMetaDB.AnimeMapping?
    @State private var showsReview = false
    @State private var failure: (any Error)?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Publish or replace my mapping")
            Text(verbatim: "TMDB \(tmdbID)")
            TextField("Logical anime season (1 or greater)", text: $season)
            TextField("Season name (optional)", text: $name)
            Text("Logical seasons are separate from TMDB season numbers. Publishing replaces all your existing chunks for this logical season.")
                .foregroundStyle(.secondary)
            ForEach($chunks) { $chunk in
                Section {
                    PublicMetaDBAnimeChunkFields(draft: $chunk)
                    Button("Remove this chunk", role: .destructive) { chunks.removeAll { $0.id == chunk.id } }
                } header: {
                    Text("TMDB chunk")
                }
            }
            Button("Add a chunk") { chunks.append(.init()) }
            Button("Review replacement") {
                do {
                    guard let season = Int(season.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        throw PublicMetaDB.Failure.invalidInput
                    }
                    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    candidate = try .init(
                        tmdbID: tmdbID, seasonNumber: season, seasonName: name.isEmpty ? nil : name,
                        chunks: chunks.map { try $0.chunk() }
                    )
                    failure = nil
                    showsReview = true
                } catch { failure = error }
            }
            .disabled(chunks.isEmpty || service.phase != .connected)
            if let failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .navigationDestination(isPresented: $showsReview) {
            if let candidate { PublicMetaDBAnimeReviewView(service: service, mapping: candidate) }
        }
        .onChange(of: service.connectionID) { _, _ in
            showsReview = false
            candidate = nil
            chunks = [.init()]
            season = ""
            name = ""
        }
    }
}

private struct PublicMetaDBAnimeReviewView: View {
    let service: PublicMetaDBService
    let mapping: PublicMetaDB.AnimeMapping
    @State private var observed: PublicMetaDB.AnimeSeasons?
    @State private var connection: UUID?
    @State private var confirming = false
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Review anime mapping")
            Text(verbatim: "TMDB \(mapping.tmdbID)")
            Text("Logical season \(mapping.seasonNumber)")
            if let name = mapping.seasonName { Text(verbatim: name) }
            // The immutable reviewed array has no editable per-row state.
            ForEach(Array(mapping.chunks.enumerated()), id: \.offset) { _, chunk in
                PublicMetaDBAnimeChunkLabel(chunk: chunk, anchorID: mapping.tmdbID)
            }
            if operation.succeeded {
                Text("Anime mapping confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, load: {
                    try await service.animeMappingsForManagement(tmdbID: mapping.tmdbID, expectedConnectionID: $0)
                }) { result in
                    PublicMetaDBAnimeExistingGroups(result: result, seasonNumber: mapping.seasonNumber)
                    Text("Your key selects which existing mapping is replaced. Contributor names do not prove ownership. All your old chunks for this logical season are deleted and the reviewed chunks become public.")
                    Button("Replace my mapping") {
                        observed = result
                        connection = service.connectionID
                        confirming = true
                    }
                    .disabled(!operation.permitsWrite)
                }
            }
            Text("PublicMetaDB may cache these reads for five minutes. If readback is unconfirmed, inspect the mapping later rather than publishing it again.")
                .foregroundStyle(.secondary)
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Replace your entire logical-season mapping?", isPresented: $confirming) {
            Button("Publish replacement", role: .destructive) {
                guard let observed, let connection else { return }
                operation.perform {
                    try await service.replaceManagedAnimeMapping(mapping, observed: observed, expectedConnectionID: connection)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces all your chunks for logical season \(mapping.seasonNumber) of TMDB \(mapping.tmdbID). Other users' contributions and your media server are not selected for modification.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            observed = nil
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

private struct PublicMetaDBAnimeExistingGroups: View {
    let result: PublicMetaDB.AnimeSeasons
    let seasonNumber: Int
    var body: some View {
        Text("Existing contributions for this logical season").font(.headline)
        let groups = result.seasons.filter { $0.seasonNumber == seasonNumber }
        if groups.isEmpty { Text("No anime season mappings") }
        ForEach(groups) { group in
            PublicMetaDBAnimeGroupLabel(group: group)
            ForEach(group.chunks) { PublicMetaDBAnimeChunkLabel(chunk: $0.value, anchorID: result.tmdbID) }
        }
    }
}

private struct PublicMetaDBAnimeDeleteView: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    @State private var season = ""
    @State private var selectedSeason: Int?
    @State private var draft: Draft?
    @State private var confirming = false
    @State private var failure: (any Error)?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let season: Int
        let observed: PublicMetaDB.AnimeSeasons
        let connection: UUID
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Delete my logical-season mapping")
            Text(verbatim: "TMDB \(tmdbID)")
            if operation.succeeded {
                Text("Your logical-season mapping was confirmed removed from PublicMetaDB")
            } else {
                TextField("Logical anime season (1 or greater)", text: $season)
                Button("Review season") {
                    if let number = Int(season.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 {
                        selectedSeason = number
                        failure = nil
                    } else { failure = PublicMetaDB.Failure.invalidInput }
                }
                if let selectedSeason {
                    PublicMetaDBReadContent(service: service, load: {
                        try await service.animeMappingsForManagement(tmdbID: tmdbID, expectedConnectionID: $0)
                    }) { result in
                        PublicMetaDBAnimeExistingGroups(result: result, seasonNumber: selectedSeason)
                        Text("PublicMetaDB deletes only the chunks owned by this API key for the selected logical season. Plozz does not identify your group from its contributor name.")
                        Button("Delete my mapping", role: .destructive) {
                            guard let connection = service.connectionID else { return }
                            draft = Draft(season: selectedSeason, observed: result, connection: connection)
                            confirming = true
                        }
                        .disabled(!operation.permitsWrite)
                    }
                    .id(selectedSeason)
                }
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete all your chunks for this logical season?", isPresented: $confirming, presenting: draft) { draft in
            Button("Delete my mapping", role: .destructive) {
                operation.perform {
                    try await service.deleteManagedAnimeSeason(
                        seasonNumber: draft.season, observed: draft.observed, expectedConnectionID: draft.connection
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Deletes your entire mapping for logical season \(draft.season) of TMDB \(tmdbID), not just one chunk. Server episode numbering remains unchanged.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            selectedSeason = nil
            season = ""
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}
#endif
