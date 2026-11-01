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
            .padding(SettingsFormMetrics.groupInset)
            .accessibilityElement(children: .contain)
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
                title(entry.title).font(.body)
                Text(verbatim: entry.destinationPath(on: platform).map {
                    $0.resolved(locale: locale)
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

    private func title(_ label: SettingsSearchLabel) -> Text {
        switch label {
        case .localized(let resource): Text(resource)
        case .verbatim(let value): Text(verbatim: value)
        }
    }
}

#if os(tvOS)
struct SettingsSearchTelevisionView<Content: View>: View {
    var isKids = false
    @ViewBuilder var content: () -> Content
    @Environment(SettingsNavigationModel.self) private var navigation
    @Environment(\.settingsPageContext) private var page
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                searchCard

                if navigation.isSearching {
                    searchResults.transition(.opacity)
                } else {
                    content()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, SettingsFormMetrics.pageInset)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: navigation.isSearching)
        }
        .scrollClipDisabled()
        .scrollsTopNavigation(onReturnToTop: {
            navigation.select(navigation.isSearching ? .search : .playback)
        })
        .onExitCommand(perform: navigation.isSearching && page?.isCurrent == true ? { navigation.endSearch() } : nil)
    }

    private var searchResults: some View {
        SettingsSearchResults(
            query: navigation.searchQuery, platform: .television, isKids: isKids
        ) { entry, source in
            navigation.pages.push(.searchResult(entry.id), sourceID: source)
        }
        .background {
            NativeFocusRegionObserver(isEnabled: page?.isCurrent == true) {
                navigation.focusInDetail = false
                navigation.restoringSidebar = false
                navigation.enteringDetail = false
            }
        }
    }

    private var searchCard: some View {
        @Bindable var navigation = navigation
        return HStack(spacing: PlozzTheme.Spacing.medium) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
            TextField("Search settings", text: $navigation.searchQuery, onEditingChanged: { editing in
                if editing { navigation.beginSearch() }
            })
            .autocorrectionDisabled()
            .submitLabel(.search)
            .settingsCategoryFocus(.search)
        }
        .padding(SettingsFormMetrics.groupInset)
        .settingsGroupSurface(cornerRadius: PlozzTheme.Metrics.mediumCardCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings-search-card")
    }
}
#endif
