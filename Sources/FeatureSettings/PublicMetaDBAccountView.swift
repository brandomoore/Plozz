#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBAccountView: View {
    let service: PublicMetaDBService
    var makeHistoryImport: (@MainActor () -> TrackerHistoryImportSession)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(verbatim: "PublicMetaDB")
            Text("These are your PublicMetaDB records, not your media server's history. Browsing does not change either.")
                .foregroundStyle(.secondary)
            if service.phase == .connected {
                Toggle("Look up community ratings", isOn: Binding(
                    get: { service.communityRatingsEnabled },
                    set: { service.setCommunityRatingsEnabled($0) }
                ))
                .accessibilityIdentifier("publicmetadb.ratings")
                Text("Looks up titles you browse on PublicMetaDB. Adds its overall score alongside existing ratings without changing server metadata.")
                    .foregroundStyle(.secondary)
                NavigationLink("Playback reporting") { PublicMetaDBPlaybackSettingsView(service: service) }
                    .accessibilityIdentifier("publicmetadb.playback")
                NavigationLink("Watchlist destination") { PublicMetaDBWatchlistSettingsView(service: service) }
                    .accessibilityIdentifier("publicmetadb.watchlist")
                if let makeHistoryImport {
                    NavigationLink("Compare with server history") {
                        TrackerHistoryImportView(makeSession: makeHistoryImport)
                    }
                    .accessibilityIdentifier("publicmetadb.compare-history")
                }
                if service.makeHistoryExportSource != nil {
                    NavigationLink("Export server history") {
                        PublicMetaDBHistoryExportView(service: service)
                    }
                    .accessibilityIdentifier("publicmetadb.export-history")
                }
                NavigationLink("Watch history") {
                    PublicMetaDBPagedRecords(
                        service: service, title: "Watch history",
                        load: { try await $0.history(page: $1) }
                    ) { record in
                        NavigationLink {
                            PublicMetaDBHistoryRecordView(service: service, action: .deletePlay(record))
                        } label: {
                            VStack(alignment: .leading) {
                                PublicMetaDBContentLabel(content: record.value.content, allowsFocus: false)
                                PublicMetaDBWatchDateLabel(date: record.value.watchedAt)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("publicmetadb.history")
                NavigationLink("Delete multiple plays") { PublicMetaDBBulkHistoryView(service: service) }
                    .accessibilityIdentifier("publicmetadb.history.bulk")
                NavigationLink("Resume points") {
                    PublicMetaDBPagedRecords(
                        service: service, title: "Resume points",
                        load: { try await $0.resumePoints(page: $1) }
                    ) { record in
                        NavigationLink {
                            PublicMetaDBHistoryRecordView(service: service, action: .clearResume(record))
                        } label: {
                            VStack(alignment: .leading) {
                                PublicMetaDBContentLabel(content: record.value.content, allowsFocus: false)
                                Text(record.value.progress / 100, format: .percent.precision(.fractionLength(1)))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink("Dropped titles") {
                    PublicMetaDBPagedRecords(
                        service: service, title: "Dropped titles",
                        load: { try await $0.dropped(page: $1) }
                    ) { record in
                        NavigationLink {
                            PublicMetaDBHistoryRecordView(service: service, action: .undrop(record))
                        } label: {
                            PublicMetaDBContentLabel(content: record.value, allowsFocus: false)
                        }
                    }
                }
                NavigationLink("Lists") {
                    PublicMetaDBPagedRecords(
                        service: service, title: "Lists", load: { try await $0.lists(page: $1) }
                    ) { list in
                        NavigationLink {
                            PublicMetaDBOwnedListView(service: service, list: list)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: list.name)
                                Text(list.isPublic ? "Public" : "Private").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                NavigationLink("Create a list") { PublicMetaDBCreateListView(service: service) }
                NavigationLink("Open a public list") { PublicMetaDBOpenListView(service: service) }
                NavigationLink("Picks") { PublicMetaDBPicksView(service: service) }
                NavigationLink("Look up an external ID") { PublicMetaDBMappingLookupView(service: service) }
            } else {
                PublicMetaDBConnectionStatus(phase: service.phase)
            }
            Button("Done") { dismiss() }
        }
    }
}

struct PublicMetaDBContentLabel: View {
    let content: PublicMetaDB.Content
    var allowsFocus = true
    @Environment(\.publicMetaDBCatalogService) private var service
    @State private var lookup = PublicMetaDBReadOperation<String>()

    private struct Request: Hashable {
        let content: PublicMetaDB.Content
        let connection: UUID?
    }

    var body: some View {
        VStack(alignment: .leading) {
            if lookup.connectionID == service?.connectionID, let title = lookup.value {
                Text(verbatim: title)
            } else {
                Text(verbatim: "TMDB \(content.tmdbID)")
                if lookup.failure != nil, !lookup.loading {
                    Text("Title lookup unavailable").foregroundStyle(.secondary)
                }
            }
            if let season = content.season, let episode = content.episode {
                Text("Season \(season), episode \(episode)").foregroundStyle(.secondary)
            } else if let season = content.season {
                Text("Season \(season)").foregroundStyle(.secondary)
            } else {
                Text(content.mediaType == .movie ? "Movie" : "TV show").foregroundStyle(.secondary)
            }
        }
        #if os(tvOS)
        .focusable(allowsFocus)
        #endif
        .task(id: Request(content: content, connection: service?.connectionID)) {
            guard let service, service.resolveCatalogItem != nil else { return }
            await lookup.load(service: service) {
                try await service.catalogItem(for: content, expectedConnectionID: $0).title
            }
        }
    }
}

struct PublicMetaDBFailureMessage: View {
    let error: any Error
    var body: some View {
        if let failure = error as? PublicMetaDB.RatingBatchFailure {
            Text("\(failure.confirmedRecordIDs.count) ratings were confirmed changed. \(failure.unconfirmedCount) ratings remain unconfirmed.")
            if !failure.unconfirmedEpisodes.isEmpty {
                Text("Unconfirmed episodes: \(failure.unconfirmedEpisodes.map { $0.formatted() }.joined(separator: ", "))")
            }
            Text("Refresh the season and review the remaining entries before making another attempt.")
        } else if let failure = error as? PublicMetaDB.HistoryDeletionFailure {
            Text("\(failure.confirmedIDs.count) selected plays were confirmed removed. Processing stopped at the next play; \(failure.remainingIDs.count) later plays were not attempted.")
            if let reason = failure.cause as? PublicMetaDB.Failure {
                Text(reason.appError.userMessage)
            } else if let reason = failure.cause as? AppError {
                Text(reason.userMessage)
            } else if failure.cause is CancellationError {
                Text("Cancelled")
            } else {
                Text("The request could not be completed.")
            }
            Text("Refresh the history and review a new selection before continuing.")
        } else if let failure = error as? PublicMetaDB.Failure {
            switch failure {
            case .uncertainWrite:
                Text("PublicMetaDB may have saved the change, but its reply could not be confirmed. Check the record before trying again.")
            case .incompleteResponse:
                Text("PublicMetaDB returned an incomplete result. The requested operation cannot be confirmed from this response.")
            case .connectionChanged:
                Text("The profile or connection changed. Open this page again for the current profile.")
            case .invalidKey:
                Text("PublicMetaDB rejected this key. Check or replace it in Settings.")
            default:
                Text(failure.appError.userMessage)
            }
        } else if let error = error as? AppError {
            Text(error.userMessage)
        } else if error is CancellationError {
            Text("Cancelled")
        } else {
            Text("The request could not be completed.")
        }
    }
}

struct PublicMetaDBPagedRecords<Item: Decodable & Identifiable & Sendable, Row: View>: View {
    let service: PublicMetaDBService
    let title: LocalizedStringResource
    let load: @Sendable (PublicMetaDBClient, Int) async throws -> PublicMetaDB.Page<Item>
    @ViewBuilder let row: (Item) -> Row
    @State private var page = 1
    @State private var result: PublicMetaDB.Page<Item>?
    @State private var failure: (any Error)?
    @State private var reload = 0
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var loadedConnection: UUID?

    private struct Request: Hashable {
        let connection: UUID?
        let page: Int
        let reload: Int
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(title)
            if loading { ProgressView() }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            if let result, loadedConnection == service.connectionID {
                if result.items.isEmpty { Text("No records") }
                ForEach(result.items) { row($0) }
                Text("Page \(result.page) of \(max(1, result.totalPages))")
                    .foregroundStyle(.secondary)
                if page > 1 { Button("Previous page") { page -= 1 } }
                if page < result.totalPages { Button("Next page") { page += 1 } }
            }
            Button("Refresh") { reload += 1 }
                .disabled(loading || service.client == nil)
                .accessibilityIdentifier("publicmetadb.refresh")
        }
        .task(id: Request(connection: service.connectionID, page: page, reload: reload)) {
            let currentRequest = UUID()
            let connection = service.connectionID
            requestID = currentRequest
            result = nil
            failure = nil
            guard let client = service.client else {
                failure = PublicMetaDB.Failure.disconnected
                return
            }
            loading = true
            defer { if requestID == currentRequest { loading = false } }
            do {
                let response = try await load(client, page)
                try Task.checkCancellation()
                guard Set(response.items.map(\.id)).count == response.items.count else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
                guard requestID == currentRequest, connection == service.connectionID else { return }
                loadedConnection = connection
                result = response
            } catch {
                if !Task.isCancelled { failure = error }
            }
        }
        .onChange(of: service.connectionID) { _, _ in page = 1 }
    }
}

private struct PublicMetaDBPicksView: View {
    let service: PublicMetaDBService
    @State private var picks: [PublicMetaDB.Pick] = []
    @State private var failure: (any Error)?
    @State private var loading = false
    @State private var reload = 0
    @State private var requestID = UUID()
    @State private var loadedConnection: UUID?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Picks")
            Text("Picks are created on PublicMetaDB. Recommendations can remain cached there for up to 24 hours.")
                .foregroundStyle(.secondary)
            if loading { ProgressView() }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            ForEach(loadedConnection == service.connectionID ? picks : []) { pick in
                NavigationLink {
                    PublicMetaDBPickItemsView(service: service, pick: pick)
                } label: {
                    VStack(alignment: .leading) {
                        Text(verbatim: pick.name)
                        if let description = pick.description {
                            Text(verbatim: description).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button("Refresh") { reload += 1 }.disabled(loading)
        }
        .task(id: "\(service.connectionID?.uuidString ?? ""):\(reload)") {
            let currentRequest = UUID()
            let connection = service.connectionID
            requestID = currentRequest
            picks = []
            failure = nil
            guard let client = service.client else {
                failure = PublicMetaDB.Failure.disconnected
                return
            }
            loading = true
            defer { if requestID == currentRequest { loading = false } }
            do {
                let response = try await client.picks()
                try Task.checkCancellation()
                guard response.isComplete, Set(response.items.map(\.id)).count == response.items.count else {
                    throw PublicMetaDB.Failure.incompleteResponse
                }
                guard requestID == currentRequest, connection == service.connectionID else { return }
                loadedConnection = connection
                picks = response.items
            } catch {
                if !Task.isCancelled { failure = error }
            }
        }
    }
}

private struct PublicMetaDBPickItemsView: View {
    let service: PublicMetaDBService
    let pick: PublicMetaDB.Pick
    var body: some View {
        PublicMetaDBPagedRecords(
            service: service, title: "Recommendations",
            load: { try await $0.pickItems(id: pick.id, page: $1).page }
        ) { item in
            NavigationLink {
                PublicMetaDBContentView(service: service, content: item.content, title: item.title)
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: item.title)
                    if let year = item.year { Text(verbatim: year).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct PublicMetaDBPage<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(tvOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                content()
            }
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
            .padding(.vertical, 40)
        }
        .scrollClipDisabled()
        #else
        SettingsPageList { content() }
        #endif
    }
}
#endif
