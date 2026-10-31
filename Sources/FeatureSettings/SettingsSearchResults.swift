import CoreModels
import CoreUI
import SwiftUI

public struct SettingsSearchResults: View {
    let query: String
    let platform: SettingsSearchEntry.Platform
    let isKids: Bool
    let onSelect: (SettingsSearchEntry, UUID?) -> Void
    @Environment(\.locale) private var locale

    public init(
        query: String, platform: SettingsSearchEntry.Platform, isKids: Bool = false,
        onSelect: @escaping (SettingsSearchEntry, UUID?) -> Void
    ) {
        self.query = query
        self.platform = platform
        self.isKids = isKids
        self.onSelect = onSelect
    }
    private var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var results: [SettingsSearchEntry] {
        let available = SettingsSearchCatalog.entries(on: platform, isKids: isKids)
        if isEmptyQuery {
            let suggestions = ["subtitle-size", "theme", "autoplay-next-episode", "resume-rewind", "display-size"]
            return suggestions.compactMap { id in available.first { $0.id == id } }
        }
        return SettingsSearchIndex(entries: available, locale: locale).results(for: query)
    }

    public var body: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            #if os(tvOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEmptyQuery {
                        Text("Suggestions").font(.headline).foregroundStyle(.secondary)
                    }
                    ForEach(results) { entry in
                        SettingsPageActionLink { source in
                            onSelect(entry, source)
                        } label: {
                            resultLabel(entry)
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("settings-search-result-\(entry.id)")
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("settings-search-results")
            #else
            List {
                if isEmptyQuery {
                    Text("Suggestions").font(.headline).foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                ForEach(results) { entry in
                    Button { onSelect(entry, nil) } label: {
                        resultLabel(entry)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("settings-search-result-\(entry.id)")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .accessibilityIdentifier("settings-search-results")
            #endif
        }
    }

    private func resultLabel(_ entry: SettingsSearchEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body)
                Text(verbatim: entry.destinationPath(on: platform).map {
                    var resource = $0
                    resource.locale = locale
                    return String(localized: resource)
                }.joined(separator: " › "))
                #if os(tvOS)
                .font(.caption)
                #else
                .font(.subheadline)
                #endif
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: entry.page.symbol)
        }
        #if os(tvOS)
        .padding(.vertical, 10)
        #endif
        .contentShape(Rectangle())
    }
}

#if os(tvOS)
struct SettingsSearchTelevisionView: View {
    var isKids = false
    @State private var query = ""
    @Environment(SettingsNavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageHeader("Search settings")
            TextField("Search settings", text: $query)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings-search-field")
            SettingsSearchResults(query: query, platform: .television, isKids: isKids) { entry, source in
                navigation.pages.push(.searchResult(entry.id), sourceID: source)
            }
        }
        .padding(.horizontal, SettingsFormMetrics.pageInset)
        .padding(.top, SettingsFormMetrics.pageTopInset)
    }
}
#endif
