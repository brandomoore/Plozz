#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBMappingsView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("External IDs")
            PublicMetaDBContentLabel(content: content)
            Text("Community mappings may disagree. Browsing or contributing here never replaces your server's IDs or episode numbering.")
                .foregroundStyle(.secondary)
            NavigationLink("Submit an external ID") {
                PublicMetaDBMappingEditor(service: service, content: content)
            }
            NavigationLink("Look up an external ID") { PublicMetaDBMappingLookupView(service: service) }
            PublicMetaDBReadContent(service: service, load: {
                try await service.mappingsForManagement(content, expectedConnectionID: $0)
            }) { records in
                if records.isEmpty { Text("No external IDs") }
                ForEach(PublicMetaDB.ExternalIDType.allCases, id: \.self) { type in
                    let values = records.filter { $0.value.idType == type }
                    if !values.isEmpty {
                        Section {
                            if Set(values.map(\.value.idValue)).count > 1 {
                                Text("Conflicting IDs: no automatic match selected")
                            }
                            ForEach(values) { record in
                                NavigationLink {
                                    PublicMetaDBContributionRecordView(
                                        service: service, category: .mappings, recordID: record.id,
                                        delete: { try await service.deleteManagedMapping(record, expectedConnectionID: $0) }
                                    ) {
                                        PublicMetaDBContentLabel(content: content)
                                        PublicMetaDBMappingLabel(record: record)
                                    }
                                } label: {
                                    PublicMetaDBMappingLabel(record: record)
                                }
                            }
                        } header: {
                            PublicMetaDBExternalIDLabel(type: type)
                        }
                    }
                }
            }
        }
    }
}

private struct PublicMetaDBExternalIDLabel: View {
    let type: PublicMetaDB.ExternalIDType
    var body: some View {
        switch type {
        case .imdb: Text(verbatim: "IMDb")
        case .tvdb: Text(verbatim: "TheTVDB")
        case .mal: Text(verbatim: "MyAnimeList")
        case .anilist: Text(verbatim: "AniList")
        case .anidb: Text(verbatim: "AniDB")
        case .trakt: Text(verbatim: "Trakt")
        }
    }
}

private struct PublicMetaDBMappingLabel: View {
    let record: PublicMetaDB.Record<PublicMetaDB.Mapping>
    var body: some View {
        VStack(alignment: .leading) {
            PublicMetaDBExternalIDLabel(type: record.value.idType)
            Text(verbatim: record.value.idValue)
            if let contributor = record.contributor { Text(verbatim: contributor).foregroundStyle(.secondary) }
        }
    }
}

private struct PublicMetaDBMappingEditor: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var type = PublicMetaDB.ExternalIDType.imdb
    @State private var value = ""
    @State private var candidate: PublicMetaDB.Mapping?
    @State private var showsReview = false
    @State private var failure: (any Error)?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Submit an external ID")
            PublicMetaDBContentLabel(content: content)
            Picker("Database", selection: $type) {
                ForEach(PublicMetaDB.ExternalIDType.allCases, id: \.self) { type in
                    PublicMetaDBExternalIDLabel(type: type).tag(type)
                }
            }
            TextField("External ID", text: $value)
                .accessibilityIdentifier("publicmetadb.mapping.value")
            Text("Use a database ID, not a title or URL. This publishes a new community contribution, not a correction to your server.")
                .foregroundStyle(.secondary)
            Button("Review mapping") {
                do {
                    candidate = try .init(
                        content: content, idType: type, idValue: value.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    failure = nil
                    showsReview = true
                } catch { failure = error }
            }
            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase != .connected)
            if let failure { PublicMetaDBFailureMessage(error: failure) }
        }
        .navigationDestination(isPresented: $showsReview) {
            if let candidate { PublicMetaDBMappingReviewView(service: service, mapping: candidate) }
        }
        .onChange(of: service.connectionID) { _, _ in
            showsReview = false
            candidate = nil
            value = ""
        }
    }
}

private struct PublicMetaDBMappingReviewView: View {
    let service: PublicMetaDBService
    let mapping: PublicMetaDB.Mapping
    @State private var draft: PublicMetaDB.MappingReview?
    @State private var confirming = false
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Review mapping")
            PublicMetaDBContentLabel(content: mapping.content)
            PublicMetaDBExternalIDLabel(type: mapping.idType)
            Text(verbatim: mapping.idValue)
            if operation.succeeded {
                Text("Mapping confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, load: {
                    try await service.reviewMapping(mapping, expectedConnectionID: $0)
                }) { review in
                    Text("Existing mappings for this title").font(.headline)
                    if review.records.isEmpty { Text("No external IDs") }
                    ForEach(review.records) { PublicMetaDBMappingLabel(record: $0) }
                    Text("Titles currently linked to this external ID").font(.headline)
                    if review.reverseMatches.isEmpty { Text("No matches") }
                    ForEach(review.reverseMatches, id: \.self) { PublicMetaDBContentLabel(content: $0) }
                    if review.reverseMatches.contains(where: { $0 != mapping.content }) {
                        Text("This ID also points to a different title. Publishing will not remove that conflict.")
                    }
                    Text("Your ID and contributor name will be public. Existing contributions are not edited or removed.")
                        .foregroundStyle(.secondary)
                    Button("Publish mapping") {
                        draft = review
                        confirming = true
                    }
                    .disabled(!operation.permitsWrite)
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Publish this external ID?", isPresented: $confirming, presenting: draft) { draft in
            Button("Publish mapping") { operation.perform { try await service.submitManagedMapping(draft) } }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Publish \(draft.mapping.idValue) for TMDB \(draft.mapping.content.tmdbID) on PublicMetaDB. Existing mappings and server metadata are unchanged.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBMappingLookupView: View {
    let service: PublicMetaDBService
    @State private var type = PublicMetaDB.ExternalIDType.imdb
    @State private var value = ""
    @State private var query: Query?

    private struct Query: Hashable {
        let type: PublicMetaDB.ExternalIDType
        let value: String
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Look up an external ID")
            Picker("Database", selection: $type) {
                ForEach(PublicMetaDB.ExternalIDType.allCases, id: \.self) { type in
                    PublicMetaDBExternalIDLabel(type: type).tag(type)
                }
            }
            TextField("External ID", text: $value)
            Button("Look up ID") {
                query = Query(type: type, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase != .connected)
            if let query {
                PublicMetaDBReadContent(service: service, load: {
                    try await service.lookupMapping(
                        idType: query.type, idValue: query.value, expectedConnectionID: $0
                    )
                }) { matches in
                    PublicMetaDBExternalIDLabel(type: query.type)
                    Text(verbatim: query.value)
                    if matches.isEmpty { Text("No matches") }
                    if matches.count > 1 { Text("Multiple matches: choose a title to inspect. No identity is selected automatically.") }
                    ForEach(matches, id: \.self) { content in
                        NavigationLink {
                            PublicMetaDBContentView(service: service, content: content)
                        } label: {
                            PublicMetaDBContentLabel(content: content, allowsFocus: false)
                        }
                    }
                }
                .id(query)
            }
        }
        .onChange(of: service.connectionID) { _, _ in
            query = nil
            value = ""
        }
    }
}
#endif
