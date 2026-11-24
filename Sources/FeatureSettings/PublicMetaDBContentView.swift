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
        } else {
            self
        }
    }
}

private struct PublicMetaDBContentPresentation: ViewModifier {
    let service: PublicMetaDBService
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { service.presentedItem },
            set: { if $0 == nil { service.dismissContent() } }
        )) { item in
            NavigationStack {
                if let identity = PublicMetaDB.Content.matching(item) {
                    PublicMetaDBContentView(service: service, content: identity, title: item.title)
                } else {
                    GroupedSettingsPage(verbatim: item.title, backIdentifier: "publicmetadb.title.back") {
                        SettingsSectionGroup {
                            Text("No confirmed TMDB match. Seasons and episodes also need verified numbering.")
                            Button("Close") { service.dismissContent() }.settingsActionRow()
                        } footer: {
                            Text("No request was sent to PublicMetaDB.")
                        }
                    }
                }
            }
            .tint(palette.primaryText)
        }
    }
}

struct PublicMetaDBContentView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    var title: String? // l10n:content — provider-supplied media title

    var body: some View {
        GroupedSettingsPage(verbatim: title ?? "PublicMetaDB", backIdentifier: "publicmetadb.title.back") {
            SettingsSectionGroup {
                PublicMetaDBContentLabel(content: content)
                PublicMetaDBOpenCatalogTitle(service: service, content: content)
            }
            SettingsSectionGroup("Activity") {
                if content.isPlayable {
                    PublicMetaDBDetailLink("Add a watched play") { PublicMetaDBHistoryDateView(service: service, content: content) }
                }
                PublicMetaDBDetailLink("Watch history") {
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
                    PublicMetaDBDetailLink("Add to a list") { PublicMetaDBAddToListView(service: service, content: content) }
                }
                if content.mediaType == .tv && content.season == nil {
                    PublicMetaDBDetailLink("Drop show on PublicMetaDB") {
                        PublicMetaDBHistoryRecordView(service: service, action: .drop(content))
                    }
                }
            } footer: {
                Text("Changes apply to PublicMetaDB, not your media server.")
            }
            SettingsSectionGroup("Contributions") {
                if content.season == nil || content.episode != nil {
                    PublicMetaDBDetailLink("Community and personal ratings") {
                        PublicMetaDBContentRatingsView(service: service, content: content)
                    }
                }
                if content.mediaType == .tv {
                    PublicMetaDBDetailLink("Season ratings") {
                        PublicMetaDBSeasonRatingsView(service: service, tmdbID: content.tmdbID, initialSeason: content.season)
                    }
                }
                if content.season == nil {
                    PublicMetaDBDetailLink("External IDs") { PublicMetaDBMappingsView(service: service, content: content) }
                }
                if content.mediaType == .tv {
                    PublicMetaDBDetailLink("Anime season mappings") {
                        PublicMetaDBAnimeMappingsView(service: service, tmdbID: content.tmdbID)
                    }
                }
            }
        }
    }
}

struct PublicMetaDBDetailLink<Destination: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let destination: () -> Destination

    init(_ title: LocalizedStringResource, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        NavigationLink(destination: destination) {
            SettingsDisclosureLabel { Text(title) }
        }
        .settingsActionRow()
    }
}

/// Catalog labels start a lookup on appearance. Keep long results lazy inside
/// their Settings group rather than starting every title lookup at once.
struct PublicMetaDBCatalogRows<Rows: View>: View {
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Group(subviews: rows()) { rows in
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 0) {
                        row
                            #if os(iOS)
                            .frame(minHeight: MobileSettingsMetrics.rowMinHeight)
                            #endif
                        if row.id != rows.last?.id {
                            PlozzDivider().accessibilityHidden(true)
                        }
                    }
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
        .settingsActionRow()
        .disabled(operation.running || service.phase != .connected || service.resolveCatalogItem == nil)
        .accessibilityIdentifier("publicmetadb.open-title")
        PublicMetaDBMutationStatus(operation: operation)
            .onChange(of: service.connectionID) { _, _ in operation.cancel() }
            .onDisappear { operation.cancel() }
    }
}
#endif
