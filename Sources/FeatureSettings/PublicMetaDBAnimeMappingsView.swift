#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBAnimeMappingsView: View {
    let service: PublicMetaDBService
    let tmdbID: Int
    @State private var mappings = PublicMetaDBReadOperation<PublicMetaDB.AnimeSeasons>()

    var body: some View {
        GroupedSettingsPage(title: "Anime season mappings", backIdentifier: "publicmetadb.anime.back") {
            Text(verbatim: "TMDB \(tmdbID)")
            SettingsSectionGroup {
                PublicMetaDBDetailLink("Publish or replace my mapping") {
                    PublicMetaDBAnimeEditor(service: service, tmdbID: tmdbID)
                }
                PublicMetaDBDetailLink("Delete my mapping for a logical season") {
                    PublicMetaDBAnimeDeleteView(service: service, tmdbID: tmdbID)
                }
            } footer: {
                Text("A logical season can span TMDB seasons or shows without changing server numbering or playback.")
            }
            PublicMetaDBReadContent(service: service, operation: mappings, id: tmdbID) { result in
                if result.seasons.isEmpty { Text("No anime season mappings") }
                ForEach(result.seasons) { group in
                    SettingsSectionGroup {
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
                                SettingsDisclosureLabel { PublicMetaDBAnimeChunkLabel(chunk: record.value, anchorID: tmdbID) }
                            }
                            .settingsActionRow()
                        }
                    }
                }
            }
        }
        .publicMetaDBRead(mappings, service: service, id: tmdbID) {
            try await service.animeMappingsForManagement(tmdbID: tmdbID, expectedConnectionID: $0)
        }
    }
}

