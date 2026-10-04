import SwiftUI
import CoreModels

public struct LibraryFilterMenu: View {
    let filters: LibraryFilters
    let capabilities: LibraryQueryCapabilities
    let facets: LibraryQueryFacets
    let isLoading: Bool
    let hasError: Bool
    let onChange: (LibraryFilters) -> Void
    let onLoadFacets: () async -> Void
    let onRetry: () -> Void
    @Environment(\.locale) private var locale

    public init(
        filters: LibraryFilters, capabilities: LibraryQueryCapabilities, facets: LibraryQueryFacets,
        isLoading: Bool, hasError: Bool, onChange: @escaping (LibraryFilters) -> Void,
        onLoadFacets: @escaping () async -> Void, onRetry: @escaping () -> Void
    ) {
        self.filters = filters
        self.capabilities = capabilities
        self.facets = facets
        self.isLoading = isLoading
        self.hasError = hasError
        self.onChange = onChange
        self.onLoadFacets = onLoadFacets
        self.onRetry = onRetry
    }

    public var body: some View {
        Menu {
            Picker("Filter", selection: binding(\.filter)) {
                ForEach(capabilities.filters, id: \.self) { filter in
                    switch filter.displayName {
                    case .localized(let name): Text(name).tag(filter)
                    case .format(let name): Text(verbatim: name).tag(filter)
                    }
                }
            }
            Divider()
            if capabilities.supportsGenres {
                Menu("Genre") {
                    Picker("Genre", selection: binding(\.genre)) {
                        Text("All Genres").tag(String?.none)
                        ForEach(facets.genres, id: \.self) { genre in Text(verbatim: genre).tag(Optional(genre)) }
                    }
                }
            }
            if capabilities.supportsYears {
                Menu("Year") {
                    Picker("Year", selection: binding(\.year)) {
                        Text("All Years").tag(Int?.none)
                        ForEach(facets.years, id: \.self) { year in Text(verbatim: String(year)).tag(Optional(year)) }
                    }
                }
            }
            if isLoading { Text("Loading filters…") }
            if hasError { Button("Couldn't load filter options. Try Again", action: onRetry) }
            if !filters.isEmpty { Button("Clear Filters") { onChange(.all) } }
        } label: {
            if filters.isEmpty {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
            } else {
                ViewThatFits(in: .horizontal) {
                    Label("Filter: \(filters.summary(in: locale))", systemImage: "line.3.horizontal.decrease")
                        .fixedSize()
                    Label("Filter: \(filters.activeCount)", systemImage: "line.3.horizontal.decrease")
                        .fixedSize()
                }
                .accessibilityLabel(Text("Filter: \(filters.summary(in: locale))"))
            }
        }
        .accessibilityIdentifier("library-filter-menu")
        .task { await onLoadFacets() }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LibraryFilters, Value>) -> Binding<Value> {
        Binding(
            get: { filters[keyPath: keyPath] },
            set: { value in
                var copy = filters
                copy[keyPath: keyPath] = value
                onChange(copy)
            }
        )
    }
}

public struct LibraryQueryPreparationView: View {
    let progress: Double
    let onCancel: () -> Void

    public init(progress: Double, onCancel: @escaping () -> Void) {
        self.progress = progress
        self.onCancel = onCancel
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    Text("Preparing library filter…")
                        .padding(.bottom, 20)
                        .frame(height: geometry.size.height / 2, alignment: .bottom)
                    VStack(spacing: 20) {
                        Text("Preparing the selected option without changing your library. Results are cached while you browse.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        Button("Cancel", action: onCancel)
                    }
                    .padding(.top, 20)
                    .frame(height: geometry.size.height / 2, alignment: .top)
                }
                ProgressView(value: progress)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("library-query-progress")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding()
        .accessibilityIdentifier("library-query-preparation")
    }
}
