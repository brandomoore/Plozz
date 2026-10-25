#if canImport(SwiftUI)
import CoreModels
import CoreUI
import PublicMetaDBService
import SwiftUI

private struct PublicMetaDBCatalogServiceKey: EnvironmentKey {
    static let defaultValue: PublicMetaDBService? = nil
}

extension EnvironmentValues {
    var publicMetaDBCatalogService: PublicMetaDBService? {
        get { self[PublicMetaDBCatalogServiceKey.self] }
        set { self[PublicMetaDBCatalogServiceKey.self] = newValue }
    }
}

public extension View {
    @ViewBuilder func publicMetaDBContentPresentation(service: PublicMetaDBService?) -> some View {
        if let service {
            modifier(PublicMetaDBContentPresentation(service: service))
                .environment(\.publicMetaDBCatalogService, service)
                .environment(\.communityPlaybackTimestampSource, service.playbackTimestampSource)
        } else {
            self
        }
    }
}

private struct PublicMetaDBContentPresentation: ViewModifier {
    let service: PublicMetaDBService

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { service.presentedItem },
            set: { if $0 == nil { service.dismissContent() } }
        )) { item in
            NavigationStack {
                if let identity = PublicMetaDB.Content.matching(item) {
                    PublicMetaDBContentView(service: service, content: identity, title: item.title)
                } else {
                    PublicMetaDBPage {
                        SettingsPageHeader(verbatim: item.title)
                        Text("PublicMetaDB needs an unambiguous TMDB identity. Episodes and seasons also need confirmed TMDB numbering. No tracker request was sent for this title.")
                        Button("Close") { service.dismissContent() }
                    }
                }
            }
        }
    }
}

struct PublicMetaDBContentView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    var title: String?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(verbatim: title ?? "PublicMetaDB")
            PublicMetaDBContentLabel(content: content)
            PublicMetaDBOpenCatalogTitle(service: service, content: content)
            Text("These controls change PublicMetaDB only. Server history and curated metadata remain separate.")
                .foregroundStyle(.secondary)
            if content.isPlayable {
                NavigationLink("Add a watched play") { PublicMetaDBHistoryDateView(service: service, content: content) }
                NavigationLink("Community timestamps") { PublicMetaDBMarkerView(service: service, content: content) }
            }
            NavigationLink("Watch history") {
                PublicMetaDBPagedRecords(
                    service: service, title: "Watch history",
                    load: { try await $0.history(content: content, page: $1) }
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
            if content.season == nil {
                NavigationLink("Add to a list") { PublicMetaDBAddToListView(service: service, content: content) }
                NavigationLink("External IDs") { PublicMetaDBMappingsView(service: service, content: content) }
            }
            if content.season == nil || content.episode != nil {
                NavigationLink("Community and personal ratings") {
                    PublicMetaDBContentRatingsView(service: service, content: content)
                }
            }
            if content.mediaType == .tv {
                if content.season == nil {
                    NavigationLink("Drop show on PublicMetaDB") {
                        PublicMetaDBHistoryRecordView(service: service, action: .drop(content))
                    }
                }
                NavigationLink("Season ratings") {
                    PublicMetaDBSeasonRatingsView(service: service, tmdbID: content.tmdbID, initialSeason: content.season)
                }
                NavigationLink("Anime season mappings") {
                    PublicMetaDBAnimeMappingsView(service: service, tmdbID: content.tmdbID)
                }
            }
        }
    }
}

private struct PublicMetaDBOpenCatalogTitle: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var operation = PublicMetaDBMutationOperation()

    var body: some View {
        Button(content.season == nil ? "Open title in Plozz" : "Open show in Plozz") {
            guard let connection = service.connectionID else { return }
            operation.perform { try await service.openCatalogItem(for: content, expectedConnectionID: connection) }
        }
        .disabled(operation.running || service.phase != .connected || service.resolveCatalogItem == nil)
        .accessibilityIdentifier("publicmetadb.open-title")
        PublicMetaDBMutationStatus(operation: operation)
            .onChange(of: service.connectionID) { _, _ in operation.cancel() }
            .onDisappear { operation.cancel() }
    }
}
#endif
