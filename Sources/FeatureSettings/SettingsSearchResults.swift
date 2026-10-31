import CoreModels
import CoreUI
import SwiftUI

public struct SettingsSearchResults: View {
    let query: String
    let platform: SettingsSearchEntry.Platform
    let onSelect: (SettingsSearchEntry, UUID?) -> Void
    @Environment(\.locale) private var locale

    public init(
        query: String, platform: SettingsSearchEntry.Platform,
        onSelect: @escaping (SettingsSearchEntry, UUID?) -> Void
    ) {
        self.query = query
        self.platform = platform
        self.onSelect = onSelect
    }
    private var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var results: [SettingsSearchEntry] {
        let available = SettingsSearchCatalog.entries(on: platform)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isEmptyQuery {
                        Text("Suggestions").font(.headline).foregroundStyle(.secondary)
                    }
                    ForEach(results) { entry in
                        #if os(tvOS)
                        SettingsPageActionLink { source in
                            onSelect(entry, source)
                        } label: {
                            resultLabel(entry)
                        }
                        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                        .accessibilityIdentifier("settings-search-result-\(entry.id)")
                        #else
                        Button { onSelect(entry, nil) } label: {
                            resultLabel(entry)
                        }

                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-search-result-\(entry.id)")
                        #endif
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("settings-search-results")
        }
    }

    private func resultLabel(_ entry: SettingsSearchEntry) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.body)
                Text(verbatim: entry.destinationPage(on: platform).path.map {
                    var resource = $0
                    resource.locale = locale
                    return String(localized: resource)
                }.joined(separator: " › "))
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
        } icon: {
            Image(systemName: entry.page.symbol)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

#if os(tvOS)
struct SettingsSearchTelevisionView: View {
    @State private var query = ""
    @Environment(SettingsNavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageHeader("Search settings")
            TextField("Search settings", text: $query)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings-search-field")
            SettingsSearchResults(query: query, platform: .television) { entry, source in
                navigation.pages.push(.searchResult(entry.id), sourceID: source)
            }
        }
        .padding(.horizontal, SettingsFormMetrics.pageInset)
        .padding(.top, SettingsFormMetrics.pageTopInset)
    }
}
#endif
