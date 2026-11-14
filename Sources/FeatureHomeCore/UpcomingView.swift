#if canImport(SwiftUI)
    import SwiftUI
    import CoreModels
    import CoreUI

    public struct UpcomingView: View {
        @Bindable private var model: UpcomingFeedModel
        @Environment(\.horizontalSizeClass) private var sizeClass
        @State private var selectedDay = Calendar.current.startOfDay(for: Date())
        @State private var showingCalendar = false
        @State private var didScrollInitially = false
        @State private var scrollRevision = 0
        private let interval: DateInterval

        public init(model: UpcomingFeedModel, interval: DateInterval) {
            self.model = model
            self.interval = interval
        }

        public var body: some View {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 20) {
                    UpcomingToolbar(
                        model: model, selectedDay: $selectedDay,
                        showingCalendar: $showingCalendar,
                        onToday: {
                            selectedDay = Calendar.current.startOfDay(for: Date())
                            scrollRevision += 1
                        }
                    )
                    #if os(tvOS)
                        .focusSection()
                    #endif
                    ScrollView {
                        UpcomingFeedStatus(model: model)
                        UpcomingAgenda(
                            releases: model.visibleReleases, selectedDay: selectedDay,
                            wide: sizeClass == .regular, hide: model.hide
                        )
                        .padding(.vertical)
                    }
                    .onChange(of: selectedDay) { _, day in
                        proxy.scrollTo(day, anchor: .top)
                    }
                    .onChange(of: scrollRevision) { _, _ in
                        proxy.scrollTo(selectedDay, anchor: .top)
                    }
                    .task(id: model.releases.isEmpty) {
                        if !model.releases.isEmpty, !didScrollInitially {
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            didScrollInitially = true
                            proxy.scrollTo(selectedDay, anchor: .top)
                        }
                    }
                    if model.lastHiddenTitle != nil {
                        Button("Undo hide", action: model.undoHide)
                    }
                }
                .padding(.horizontal)
                .navigationTitle("Upcoming")
                .onAppear { model.refreshRevision += 1 }
                .sheet(isPresented: $showingCalendar) {
                    UpcomingCalendar(selectedDay: $selectedDay, interval: interval)
                }
            }
        }
    }

    private struct UpcomingFeedStatus: View {
        let model: UpcomingFeedModel

        var body: some View {
            if model.isLoading {
                ProgressView("Updating releases")
            } else if model.failedSourceCount > 0 {
                HStack {
                    Text("Some sources couldn't refresh.").foregroundStyle(.secondary)
                    Button("Retry") { model.refreshRevision += 1 }
                }
            } else if model.visibleReleases.isEmpty {
                ContentUnavailableView(
                    "No announced releases", systemImage: "calendar",
                    description: Text(
                        "Upcoming episodes from shows you've watched and movies you've saved or requested appear here.")
                )
            }
        }
    }

    private struct UpcomingToolbar: View {
        @Bindable var model: UpcomingFeedModel
        @Binding var selectedDay: Date
        @Binding var showingCalendar: Bool
        let onToday: () -> Void
        @Environment(\.horizontalSizeClass) private var sizeClass
        @Environment(\.dynamicTypeSize) private var dynamicType

        var body: some View {
            let layout =
                sizeClass == .compact || dynamicType.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 20))
            layout {
                HStack {
                    Button("Today", action: onToday)
                        .accessibilityIdentifier("upcoming.today")
                    Button {
                        showingCalendar = true
                    } label: {
                        Label {
                            Text(selectedDay, format: .dateTime.month(.abbreviated).day())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                    }
                    .accessibilityIdentifier("upcoming.calendar")
                    Spacer(minLength: 0)
                    UpcomingFilterMenu(model: model)
                }
                Picker("Type", selection: $model.filters.mediaType) {
                    ForEach(UpcomingFilters.MediaType.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private struct UpcomingFilterMenu: View {
        @Bindable var model: UpcomingFeedModel

        var body: some View {
            Menu {
                Section("Interests") {
                    ForEach(UpcomingInterest.allCases, id: \.self) { interest in
                        Toggle(
                            interest.title,
                            isOn: Binding(
                                get: { model.filters.interests.contains(interest) },
                                set: { enabled in
                                    if enabled {
                                        model.filters.interests.insert(interest)
                                    } else {
                                        model.filters.interests.remove(interest)
                                    }
                                }
                            ))
                    }
                }
                Section("Movie releases") {
                    ForEach(UpcomingReleaseKind.allCases.filter { $0 != .episode }, id: \.self) { kind in
                        Toggle(
                            kind.title,
                            isOn: Binding(
                                get: { model.filters.releaseKinds.contains(kind) },
                                set: { enabled in
                                    if enabled {
                                        model.filters.releaseKinds.insert(kind)
                                    } else {
                                        model.filters.releaseKinds.remove(kind)
                                    }
                                }
                            ))
                    }
                }
                Toggle("Season premieres only", isOn: $model.filters.premieresOnly)
                Toggle("Hide watched movies", isOn: $model.filters.hideWatchedMovies)
                Button("Reset filters") { model.filters = UpcomingFilters() }
                if !model.hiddenTitles.isEmpty {
                    Button("Restore hidden titles", action: model.restoreHiddenTitles)
                }
                Button("Refresh") { model.refreshRevision += 1 }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            }
        }
    }

    private struct UpcomingAgenda: View {
        let releases: [UpcomingRelease]
        let selectedDay: Date
        let wide: Bool
        let hide: (UpcomingRelease) -> Void

        var body: some View {
            let calendar = Calendar.current
            let groups = Dictionary(grouping: releases) { calendar.startOfDay(for: $0.date) }
            let days = Set(groups.keys).union([selectedDay]).sorted()
            #if os(tvOS)
                let visibleDays = days.filter { $0 >= selectedDay }
                let columns = Array(repeating: GridItem(.flexible(), spacing: 28), count: 3)
            #else
                let visibleDays = days
                let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: wide ? 2 : 1)
            #endif
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(visibleDays, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        if calendar.isDateInToday(day) {
                            Text("Today").font(.title2.bold())
                        } else {
                            Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                                .font(.title2.bold())
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(groups[day] ?? []) { release in
                                UpcomingReleaseCard(release: release, showsDate: false)
                                    .contextMenu { Button("Hide title") { hide(release) } }
                            }
                        }
                    }
                    .id(day)
                }
            }
        }
    }

    public struct UpcomingHomeRow: View {
        public let title: Text
        public let releases: [UpcomingRelease]
        public let onSeeAll: () -> Void
        private let onFocusEntered: (() -> Void)?
        private let onFocusChange: ((MediaItem?) -> Void)?
        private let onCardFocused: ((MediaItem) -> Void)?
        @Environment(\.mediaItemNavigator) private var navigate

        public init(
            title: Text = Text("Coming Soon"),
            releases: [UpcomingRelease],
            onFocusEntered: (() -> Void)? = nil,
            onFocusChange: ((MediaItem?) -> Void)? = nil,
            onCardFocused: ((MediaItem) -> Void)? = nil,
            onSeeAll: @escaping () -> Void
        ) {
            self.title = title
            self.releases = releases
            self.onSeeAll = onSeeAll
            self.onFocusEntered = onFocusEntered
            self.onFocusChange = onFocusChange
            self.onCardFocused = onCardFocused
        }

        public var body: some View {
            #if os(tvOS)
                MediaRowView(
                    title: title, items: releases.map(\.item), style: .landscape,
                    leadingInset: 0, onFocusEntered: onFocusEntered,
                    onFocusChange: onFocusChange, onCardFocused: onCardFocused,
                    statusCue: { item in
                        guard
                            let release = releases.first(where: {
                                $0.item.stablePresentationID == item.stablePresentationID
                            })
                        else { return nil }
                        let date = release.date.formatted(.dateTime.month(.abbreviated).day())
                        return "\(date) · \(String(localized: release.subtitle))"
                    },
                    onSelect: { navigate?($0) }
                )
                .browsingRow(onSeeAll)
            #else
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        title.font(.title2.bold())
                        Spacer()
                        Button("See All", action: onSeeAll)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 20) {
                            ForEach(releases) { release in
                                UpcomingReleaseCard(release: release, showsDate: true)
                                    #if os(tvOS)
                                        .frame(width: 360)
                                    #else
                                        .frame(width: 280)
                                    #endif
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollClipDisabled()
                }
            #endif
        }
    }

    private struct UpcomingReleaseCard: View {
        let release: UpcomingRelease
        let showsDate: Bool
        @Environment(\.mediaItemNavigator) private var navigate
        @Environment(\.plozzArtworkPolicy) private var artworkPolicy

        var body: some View {
            #if os(tvOS)
                VStack(alignment: .leading, spacing: 8) {
                    PosterCardView(
                        item: release.item, style: .landscape, statusCue: release.subtitle
                    ) { navigate?(release.item) }
                    if showsDate {
                        Text(release.date, format: .dateTime.month(.abbreviated).day()).font(.caption)
                    }
                }
            #else
                Button {
                    navigate?(release.item)
                } label: {
                    HStack(spacing: 12) {
                        let artwork = MediaArtworkSource(
                            item: release.item, placement: .poster, policy: artworkPolicy
                        )
                        FallbackAsyncImage(
                            references: artwork.references, variant: .posterCard,
                            artworkPolicy: artwork.policy, asyncFallbackURL: artwork.fallbackURL
                        ) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(.quaternary)
                        }
                        .frame(width: 64, height: 96)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: release.item.title).font(.headline).lineLimit(2)
                            Text(release.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            if showsDate {
                                Text(release.date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            #endif
        }
    }

    private struct UpcomingCalendar: View {
        @Binding var selectedDay: Date
        let interval: DateInterval
        @Environment(\.dismiss) private var dismiss
        @State private var month: Date = Date()

        var body: some View {
            #if os(tvOS)
                let calendar = Calendar.current
                let start = calendar.dateInterval(of: .month, for: month)!.start
                let dayCount = calendar.range(of: .day, in: .month, for: month)!.count
                let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
                VStack(spacing: 24) {
                    HStack {
                        Button("Previous month", systemImage: "chevron.left") {
                            month = calendar.date(byAdding: .month, value: -1, to: month)!
                        }
                        .labelStyle(.iconOnly)
                        .disabled(start <= interval.start)
                        Text(month, format: .dateTime.month(.wide).year()).font(.title)
                        Button("Next month", systemImage: "chevron.right") {
                            month = calendar.date(byAdding: .month, value: 1, to: month)!
                        }
                        .labelStyle(.iconOnly)
                        .disabled(calendar.date(byAdding: .month, value: 1, to: start)! >= interval.end)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                        ForEach(0..<7, id: \.self) { index in
                            Text(
                                verbatim: calendar.shortStandaloneWeekdaySymbols[
                                    (calendar.firstWeekday - 1 + index) % 7]
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 60) }
                        ForEach(0..<dayCount, id: \.self) { index in
                            let day = calendar.date(byAdding: .day, value: index, to: start)!
                            Button {
                                selectedDay = day
                                dismiss()
                            } label: {
                                Text(day, format: .dateTime.day()).frame(maxWidth: .infinity)
                            }
                            .overlay(alignment: .bottom) {
                                if calendar.isDate(day, inSameDayAs: selectedDay) {
                                    Circle().frame(width: 8, height: 8).allowsHitTesting(false)
                                }
                            }
                            .disabled(day < interval.start || day >= interval.end)
                            .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: selectedDay) ? .isSelected : [])
                            .accessibilityLabel(Text(day, format: .dateTime.weekday().month().day()))
                        }
                    }
                    Button("Cancel") { dismiss() }
                }
                .padding(48)
                .frame(maxWidth: 850)
                .onAppear { month = selectedDay }
            #else
                NavigationStack {
                    DatePicker(
                        "Date", selection: $selectedDay,
                        in: interval.start...interval.end.addingTimeInterval(-1),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .padding()
                    .navigationTitle("Calendar")
                    .toolbar { Button("Done") { dismiss() } }
                }
                .presentationDetents([.medium, .large])
            #endif
        }
    }
#endif
