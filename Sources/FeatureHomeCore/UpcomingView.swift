#if canImport(SwiftUI)
    import SwiftUI
    import CoreModels
    import CoreUI

    public struct UpcomingView: View {
        @Bindable private var model: UpcomingFeedModel
        @Environment(\.horizontalSizeClass) private var sizeClass
        @Environment(\.themePalette) private var palette
        #if os(tvOS)
            @Environment(\.plozzNavigationContentInset) private var navigationInset
            @Environment(\.plozzTopNavigationContentInsets) private var topNavigationInsets
        #endif
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
                    #if os(tvOS)
                        HStack {
                            Text("Upcoming").font(.title.bold())
                            Spacer()
                            toolbarControls
                        }
                        .plozzActionButton(role: .secondary)
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
                #if os(tvOS)
                .padding(.leading, navigationInset)
                .padding(.top, topNavigationInsets.top)
                #else
                .navigationTitle("Upcoming")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        todayButton
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        calendarButton
                        UpcomingFilterMenu(model: model)
                    }
                }
                #endif
                .tint(palette.primaryText)
                .sheet(isPresented: $showingCalendar) {
                    UpcomingCalendar(selectedDay: $selectedDay, interval: interval)
                }
            }
        }

        private var todayButton: some View {
            Button("Today") {
                selectedDay = Calendar.current.startOfDay(for: Date())
                scrollRevision += 1
            }
            .accessibilityIdentifier("upcoming.today")
        }

        private var calendarButton: some View {
            Button("Calendar", systemImage: "calendar") {
                showingCalendar = true
            }
            .labelStyle(.iconOnly)
            .accessibilityValue(Text(selectedDay, format: .dateTime.month().day()))
            .accessibilityIdentifier("upcoming.calendar")
            .help("Calendar")
        }

        #if os(tvOS)
            private var toolbarControls: some View {
                HStack(spacing: 20) {
                    todayButton
                    calendarButton
                    UpcomingFilterMenu(model: model)
                }
            }
        #endif
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

    private struct UpcomingFilterMenu: View {
        @Bindable var model: UpcomingFeedModel

        var body: some View {
            Menu {
                Picker("Type", selection: $model.filters.mediaType) {
                    ForEach(UpcomingFilters.MediaType.allCases, id: \.self) {
                        Text($0.title).tag($0)
                    }
                }
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
            .accessibilityIdentifier("upcoming.filters")
            .help("Filters")
        }
    }

    private struct UpcomingAgenda: View {
        let releases: [UpcomingRelease]
        let selectedDay: Date
        let wide: Bool
        let hide: (UpcomingRelease) -> Void
        @Environment(\.plozzMetrics) private var metrics

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
                        Group {
                            if calendar.isDateInToday(day) {
                                Text("Today")
                            } else {
                                Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            }
                        }
                        #if os(tvOS)
                        .font(PlozzRailTitle.font(sectionHeaderFontSize: metrics.sectionHeaderFontSize))
                        #else
                        .font(PlozziOSMediaRailLayout.headingFont)
                        #endif
                        .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(groups[day] ?? []) { release in
                                UpcomingReleaseCard(release: release)
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
        #if os(iOS)
            @Environment(\.plozzCardStyle) private var cardStyle
        #endif

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
                        return statusCue(for: release)
                    },
                    onSelect: { navigate?($0) }
                )
                .browsingRow(onSeeAll)
            #elseif os(iOS)
                PlozziOSHomeRailLayout { metrics in
                    PlozziOSMediaSection(
                        title: title, artworkInset: cardStyle == .framed ? metrics.cardInset : 0,
                        reservesBrowseSpace: true, onBrowse: onSeeAll
                    ) {
                        PlozziOSMediaRailScroll {
                            ForEach(releases) { release in
                                PosterCardView(
                                    item: release.item, style: .landscape,
                                    reservesSubtitleSpace: false, statusCue: statusCue(for: release)
                                ) {
                                    navigate?(release.item)
                                }
                                .frame(width: metrics.cardSlotWidth(for: .landscape, cardStyle: cardStyle))
                            }
                        }
                    }
                }
                .environment(\.plozzCardCaptionView, .home)
            #endif
        }

        private func statusCue(for release: UpcomingRelease) -> LocalizedStringResource {
            let date = release.date.formatted(.dateTime.month(.abbreviated).day())
            if let subtitle = release.subtitle {
                return "\(date) · \(String(localized: subtitle))"
            }
            return "\(date)"
        }
    }

    private struct UpcomingReleaseCard: View {
        let release: UpcomingRelease
        @Environment(\.mediaItemNavigator) private var navigate
        @Environment(\.plozzArtworkPolicy) private var artworkPolicy
        @Environment(\.plozzMetrics) private var metrics

        var body: some View {
            #if os(tvOS)
                PosterCardView(
                    item: release.item, style: .landscape, statusCue: release.subtitle
                ) { navigate?(release.item) }
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
                            Text(verbatim: release.item.title)
                                .font(.system(size: metrics.cardTitleFontSize, weight: .semibold))
                                .lineLimit(2)
                            if let subtitle = release.subtitle {
                                Text(subtitle)
                                    .font(.system(size: metrics.cardSubtitleFontSize))
                                    .foregroundStyle(.secondary)
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
