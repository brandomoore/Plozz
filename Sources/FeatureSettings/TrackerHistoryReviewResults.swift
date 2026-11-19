#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

extension View {
    /// Read-only results are their own stops; selectable rows delegate focus
    /// to the native switch rather than wrapping it in a disabled focus host.
    @ViewBuilder
    func trackerHistoryRowFocus(readOnly: Bool) -> some View {
        #if os(tvOS)
        if readOnly {
            self.focusable()
        } else {
            self.focusSection()
        }
        #else
        self
        #endif
    }
}

enum TrackerHistoryResultFilter: CaseIterable {
    case all, ready, conflicts, matches, unavailable, selected

    func label(count: Int) -> Text {
        switch self {
        case .all: Text("All (\(count))")
        case .ready: Text("Ready (\(count))")
        case .conflicts: Text("Conflicts (\(count))")
        case .matches: Text("Already match (\(count))")
        case .unavailable: Text("Unavailable (\(count))")
        case .selected: Text("Selected (\(count))")
        }
    }
}

struct TrackerHistorySettingsStack<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: MobileSettingsMetrics.sectionSpacing, content: content)
        #else
        VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing, content: content)
        #endif
    }
}

/// Filtering and paging only affect visibility. Selection belongs to the
/// reviewed plan and never expands to include a filter or page.
struct TrackerHistoryReviewResults<Row: Identifiable, Content: View, Action: View>: View where Row.ID == UUID {
    let rows: [Row]
    let selected: Set<UUID>
    let identifier: String
    let hint: LocalizedStringResource?
    let category: (Row) -> TrackerHistoryResultFilter
    let title: (Row) -> String
    @ViewBuilder let action: () -> Action
    @ViewBuilder let content: (Row) -> Content
    @State private var filter = TrackerHistoryResultFilter.all
    @State private var query = ""
    @State private var page = 0
    private let pageSize = 20

    var body: some View {
        let counts = rows.reduce(into: [TrackerHistoryResultFilter: Int]()) { $0[category($1), default: 0] += 1 }
            .merging([.all: rows.count, .selected: selected.count], uniquingKeysWith: { _, latest in latest })
        let filtered = rows.filter { row in
            (filter == .all || (filter == .selected ? selected.contains(row.id) : category(row) == filter))
                && (query.isEmpty || title(row).localizedStandardContains(query))
        }
        let pages = max(1, (filtered.count + pageSize - 1) / pageSize)
        let visiblePage = min(page, pages - 1)

        SettingsSectionGroup("Comparison") {
            summary(counts)
                .accessibilityIdentifier("\(identifier).summary")
            if rows.count > pageSize || !selected.isEmpty || filter != .all {
                SettingsMenuRow(title: "Show", value: filter.label(count: counts[filter, default: 0])) {
                    Picker("Show", selection: $filter) {
                        ForEach(TrackerHistoryResultFilter.allCases.filter { $0 == filter || counts[$0, default: 0] > 0 }, id: \.self) {
                            $0.label(count: counts[$0, default: 0]).tag($0)
                        }
                    }
                }
                .accessibilityIdentifier("\(identifier).filter")
            }
            if rows.count > pageSize {
                SettingsInputRow("Find a title", axis: .horizontal) {
                    TextField("Title", text: $query)
                        .accessibilityIdentifier("\(identifier).search")
                }
            }
            if pages > 1 {
                SettingsMenuRow(title: "Page", value: Text("\(visiblePage + 1) of \(pages)")) {
                    Picker("Page", selection: $page) {
                        ForEach(0..<pages, id: \.self) { index in
                            Text("\(index * pageSize + 1)–\(min(filtered.count, (index + 1) * pageSize))").tag(index)
                        }
                    }
                }
                .accessibilityIdentifier("\(identifier).page")
            }
            action()
        } footer: {
            if let hint { Text(hint) }
        }
        .onChange(of: pages) { _, _ in page = min(page, pages - 1) }
        .onChange(of: filter) { _, newValue in
            page = 0
            if newValue == .selected { query = "" }
        }
        .onChange(of: query) { _, _ in page = 0 }

        SettingsSectionGroup {
            if filtered.isEmpty { Text("No results for this filter.") }
            ForEach(filtered.dropFirst(visiblePage * pageSize).prefix(pageSize)) { row in
                content(row)
            }

        }
        if pages > 1 {
            SettingsSectionGroup {
                Text("Page \(visiblePage + 1) of \(pages)")
                if visiblePage > 0 {
                    Button("Previous page") { page = visiblePage - 1 }
                        .settingsActionRow()
                        .accessibilityIdentifier("\(identifier).previous-page")
                }
                if visiblePage + 1 < pages {
                    Button("Next page") { page = visiblePage + 1 }
                        .settingsActionRow()
                        .accessibilityIdentifier("\(identifier).next-page")
                }
            }
        }
    }

    private func summary(_ counts: [TrackerHistoryResultFilter: Int]) -> Text {
        var parts = [Text]()
        if let n = counts[.ready] { parts.append(Text("\(n) ready")) }
        if let n = counts[.conflicts] { parts.append(n == 1 ? Text("1 conflict") : Text("\(n) conflicts")) }
        if let n = counts[.matches] { parts.append(Text("\(n) unchanged")) }
        if let n = counts[.unavailable] { parts.append(Text("\(n) unavailable")) }
        return parts.dropFirst().reduce(parts.first ?? Text("No results")) { Text("\($0) · \($1)") }
    }
}

struct TrackerHistoryExportSourceRows: View {
    let accounts: [TrackerHistoryImportSession.Destination]
    let libraries: [MediaLibrary]
    let loadingLibraries: Bool
    let libraryLoadFailed: Bool
    @Binding var accountID: String
    @Binding var libraryID: String
    let identifier: String

    var body: some View {
        if accounts.isEmpty {
            Text("No server users available.")
        } else {
            let account = accounts.first { $0.id == accountID }
            SettingsMenuRow(title: "Server user", value: account.map { Text("\($0.serverName) · \($0.userName)") } ?? Text("Choose")) {
                Picker("Server user", selection: $accountID) {
                    Text("Choose a server user").tag("")
                    ForEach(accounts) { Text("\($0.serverName) · \($0.userName)").tag($0.id) }
                }
            }
            .accessibilityIdentifier("\(identifier).account")
            if loadingLibraries {
                ProgressView("Loading libraries…")
            } else if account != nil, !libraries.isEmpty {
                let library = libraries.first { $0.id == libraryID }
                SettingsMenuRow(title: "Library", value: library.map { Text(verbatim: $0.title) } ?? Text("Choose")) {
                    Picker("Library", selection: $libraryID) {
                        Text("Choose a library").tag("")
                        ForEach(libraries) { Text(verbatim: $0.title).tag($0.id) }
                    }
                }
                .accessibilityIdentifier("\(identifier).library")
            } else if account != nil, !libraryLoadFailed {
                Text("No supported libraries for this server user.")
            }
        }
    }
}
#endif