private struct PublicMetaDBAnimeGroupLabel: View {
    let group: PublicMetaDB.AnimeSeasons.Group
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let name = group.seasonName {
                Text("Logical season \(group.seasonNumber) · \(name)").font(.headline)
            } else {
                Text("Logical season \(group.seasonNumber)").font(.headline)
            }
            Text(group.source == "community" ? "Community · \(group.contributor)" : "Member · \(group.contributor)")
                .settingsRowSecondary()
            Text(group.recommended ? "Recommended · Vote score: \(group.votes)" : "Vote score: \(group.votes)")
                .font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PublicMetaDBAnimeChunkLabel: View {
    let chunk: PublicMetaDB.AnimeChunk
    let anchorID: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TMDB \(String(chunk.chunkTmdbID ?? anchorID)) · Season \(chunk.tmdbSeason)")
            Group {
                switch (chunk.tmdbEpisodeStart, chunk.tmdbEpisodeEnd) {
                case let (start?, end?): Text("Episodes \(start)–\(end)")
                case let (start?, nil): Text("From episode \(start) · End unspecified")
                case let (nil, end?): Text("Through episode \(end) · Start unspecified")
                case (nil, nil): Text("Episode range unspecified")
                }
            }
            .font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
        }
        .accessibilityElement(children: .combine)
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
        SettingsInputRow("TMDB season", axis: .horizontal) {
            TextField("0 for specials", text: $draft.season)
        }
        SettingsInputRow("First episode", axis: .horizontal) {
            TextField("Optional", text: $draft.firstEpisode)
        }
        SettingsInputRow("Last episode", axis: .horizontal) {
            TextField("Optional", text: $draft.lastEpisode)
        }
        SettingsInputRow("Different TMDB show ID", axis: .horizontal) {
            TextField("Optional", text: $draft.showID)
        }
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
        GroupedSettingsPage(title: "Publish or replace my mapping", backIdentifier: "publicmetadb.anime.edit.back") {
            SettingsSectionGroup(verbatim: "TMDB \(tmdbID)") {
                TextField("Logical anime season (1 or greater)", text: $season)
                TextField("Season name (optional)", text: $name)
            } footer: {
                Text("Publishing replaces all your chunks for this logical season.")
            }
            ForEach($chunks) { $chunk in
                SettingsSectionGroup("TMDB chunk") {
                    PublicMetaDBAnimeChunkFields(draft: $chunk)
                    Button("Remove this chunk", role: .destructive) { chunks.removeAll { $0.id == chunk.id } }
                        .settingsActionRow()
                }
            }
            SettingsSectionGroup {
                Button("Add a chunk") { chunks.append(.init()) }.settingsActionRow()
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
                .settingsActionRow()
                .disabled(chunks.isEmpty || service.phase != .connected)
            }
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
    @State private var mappings = PublicMetaDBReadOperation<PublicMetaDB.AnimeSeasons>()

    var body: some View {
        GroupedSettingsPage(title: "Review anime mapping", backIdentifier: "publicmetadb.anime.review.back") {
            SettingsSectionGroup("Logical season \(mapping.seasonNumber) · TMDB \(String(mapping.tmdbID))") {
                if let name = mapping.seasonName { Text(verbatim: name) }
                // The immutable reviewed array has no editable per-row state.
                ForEach(Array(mapping.chunks.enumerated()), id: \.offset) { _, chunk in
                    PublicMetaDBAnimeChunkLabel(chunk: chunk, anchorID: mapping.tmdbID)
                }
            }
            if operation.succeeded {
                Text("Anime mapping confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, operation: mappings) { result in
                    PublicMetaDBAnimeExistingGroups(result: result, seasonNumber: mapping.seasonNumber)
                    SettingsSectionGroup {
                        Button("Replace my mapping") {
                            observed = result
                            connection = service.connectionID
                            confirming = true
                        }
                        .settingsActionRow()
                        .disabled(!operation.permitsWrite)
                    } footer: {
                        Text("Your API key identifies the mapping to replace, not the contributor name.")
                    }
                }
            }
            if operation.failure != nil {
                Text("Updates can take five minutes to appear. Check again before republishing.")
                    .settingsHelperText()
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .publicMetaDBRead(mappings, service: service, enabled: !operation.succeeded) {
            try await service.animeMappingsForManagement(tmdbID: mapping.tmdbID, expectedConnectionID: $0)
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
            Text("Deletes all your old chunks for logical season \(mapping.seasonNumber) of TMDB \(String(mapping.tmdbID)) and publishes the \(mapping.chunks.count) reviewed chunks. Other contributors’ mappings and your server stay unchanged.")
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
        let groups = result.seasons.filter { $0.seasonNumber == seasonNumber }
        SettingsSectionGroup("Existing mappings") {
            if groups.isEmpty { Text("No anime season mappings") }
            ForEach(groups) { group in
                PublicMetaDBAnimeGroupLabel(group: group)
                ForEach(group.chunks) { PublicMetaDBAnimeChunkLabel(chunk: $0.value, anchorID: result.tmdbID) }
            }
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
    @State private var mappings = PublicMetaDBReadOperation<PublicMetaDB.AnimeSeasons>()

    private struct Draft {
        let season: Int
        let observed: PublicMetaDB.AnimeSeasons
        let connection: UUID
    }

    var body: some View {
        GroupedSettingsPage(title: "Delete my logical-season mapping", backIdentifier: "publicmetadb.anime.delete.back") {
            if operation.succeeded {
                Text("Your logical-season mapping was confirmed removed from PublicMetaDB")
            } else {
                SettingsSectionGroup(verbatim: "TMDB \(tmdbID)") {
                    TextField("Logical anime season (1 or greater)", text: $season)
                    Button("Review season") {
                        if let number = Int(season.trimmingCharacters(in: .whitespacesAndNewlines)), number > 0 {
                            selectedSeason = number
                            failure = nil
                        } else { failure = PublicMetaDB.Failure.invalidInput }
                    }
                    .settingsActionRow()
                }
                if let selectedSeason {
                    PublicMetaDBReadContent(service: service, operation: mappings, id: self.selectedSeason) { result in
                        PublicMetaDBAnimeExistingGroups(result: result, seasonNumber: selectedSeason)
                        SettingsSectionGroup {
                            Button("Delete my mapping", role: .destructive) {
                                guard let connection = service.connectionID else { return }
                                draft = Draft(season: selectedSeason, observed: result, connection: connection)
                                confirming = true
                            }
                            .settingsActionRow()
                            .disabled(!operation.permitsWrite)
                        } footer: {
                            Text("Only chunks owned by your API key are removed.")
                        }
                    }
                    .id(selectedSeason)
                }
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .publicMetaDBRead(
            mappings, service: service, id: selectedSeason, enabled: selectedSeason != nil && !operation.succeeded
        ) {
            try await service.animeMappingsForManagement(tmdbID: tmdbID, expectedConnectionID: $0)
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
            Text("Deletes all your public chunks for logical season \(draft.season) of TMDB \(String(tmdbID)). Other contributors’ mappings and server episode numbering stay unchanged.")
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
