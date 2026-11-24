#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBMappingsView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var mappings = PublicMetaDBReadOperation<[PublicMetaDB.Record<PublicMetaDB.Mapping>]>()

    var body: some View {
        GroupedSettingsPage(title: "External IDs", backIdentifier: "publicmetadb.mappings.back") {
            PublicMetaDBContentLabel(content: content)
            SettingsSectionGroup {
                PublicMetaDBDetailLink("Submit an external ID") {
                    PublicMetaDBMappingEditor(service: service, content: content)
                }
                PublicMetaDBDetailLink("Look up an external ID") { PublicMetaDBMappingLookupView(service: service) }
            } footer: {
                Text("Community IDs don’t change server IDs or episode numbering.")
            }
            PublicMetaDBReadContent(service: service, operation: mappings, id: content) { records in
                if records.isEmpty { Text("No external IDs") }
                ForEach(PublicMetaDB.ExternalIDType.allCases, id: \.self) { type in
                    let values = records.filter { $0.value.idType == type }
                    if !values.isEmpty {
                        SettingsSectionGroup(verbatim: type.databaseName) {
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
                                    SettingsDisclosureLabel { PublicMetaDBMappingLabel(record: record, showsDatabase: false) }
                                }
                                .settingsActionRow()
                            }
                        } footer: {
                            if Set(values.map(\.value.idValue)).count > 1 {
                                Text("Conflicting IDs: no automatic match selected")
                            }
                        }
                    }
                }
            }
        }
        .publicMetaDBRead(mappings, service: service, id: content) {
            try await service.mappingsForManagement(content, expectedConnectionID: $0)
        }
    }
}

private extension PublicMetaDB.ExternalIDType {
    var databaseName: String {
        switch self {
        case .imdb: "IMDb"
        case .tvdb: "TheTVDB"
        case .mal: "MyAnimeList"
        case .anilist: "AniList"
        case .anidb: "AniDB"
        case .trakt: "Trakt"
        }
    }
}

private struct PublicMetaDBMappingLabel: View {
    let record: PublicMetaDB.Record<PublicMetaDB.Mapping>
    var showsDatabase = true
    var body: some View {
        VStack(alignment: .leading) {
            if showsDatabase {
                LabeledContent {
                    Text(verbatim: record.value.idValue)
                } label: { Text(verbatim: record.value.idType.databaseName) }
            } else {
                Text(verbatim: record.value.idValue)
            }
            if let contributor = record.contributor {
                Text(verbatim: contributor).font(SettingsRowMetrics.descriptionFont).settingsRowSecondary()
            }
        }
    }
}

private struct PublicMetaDBMappingFields: View {
    @Binding var type: PublicMetaDB.ExternalIDType
    @Binding var value: String

    var body: some View {
        Picker("Database", selection: $type) {
            ForEach(PublicMetaDB.ExternalIDType.allCases, id: \.self) { type in
                Text(verbatim: type.databaseName).tag(type)
            }
        }
        .pickerStyle(.menu)
        SettingsInputRow("External ID", axis: .horizontal) {
            TextField("ID", text: $value)
                .accessibilityIdentifier("publicmetadb.mapping.value")
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
        GroupedSettingsPage(title: "Submit an external ID", backIdentifier: "publicmetadb.mapping.edit.back") {
            PublicMetaDBContentLabel(content: content)
            SettingsSectionGroup {
                PublicMetaDBMappingFields(type: $type, value: $value)
                Button("Review mapping") {
                    do {
                        candidate = try .init(
                            content: content, idType: type, idValue: value.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        failure = nil
                        showsReview = true
                    } catch { failure = error }
                }
                .settingsActionRow()
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase != .connected)
            } footer: { Text("Use the database ID, not a title or URL.") }
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
    @State private var review = PublicMetaDBReadOperation<PublicMetaDB.MappingReview>()

    var body: some View {
        GroupedSettingsPage(title: "Review mapping", backIdentifier: "publicmetadb.mapping.review.back") {
            SettingsSectionGroup {
                PublicMetaDBContentLabel(content: mapping.content)
                LabeledContent {
                    Text(verbatim: mapping.idValue)
                } label: { Text(verbatim: mapping.idType.databaseName) }
            }
            if operation.succeeded {
                Text("Mapping confirmed on PublicMetaDB")
            } else {
                PublicMetaDBReadContent(service: service, operation: review) { review in
                    SettingsSectionGroup("IDs for this title") {
                        if review.records.isEmpty { Text("No external IDs") }
                        ForEach(review.records) { PublicMetaDBMappingLabel(record: $0) }
                    }
                    SettingsSectionGroup("Titles linked to this ID") {
                        if review.reverseMatches.isEmpty {
                            Text("No matches")
                        } else {
                            PublicMetaDBCatalogRows {
                                ForEach(review.reverseMatches, id: \.self) { PublicMetaDBContentLabel(content: $0) }
                            }
                        }
                    } footer: {
                        if review.reverseMatches.contains(where: { $0 != mapping.content }) {
                            Text("Another title uses this ID. Publishing won’t resolve the conflict.")
                        }
                    }
                    SettingsSectionGroup {
                        Button("Publish mapping") {
                            draft = review
                            confirming = true
                        }
                        .settingsActionRow()
                        .disabled(!operation.permitsWrite)
                    } footer: {
                        Text("The ID and your contributor name will be public.")
                    }
                }
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .publicMetaDBRead(review, service: service, enabled: !operation.succeeded) {
            try await service.reviewMapping(mapping, expectedConnectionID: $0)
        }
        .confirmationDialog("Publish this external ID?", isPresented: $confirming, presenting: draft) { draft in
            Button("Publish mapping") { operation.perform { try await service.submitManagedMapping(draft) } }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            Text("Publish \(draft.mapping.idValue) for TMDB \(String(draft.mapping.content.tmdbID)) on PublicMetaDB. Existing mappings and server metadata are unchanged.")
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
    @State private var matches = PublicMetaDBReadOperation<[PublicMetaDB.Content]>()

    private struct Query: Hashable {
        let type: PublicMetaDB.ExternalIDType
        let value: String
    }

    var body: some View {
        GroupedSettingsPage(title: "Look up an external ID", backIdentifier: "publicmetadb.mapping.lookup.back") {
            SettingsSectionGroup {
                PublicMetaDBMappingFields(type: $type, value: $value)
                Button("Look up ID") {
                    query = Query(type: type, value: value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .settingsActionRow()
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || service.phase != .connected)
            }
            if let query {
                PublicMetaDBReadContent(service: service, operation: matches, id: self.query) { matches in
                    SettingsSectionGroup(verbatim: "\(query.type.databaseName) · \(query.value)") {
                        if matches.isEmpty {
                            Text("No matches")
                        } else {
                            PublicMetaDBCatalogRows {
                                ForEach(matches, id: \.self) { content in
                                    NavigationLink {
                                        PublicMetaDBContentView(service: service, content: content)
                                    } label: {
                                        SettingsDisclosureLabel { PublicMetaDBContentLabel(content: content, allowsFocus: false) }
                                    }
                                }
                            }
                        }
                    } footer: {
                        if matches.count > 1 { Text("Multiple matches. Choose a title to inspect.") }
                    }
                }
                .id(query)
            }
        }
        .publicMetaDBRead(matches, service: service, id: query, enabled: query != nil) { connection in
            guard let query else { throw PublicMetaDB.Failure.invalidInput }
            return try await service.lookupMapping(
                idType: query.type, idValue: query.value, expectedConnectionID: connection
            )
        }
        .onChange(of: service.connectionID) { _, _ in
            query = nil
            value = ""
        }
    }
}
#endif
