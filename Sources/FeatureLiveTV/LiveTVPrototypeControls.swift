import CoreUI
import CoreModels
import FeatureLiveTVCore
import SwiftUI

struct PrototypeBrowseToolbar: View {
    @Bindable var model: LiveTVPrototypeModel
    @Binding var active: Bool
    let focusRequest: Int
    let compact: Bool
    var isSearching = false
    let search: () -> Void
    let filters: () -> Void
    var multiviews: (() -> Void)?
    @FocusState private var focused: Control?
    @Environment(\.themePalette) private var palette

    private enum Control: Hashable { case search, filters }

    var body: some View {
        HStack(spacing: PrototypeLayout.gap) {
            HStack(spacing: PrototypeLayout.smallGap) {
                Button(action: search) {
                    Label(isSearching ? "Back to guide" : "Search", systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                        .labelStyle(PrototypeToolbarLabelStyle(compact: compact))
                        .padding(.horizontal, compact ? 12 : Self.labelPadding)
                        .frame(minWidth: Self.controlHeight, minHeight: Self.controlHeight)
                }
                .focused($focused, equals: .search)
                .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
                .accessibilityValue(model.query)
                .accessibilityIdentifier("live-tv-search")
                #if os(iOS)
                // Touch picks a category in one step; the rest of the filters
                // stay one item away rather than fronting every choice.
                Menu {
                    Picker("Category", selection: $model.category) {
                        Text("All categories").tag(String?.none)
                        ForEach(model.categories, id: \.self) { category in
                            Text(category).tag(Optional(category))
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("More filters", systemImage: "line.3.horizontal.decrease", action: filters)
                } label: {
                    categoryLabel
                }
                .menuOrder(.fixed)
                .buttonStyle(PrototypeButtonStyle(selected: hasActiveFilters, padded: false, surface: .control))
                .accessibilityIdentifier("live-tv-category")
                #else
                Button(action: filters) { categoryLabel }
                    .focused($focused, equals: .filters)
                    .buttonStyle(PrototypeButtonStyle(selected: hasActiveFilters, padded: false, surface: .control))
                    .accessibilityIdentifier("live-tv-category")
                #endif
            }
            .padding(Self.controlInset)
            .background { PrototypeControlSurface() }
            if let multiviews {
                #if os(iOS)
                Button(action: multiviews) {
                    Label("Multiviews", systemImage: "rectangle.split.2x2")
                        .padding(.horizontal, Self.labelPadding)
                        .frame(minHeight: Self.controlHeight)
                }
                .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
                .padding(Self.controlInset)
                .background { PrototypeControlSurface() }
                .accessibilityIdentifier("live-tv-multiview-favorites")
                #else
                Button("Multiviews", systemImage: "rectangle.split.2x2", action: multiviews)
                    .buttonStyle(PrototypeButtonStyle(surface: .control))
                    .accessibilityIdentifier("live-tv-multiview-favorites")
                #endif
            }
            #if os(iOS)
            if compact { Spacer(minLength: 0) }
            #endif
            if !compact {
                Spacer(minLength: 0)
                Text(model.now, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.secondaryText)
            }
        }
        #if os(iOS)
        .font(.footnote.weight(.medium))
        #else
        .font(.subheadline.weight(.medium))
        #endif
        .lineLimit(1)
        .buttonStyle(PrototypeButtonStyle(padded: false, surface: .control))
        .focusEffectDisabled()
        #if os(tvOS)
        .focusSection()
        #endif
        .onChange(of: focused) { _, target in
            if target != nil { active = true }
        }
        .onChange(of: focusRequest) { _, _ in focused = .search }
    }

    private var categoryLabel: some View {
        HStack(spacing: 8) {
            if let category = model.category { Text(category) }
            else { Text("Categories") }
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, compact ? 12 : Self.labelPadding)
        .frame(minHeight: Self.controlHeight)
        #if os(tvOS)
        .frame(maxWidth: compact ? .infinity : 280)
        #endif
    }

    // Touch controls are a size down from the TV's: the guide wants the room.
    #if os(iOS)
    static let controlHeight: CGFloat = 32
    private static let labelPadding: CGFloat = 12
    private static let controlInset: CGFloat = 3
    #else
    static let controlHeight = PrototypeLayout.controlHeight
    private static let labelPadding: CGFloat = 20
    private static let controlInset = PrototypeLayout.controlInset
    #endif

    private var hasActiveFilters: Bool {
        model.category != nil || model.guideOnly || model.source != nil
            || model.language != nil || model.country != nil || model.favoritesOnly
    }
}

#if os(iOS)
/// Touch: the guide's top-row controls as a cluster of icon buttons, level
/// with the profile avatar — Search, the category filter, Multiviews, and
/// "now", which brings the timeline back to the current programme after
/// scrolling away. Icons rather than labelled pills so the row fits a phone
/// without truncating.
struct PrototypeTouchBrowseBar: View {
    @Bindable var model: LiveTVPrototypeModel
    var isSearching = false
    let search: () -> Void
    let filters: () -> Void
    var multiviews: (() -> Void)?
    let goToNow: () -> Void
    @Environment(\.themePalette) private var palette

    static let diameter: CGFloat = 40

    var body: some View {
        HStack(spacing: PrototypeLayout.smallGap) {
            Button(action: search) {
                Label(isSearching ? "Back to guide" : "Search",
                      systemImage: isSearching ? "chevron.backward" : "magnifyingglass")
                    .labelStyle(.iconOnly)
                    .circleControl(active: false, palette: palette)
            }
            .buttonStyle(.plain)
            .accessibilityValue(model.query)
            .accessibilityIdentifier("live-tv-search")

            Menu {
                Picker("Category", selection: $model.category) {
                    Text("All categories").tag(String?.none)
                    ForEach(model.categories, id: \.self) { category in
                        Text(category).tag(Optional(category))
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("More filters", systemImage: "line.3.horizontal.decrease", action: filters)
            } label: {
                Label("Categories", systemImage: hasActiveFilters
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
                    .circleControl(active: hasActiveFilters, palette: palette)
            }
            .menuOrder(.fixed)
            .accessibilityValue(Text(verbatim: model.category ?? ""))
            .accessibilityIdentifier("live-tv-category")

            if let multiviews {
                Button(action: multiviews) {
                    Label("Multiviews", systemImage: "rectangle.split.2x2")
                        .labelStyle(.iconOnly)
                        .circleControl(active: false, palette: palette)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("live-tv-multiview-favorites")
            }

            if !isSearching {
                Button(action: goToNow) {
                    Label {
                        Text("Now", comment: "Guide button that scrolls the timeline back to the programmes airing now.")
                    } icon: {
                        Image(systemName: "arrow.right.and.line.vertical.and.arrow.left")
                    }
                    .labelStyle(.iconOnly)
                    .circleControl(active: false, palette: palette)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("live-tv-guide-now")
            }
        }
        .font(.body.weight(.medium))
    }

    private var hasActiveFilters: Bool {
        model.category != nil || model.guideOnly || model.source != nil
            || model.language != nil || model.country != nil || model.favoritesOnly
    }
}

private extension View {
    func circleControl(active: Bool, palette: ThemePalette) -> some View {
        self
            .foregroundStyle(active ? palette.onAccent : palette.primaryText)
            .frame(width: PrototypeTouchBrowseBar.diameter, height: PrototypeTouchBrowseBar.diameter)
            .background {
                if active {
                    Circle().fill(palette.accent)
                } else {
                    PrototypeControlSurface().clipShape(Circle())
                }
            }
            .contentShape(Circle())
    }
}
#endif

private struct PrototypeToolbarLabelStyle: LabelStyle {
    let compact: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
            if !compact { configuration.title }
        }
    }
}

struct PrototypeSheetPresentation<SheetContent: View>: ViewModifier {
    @Binding var selection: PrototypeSheet?
    let onDismiss: () -> Void
    @ViewBuilder let sheetContent: (PrototypeSheet) -> SheetContent

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .fullScreenCover(item: binding(forManagement: true), onDismiss: onDismiss, content: sheetContent)
            .sheet(item: binding(forManagement: false), onDismiss: onDismiss, content: sheetContent)
        #else
        content.sheet(item: $selection, onDismiss: onDismiss, content: sheetContent)
        #endif
    }

    private func binding(forManagement management: Bool) -> Binding<PrototypeSheet?> {
        Binding(
            get: {
                guard let selection, selection.usesManagementPage == management else { return nil }
                return selection
            },
            set: { value in
                guard value != nil || selection?.usesManagementPage == management else { return }
                selection = value
            }
        )
    }
}

extension PrototypeSheet {
    var usesManagementPage: Bool {
        switch self {
        case .sources, .addPlaylist, .serverSetup: true
        default: false
        }
    }
}

struct PrototypeSheetContent: View {
    @Bindable var model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    let destination: PrototypeSheet
    let reload: () -> Void
    let showGuide: () -> Void
    @Binding var guideOffset: TimeInterval
    let goToNow: () -> Void
    let guideStart: Date
    let tune: (String) -> Void
    let openMultiview: (LiveTVMultiviewFavorite) -> Void
    var channelActionTitle: LocalizedStringResource?
    var sourceManagement: ((PrototypeSheet) -> AnyView)? = nil
    var openLibraryItem: ((LibraryChannelItem) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.themePalette) private var palette

    var body: some View {
        NavigationStack {
            Group {
                switch destination {
                case .multiviewFavorites:
                    LiveTVMultiviewFavoritesView(model: model, open: openMultiview)
                case .filters:
                    PrototypeFilterForm(model: model)
                        .navigationTitle("Categories")
                case .guideTime:
                    PrototypeGuideTimeForm(guideOffset: $guideOffset, goToNow: goToNow, guideStart: guideStart)
                        .navigationTitle("Guide time")
                case .sources, .addPlaylist, .serverSetup:
                    if let sourceManagement {
                        sourceManagement(destination)
                    } else {
                        PrototypeSourcesForm(model: model, imports: imports, reload: reload) {
                            showGuide()
                            dismiss()
                        }
                        .navigationTitle("Live TV sources")
                    }
                case .program(let program):
                    if let channel = model.channel(id: program.channelID),
                       imports.isProgramSearchResultAvailable(program, catalog: model) {
                        LiveTVProgramDetailsView(
                            program: program, channelName: channel.name, now: model.now,
                            guideSourceName: imports.guideSources.first {
                                $0.id == imports.selectedSourceByChannel[program.channelID]
                            }?.source.name,
                            isFavorite: model.favoriteIDs.contains(program.channelID),
                            toggleFavorite: { model.toggleFavorite(program.channelID) },
                            watchTitle: channelActionTitle ?? "Watch channel",
                            openLibraryItem: channel.source == .plozz ? openLibraryItem : nil
                        ) {
                            guard imports.isProgramSearchResultAvailable(program, catalog: model) else { return }
                            tune(program.channelID)
                            dismiss()
                        }
                    } else {
                        ContentUnavailableView(
                            "Program details unavailable", systemImage: "calendar.badge.exclamationmark",
                            description: Text("This listing is no longer available in the guide.")
                        )
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .background(palette.backgroundBase)
        }
    }
}

private struct PrototypeGuideTimeForm: View {
    @Binding var guideOffset: TimeInterval
    let goToNow: () -> Void
    let guideStart: Date
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LiveTVSettingsPage(title: "Guide time") {
            SettingsSectionGroup {
                Text(guideStart, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                Button("Earlier", systemImage: "chevron.backward") {
                    guideOffset = max(-86_400, guideOffset - 7_200)
                    dismiss()
                }
                .disabled(guideOffset <= -86_400)
                Button("Now", systemImage: "clock") {
                    goToNow()
                    dismiss()
                }
                Button("Later", systemImage: "chevron.forward") {
                    guideOffset = min(604_800, guideOffset + 7_200)
                    dismiss()
                }
                .disabled(guideOffset >= 604_800)
            }
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
    }
}

private struct PrototypeFilterForm: View {
    @Bindable var model: LiveTVPrototypeModel

    var body: some View {
        LiveTVSettingsPage(title: "Categories") {
            SettingsSectionGroup {
                PrototypeSelectionLink(
                    title: "Category", selection: $model.category,
                    options: [nil] + model.categories.map(Optional.some)
                ) { category in
                    if let category { Text(category) }
                    else { Text("All categories") }
                }
                PrototypeSelectionLink(
                    title: "Language", selection: $model.language,
                    options: [nil] + model.languages.map(Optional.some)
                ) { language in
                    if let language { Text(language) }
                    else { Text("All languages") }
                }
                PrototypeSelectionLink(
                    title: "Country", selection: $model.country,
                    options: [nil] + model.countries.map(Optional.some)
                ) { country in
                    if let country { Text(country) }
                    else { Text("All countries") }
                }
                Toggle("Favorites only", isOn: $model.favoritesOnly)
                Toggle("Channels with a guide", isOn: $model.guideOnly)
                PrototypeSelectionLink(title: "Sort", selection: $model.sort, options: LiveTVPrototypeSort.allCases) {
                    if $0 == .channelNumber { Text("Channel number") }
                    else { Text("Name") }
                }
            }
            SettingsSectionGroup {
                Button("Reset filters") { model.resetFilters() }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                Text("\(model.visibleChannels.count) matching channels")
            }
        }
        #if os(tvOS)
        .toggleStyle(SettingsSwitchToggleStyle(flushLeading: false))
        #elseif os(iOS)
        .toggleStyle(SettingsTouchSwitchToggleStyle())
        #endif
    }
}

struct PrototypeSelectionLink<Option: Hashable, OptionLabel: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Option
    let options: [Option]
    @ViewBuilder let optionLabel: (Option) -> OptionLabel

    var body: some View {
        NavigationLink {
            PrototypeSelectionList(title: title, selection: $selection, options: options, optionLabel: optionLabel)
                .navigationTitle(title)
        } label: {
            SettingsRowLabel(icon: nil, title: Text(title), trailing: {
                optionLabel(selection).settingsRowSecondary()
            })
        }
        .buttonStyle(SettingsFocusButtonStyle(size: .contained))
    }
}

struct PrototypeSelectionList<Option: Hashable, OptionLabel: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Option
    let options: [Option]
    @ViewBuilder let optionLabel: (Option) -> OptionLabel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            SettingsSectionGroup {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        HStack {
                            optionLabel(option)
                            Spacer()
                            if option == selection { SettingsSelectionIndicator() }
                        }
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    .accessibilityAddTraits(option == selection ? .isSelected : [])
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct PrototypeSourcesForm: View {
    @Bindable var model: LiveTVPrototypeModel
    let imports: LiveTVPrototypeImportModel
    let reload: () -> Void
    let showGuide: () -> Void
    @State private var selectionFailed = false

    var body: some View {
        Form {
            Section {
                ForEach(imports.playlistSources) { status in
                    Text(status.source.name).font(.headline)
                    PrototypeSourceAddress(url: status.source.playlistURL).font(.caption)
                }
                if imports.playlistSources.isEmpty, let url = imports.playlistURL {
                    Text("IPTV playlist").font(.headline)
                    PrototypeSourceAddress(url: url).font(.caption)
                }
                Text("\(imports.entryCount) playlist entries")
                Text("\(imports.skippedEntryCount) unsupported or duplicate entries skipped")
            } header: {
                Text("Channels")
            } footer: {
                Text("Stream variants can share a station name. Availability varies by channel and region.")
            }
            Section {
                Text("\(imports.matchedChannelCount) channel matches")
                Text("\(model.guideChannelCount) channels with listings · \(imports.programCount) programs")
                if let start = imports.coverageStart, let end = imports.coverageEnd {
                    Text(start..<end, format: .interval.day().month().hour().minute())
                }
                if let date = imports.lastGuideRefresh {
                    Text("Last refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                }
                Button("Show channels with guide listings", systemImage: "calendar", action: showGuide)
                    .disabled(model.guideChannelCount == 0)
            } header: {
                Text("Program guide")
            } footer: {
                Text("Each channel uses one guide. Exact channel IDs take priority; equally strong matches prefer available listings, then the source order below. Unknown channels remain watchable.")
            }
            ForEach(imports.guideSources) { status in
                Section {
                    Toggle(isOn: Binding(
                        get: { imports.enabledSourceIDs.contains(status.id) },
                        set: { enabled in
                            do {
                                try imports.setSourceEnabled(status.id, enabled: enabled, into: model)
                                reload()
                            } catch {
                                selectionFailed = true
                            }
                        }
                    )) {
                        Text(status.source.name).font(.headline)
                    }
                    .accessibilityIdentifier("live-tv-guide-source-\(status.id)")
                    PrototypeSourceAddress(url: status.source.url).font(.caption)
                    PrototypeGuideSourceStatus(
                        status: status, enabled: imports.enabledSourceIDs.contains(status.id)
                    )
                }
            }
            Section {
                PrototypeImportStatus(imports: imports, listedChannels: model.guideChannelCount)
                if imports.playlistPhase == .failed {
                    if let failure = imports.playlistFailure { Text(failure.userDescription) }
                    Text("The playlist could not be loaded. Check your connection and retry. Any previously loaded channels remain available.")
                }
                if imports.guidePhase == .failed {
                    if let failure = imports.guideFailure { Text(failure.userDescription) }
                    Text("The guide could not be loaded or parsed. Retry later; this does not prevent watching channels.")
                }
                Button("Reload sources", systemImage: "arrow.clockwise", action: reload)
                    .disabled(imports.isLoading)
            }
            #if DEBUG
            Section {
                Toggle("5,000 rows for scrolling", isOn: $model.isLargeCatalog)
            } header: {
                Text("Browse testing")
            } footer: {
                Text("Repeats the imported channels into labeled copies; it does not add stations. Favorites and recently watched channels are saved separately for each profile.")
            }
            Section {
                Text("Channel history is separate from movie and episode progress. Jellyfin and Emby can play channels from a configured Live TV server. Plex currently supports channels and guide listings, not playback.")
            }
            #endif
        }
        .alert("Guide selection could not be applied", isPresented: $selectionFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Reload the sources and try again. Your channels remain available.")
        }
    }
}

struct PrototypeSourceAddress: View {
    let url: URL

    var body: some View {
        if let host = url.host {
            Text(host).privacySensitive()
        } else {
            Text("Source address unavailable")
        }
    }
}

struct PrototypeGuideSourceStatus: View {
    let status: LiveTVGuideSourceStatus
    let enabled: Bool

    var body: some View {
        if !enabled {
            Text("Disabled")
        } else {
            switch status.phase {
            case .idle:
                Text("Waiting to load")
            case .loading:
                Label("Loading guide", systemImage: "arrow.down.circle")
            case .loaded:
                Text("\(status.matchedChannelCount) channel matches · \(status.programCount) programs")
            case .failed:
                if let failure = status.failure { Text(failure.userDescription) }
                if status.lastRefresh != nil { Text("Keeping previously loaded listings") }
            }
            if let date = status.lastRefresh {
                Text("Last refreshed: \(date, format: .dateTime.month().day().hour().minute())")
                    .font(.caption)
            }
        }
    }
}
