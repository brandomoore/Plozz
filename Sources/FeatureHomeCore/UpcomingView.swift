#if canImport(SwiftUI)
    import SwiftUI
    import CoreModels
    import CoreUI

    public struct UpcomingView<TrailingToolbar: ToolbarContent>: View {
        @Bindable private var model: UpcomingFeedModel
        @Environment(\.themePalette) private var palette
        @Environment(\.plozzMetrics) private var metrics
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var agendaSize = CGSize.zero
        @State private var dateScrollRequest: UUID?
        #if os(tvOS)
            @Environment(\.plozzNavigationContentInset) private var navigationInset
            @Environment(\.plozzTopNavigationContentInsets) private var topNavigationInsets
            @State private var didChooseCalendarDate = false
        #elseif os(iOS)
            @Environment(\.horizontalSizeClass) private var sizeClass
            @Environment(\.plozzCardStyle) private var cardStyle
            @State private var availableSize = CGSize.zero
            @State private var calendarIsMinimized = false
            @State private var scrollPosition = ScrollPosition(
                id: Calendar.current.startOfDay(for: Date()), anchor: .top
            )
            @State private var hasScrolledAgenda = false
            @State private var todayDetent = UpcomingScrollDetent()
        #endif
        @State private var selectedDay = Calendar.current.startOfDay(for: Date())
        @State private var showingCalendar = false
        @State private var didScrollInitially = false
        private let interval: DateInterval
        private let trailingToolbar: TrailingToolbar

        public init(
            model: UpcomingFeedModel, interval: DateInterval,
            @ToolbarContentBuilder trailingToolbar: () -> TrailingToolbar
        ) {
            self.model = model
            self.interval = interval
            self.trailingToolbar = trailingToolbar()
        }

        public init(model: UpcomingFeedModel, interval: DateInterval)
        where TrailingToolbar == ToolbarItemGroup<EmptyView> {
            self.model = model
            self.interval = interval
            // EmptyView itself only conforms to ToolbarContent on OS 27 and later.
            self.trailingToolbar = ToolbarItemGroup(placement: .topBarTrailing) { EmptyView() }
        }

        public var body: some View {
            let visibleReleases = upcomingAgendaReleases(model.visibleReleases)
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 20) {
                    #if os(tvOS)
                        HStack {
                            Text("Upcoming").font(.title.bold())
                            Spacer()
                            toolbarControls
                        }
                        .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                        .plozzActionButton(role: .secondary)
                        .focusSection()
                        .navigationEntryFocus(.fallback)
                    #endif
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            UpcomingAgenda(
                                model: model, selectedDay: selectedDay,
                                minimumLastDayHeight: agendaHeight, contentWidth: agendaContentWidth
                            )
                            #if os(iOS)
                            .environment(\.plozzMetrics, agendaMetrics)
                            .environment(\.upcomingScrollDetent, todayDetent)
                            .background {
                                UpcomingScrollProbe(
                                    detent: todayDetent, role: .container, reduceMotion: reduceMotion,
                                    onScrollToToday: {
                                        requestDateScroll(to: Calendar.current.startOfDay(for: Date()))
                                    }
                                )
                            }
                            #endif
                            .opacity(visibleReleases.isEmpty ? 0 : 1)
                            .accessibilityHidden(visibleReleases.isEmpty)
                            #if os(tvOS)
                            .padding(.vertical)
                            .padding(.horizontal, PlozzTheme.Metrics.screenPadding + metrics.railShadowClearance)
                            #endif
                        }
                        .overlay {
                            if visibleReleases.isEmpty {
                                UpcomingFeedStatus(model: model)
                                    .padding()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        #if os(iOS)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { agendaSize = $0 }
                        .contentMargins(.horizontal, agendaInset, for: .scrollContent)
                        .contentMargins(.vertical, 16, for: .scrollContent)
                        .scrollPosition($scrollPosition, anchor: .top)
                        .scrollTargetBehavior(UpcomingScrollTargetBehavior(state: todayDetent.targetState))
                        .onScrollPhaseChange { _, newPhase in
                            if newPhase == .interacting {
                                hasScrolledAgenda = true
                                dateScrollRequest = nil
                                scrollPosition.isPositionedByUser = true
                            }
                            todayDetent.phaseChanged(to: newPhase)
                        }
                        .modifier(UpcomingScrollEdge())
                        .task(id: agendaSize.width) {
                            guard agendaSize.width > 0, !hasScrolledAgenda, dateScrollRequest == nil else { return }
                            await Task.yield()
                            guard !Task.isCancelled, !hasScrolledAgenda, dateScrollRequest == nil else { return }
                            scrollPosition.scrollTo(id: selectedDay, anchor: .top)
                        }
                        .task(id: dateScrollRequest) {
                            guard let request = dateScrollRequest else { return }
                            // Mount empty date targets before issuing the animated command.
                            await Task.yield()
                            guard !Task.isCancelled, dateScrollRequest == request, !hasScrolledAgenda else { return }
                            todayDetent.scrollToDate {
                                scrollPosition.scrollTo(id: selectedDay, anchor: .top)
                            }
                        }
                        #else
                        .frame(maxWidth: .infinity)
                        .navigationEntryFocus(model.isLoading && visibleReleases.isEmpty ? .pending : nil)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { agendaSize = $0 }
                        // Reserve focus lift inside the scroll clip without moving the row keyline.
                        .padding(.horizontal, -metrics.railShadowClearance)
                        .task(id: dateScrollRequest) {
                            guard let request = dateScrollRequest else { return }
                            await Task.yield()
                            guard !Task.isCancelled, dateScrollRequest == request else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                proxy.scrollTo(selectedDay, anchor: .top)
                            }
                        }
                        .task(id: visibleReleases.isEmpty) {
                            if !visibleReleases.isEmpty, !didScrollInitially {
                                await Task.yield()
                                guard !Task.isCancelled else { return }
                                didScrollInitially = true
                                proxy.scrollTo(selectedDay, anchor: .top)
                            }
                        }
                        #endif
                        #if os(iOS)
                        if showsInlineCalendar {
                            UpcomingCalendar(
                                selectedDay: calendarSelection, interval: interval, dismissesOnSelection: false
                            )
                            .transition(.opacity)
                        }
                        #endif
                    }
                    if model.lastHiddenTitle != nil {
                        Button("Undo hide", action: model.undoHide)
                            #if os(tvOS)
                            .padding(.horizontal, PlozzTheme.Metrics.screenPadding)
                            #endif
                    }
                }
                #if os(tvOS)
                .padding(.leading, navigationInset)
                .padding(.top, topNavigationInsets.top)
                #else
                .navigationTitle(Text(verbatim: ""))
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        calendarButton
                        UpcomingFilterMenu(model: model)
                    }
                    trailingToolbar
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { availableSize = $0 }
                .onChange(of: supportsInlineCalendar) { _, supported in
                    if supported { showingCalendar = false }
                }
                #endif
                .tint(palette.primaryText)
                .onAppear { model.refreshIfStale() }
                #if os(tvOS)
                .sheet(isPresented: $showingCalendar, onDismiss: {
                    if didChooseCalendarDate {
                        didChooseCalendarDate = false
                        dateScrollRequest = UUID()
                    }
                }) {
                    UpcomingCalendar(selectedDay: Binding(
                        get: { selectedDay },
                        set: {
                            selectedDay = Calendar.current.startOfDay(for: $0)
                            didChooseCalendarDate = true
                        }
                    ), interval: DateInterval(
                        start: min(interval.end, max(interval.start, Calendar.current.startOfDay(for: Date()))),
                        end: interval.end
                    ))
                }
                #endif
            }
        }

        private var calendarButton: some View {
            Button("Calendar", systemImage: "calendar") {
                #if os(iOS)
                if supportsInlineCalendar {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        calendarIsMinimized.toggle()
                    }
                } else {
                    showingCalendar = true
                }
                #else
                showingCalendar = true
                #endif
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel(calendarActionTitle)
            .accessibilityValue(Text(selectedDay, format: .dateTime.month().day()))
            .accessibilityIdentifier("upcoming.calendar")
            .help(calendarActionTitle)
            #if os(iOS)
            .accessibilityAddTraits(showsInlineCalendar ? .isSelected : [])
            .popover(isPresented: $showingCalendar) {
                UpcomingCalendar(selectedDay: calendarSelection, interval: interval)
                    .presentationCompactAdaptation(.popover)
            }
            #endif
        }

        private var agendaHeight: CGFloat {
            max(0, agendaSize.height - 32)
        }

        private var agendaContentWidth: CGFloat {
            #if os(iOS)
            max(0, agendaSize.width - 2 * agendaInset)
            #else
            max(0, agendaSize.width - 2 * (PlozzTheme.Metrics.screenPadding + metrics.railShadowClearance))
            #endif
        }

        #if os(iOS)
        private var calendarSelection: Binding<Date> {
            Binding(
                get: { selectedDay },
                set: {
                    requestDateScroll(to: $0)
                    showingCalendar = false
                }
            )
        }

        private func requestDateScroll(to day: Date) {
            todayDetent.prepareForDateScroll()
            scrollPosition.isPositionedByUser = true
            selectedDay = Calendar.current.startOfDay(for: day)
            hasScrolledAgenda = false
            dateScrollRequest = UUID()
        }

        private var agendaMetrics: PlozzMetrics {
            guard sizeClass == .compact else { return metrics }
            return PlozziOSHomeRailLayout<EmptyView>.posterMetrics(
                in: agendaSize.width,
                inset: PlozziOSMediaRailLayout.pageInset(for: sizeClass, usesDesktopSizing: metrics.usesDesktopSizing),
                metrics: metrics, cardStyle: cardStyle
            )
        }

        private var agendaInset: CGFloat {
            PlozziOSMediaRailLayout.artworkAlignedInset(
                PlozziOSMediaRailLayout.pageInset(for: sizeClass, usesDesktopSizing: metrics.usesDesktopSizing),
                metrics: metrics, cardStyle: cardStyle
            )
        }
        #endif

        private var calendarActionTitle: Text {
            #if os(iOS)
            if supportsInlineCalendar {
                return showsInlineCalendar ? Text("Hide calendar") : Text("Show calendar")
            }
            #endif
            return Text("Calendar")
        }

        #if os(iOS)
            private var supportsInlineCalendar: Bool {
                sizeClass == .regular && availableSize.width >= 800 && availableSize.height >= 500
            }

            private var showsInlineCalendar: Bool {
                supportsInlineCalendar && !calendarIsMinimized
            }

            private struct UpcomingScrollEdge: ViewModifier {
                func body(content: Content) -> some View {
                    if #available(iOS 26.0, *) {
                        content.scrollEdgeEffectStyle(.soft, for: .top)
                    } else {
                        content
                    }
                }
            }
        #endif

        #if os(tvOS)
            private var toolbarControls: some View {
                HStack(spacing: 20) {
                    calendarButton
                    UpcomingFilterMenu(model: model)
                }
            }
        #endif
    }

    private func upcomingAgendaReleases(_ releases: [UpcomingRelease]) -> [UpcomingRelease] {
        #if os(tvOS)
        let today = Calendar.current.startOfDay(for: Date())
        return releases.filter { $0.date >= today }
        #else
        return releases
        #endif
    }

    private struct UpcomingFeedStatus: View {
        let model: UpcomingFeedModel
        @Environment(\.plozzSeerConnected) private var seerConnected

        var body: some View {
            let releases = upcomingAgendaReleases(model.releases)
            let visibleReleases = upcomingAgendaReleases(model.visibleReleases)
            if model.isLoading {
                ProgressView("Updating releases")
            } else if releases.isEmpty, model.failedSourceCount > 0 {
                ContentUnavailableView {
                    Label("Couldn't load releases", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("Retry") { model.refreshRevision += 1 }
                        .accessibilityIdentifier("upcoming.retry")
                }
                .plozzActionButton(role: .secondary)
            } else if !releases.isEmpty, visibleReleases.isEmpty {
                ContentUnavailableView {
                    Label("No matching releases", systemImage: "line.3.horizontal.decrease")
                } actions: {
                    if model.filters != UpcomingFilters() {
                        Button("Reset filters") { model.filters = UpcomingFilters() }
                            .accessibilityIdentifier("upcoming.resetFilters")
                    }
                    if !model.hiddenTitles.isEmpty {
                        Button("Restore hidden titles", action: model.restoreHiddenTitles)
                            .accessibilityIdentifier("upcoming.restoreHidden")
                    }
                }
                .plozzActionButton(role: .secondary)
            } else if model.failedSourceCount > 0 {
                HStack {
                    Text("Some sources couldn't refresh.").foregroundStyle(.secondary)
                    Button("Retry") { model.refreshRevision += 1 }
                }
            } else if visibleReleases.isEmpty {
                ContentUnavailableView(
                    "Nothing upcoming yet", systemImage: "calendar",
                    description: seerConnected
                        ? Text("Shows and movies you watch, watchlist, or request appear here.")
                        : Text("Shows and movies you watch or watchlist appear here.")
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
                Section {
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

    struct UpcomingAgenda: View {
        let model: UpcomingFeedModel
        let selectedDay: Date
        let minimumLastDayHeight: CGFloat
        let contentWidth: CGFloat
        @Environment(\.plozzMetrics) private var metrics
        @Environment(\.plozzCardStyle) private var cardStyle

        var body: some View {
            let calendar = Calendar.current
            let groups = Dictionary(grouping: upcomingAgendaReleases(model.visibleReleases)) { calendar.startOfDay(for: $0.date) }
            #if os(iOS)
                let days = Set(groups.keys).union([selectedDay, calendar.startOfDay(for: Date())]).sorted()
            #else
                let days = Set(groups.keys).union([selectedDay]).sorted()
            #endif
            #if os(tvOS)
                let visibleDays = days.filter { $0 >= calendar.startOfDay(for: Date()) }
                let spacing = metrics.cardSpacing
                let gridMetrics = metrics
                let width = metrics.portraitRowSlotWidth(
                    viewportWidth: contentWidth, leadingInset: 0, cardStyle: cardStyle
                )
                let columns = [GridItem(.adaptive(minimum: width, maximum: width), spacing: spacing, alignment: .topLeading)]
            #else
                let visibleDays = days
                let layout = PlozziOSPosterGridLayout(contentWidth: contentWidth, metrics: metrics, cardStyle: cardStyle)
                let gridMetrics = layout.metrics
                let width = gridMetrics.cardSlotWidth(for: .poster, cardStyle: cardStyle)
                let columns = Array(
                    repeating: GridItem(.fixed(width), spacing: layout.spacing, alignment: .topLeading),
                    count: layout.columns
                )
            #endif
            #if os(iOS)
            VStack(alignment: .leading, spacing: 28) {
                dateGroups(visibleDays, groups: groups, columns: columns, metrics: gridMetrics, width: width)
                refreshError
            }
            .frame(width: contentWidth > 0 ? contentWidth : nil, alignment: .leading)
            #else
            VStack(alignment: .leading, spacing: 20) {
                dateGroups(visibleDays, groups: groups, columns: columns, metrics: gridMetrics, width: width)
                refreshError
            }
            #endif
        }

        @ViewBuilder
        private var refreshError: some View {
            if !model.isLoading, model.failedSourceCount > 0 {
                UpcomingFeedStatus(model: model).frame(maxWidth: .infinity)
            }
        }

        @ViewBuilder
        private func dateGroups(
            _ days: [Date], groups: [Date: [UpcomingRelease]],
            columns: [GridItem], metrics: PlozzMetrics, width: CGFloat
        ) -> some View {
            #if os(iOS)
            // Date targets must stay mounted when scrolling through history.
            // The poster grids still create their rows lazily.
            VStack(alignment: .leading, spacing: 28) {
                dateGroupContent(days, groups: groups, columns: columns, metrics: metrics, width: width)
            }
            .scrollTargetLayout()
            #else
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                dateGroupContent(days, groups: groups, columns: columns, metrics: metrics, width: width)
            }
            #endif
        }

        private func dateGroupContent(
            _ days: [Date], groups: [Date: [UpcomingRelease]],
            columns: [GridItem], metrics: PlozzMetrics, width: CGFloat
        ) -> some View {
            ForEach(days, id: \.self) { day in
                Group {
                    #if os(tvOS)
                    MediaRowSection(title: dayTitle(day), leadingInset: 0) {
                        if let releases = groups[day], !releases.isEmpty {
                            releaseGrid(releases, columns: columns, metrics: metrics, width: width)
                                .padding(.leading, metrics.cardRowLeadingPadding(0, cardStyle: cardStyle))
                                .padding(.top, metrics.railTopPadding)
                                .padding(.bottom, metrics.railVerticalPadding)
                        }
                    }
                    .environment(\.plozzNavigationContentInset, 0)
                    .environment(\.plozzCardCaptionView, .home)
                    #else
                    VStack(alignment: .leading, spacing: 12) {
                        dayTitle(day)
                            .font(PlozziOSMediaRailLayout.headingFont)
                            .padding(.horizontal, cardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin)
                            .accessibilityAddTraits(.isHeader)
                        releaseGrid(groups[day] ?? [], columns: columns, metrics: metrics, width: width)
                    }
                    #endif
                }
                .frame(minHeight: day == days.last ? minimumLastDayHeight : 0, alignment: .top)
                #if os(tvOS)
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusSection()
                #else
                .background {
                    if Calendar.current.isDateInToday(day) {
                        UpcomingTodayAnchor()
                    }
                }
                #endif
                .id(day)
            }
        }

        private func dayTitle(_ day: Date) -> Text {
            let calendar = Calendar.current
            if calendar.isDateInToday(day) { return Text("Today") }
            if calendar.isDateInTomorrow(day) { return Text("Tomorrow") }
            if calendar.isDateInYesterday(day) { return Text("Yesterday") }
            let format = Date.FormatStyle.dateTime.weekday(.wide).month(.abbreviated).day()
            return Text(day, format: calendar.component(.year, from: day) == calendar.component(.year, from: Date())
                        ? format : format.year())
        }

        private func releaseGrid(
            _ releases: [UpcomingRelease], columns: [GridItem], metrics: PlozzMetrics, width: CGFloat
        ) -> some View {
            LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                ForEach(releases) { release in
                    UpcomingReleaseCard(release: release)
                        .environment(\.plozzMetrics, metrics)
                        .frame(width: width)
                        .contextMenu { Button("Hide title") { model.hide(release) } }
                        .navigationEntryFocus(Calendar.current.startOfDay(for: release.date) >= selectedDay ? .content : nil)
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
        @Environment(\.locale) private var locale
        #if os(iOS)
            @Environment(\.plozzCardStyle) private var cardStyle
            @Environment(\.mediaItemArtworkNavigator) private var navigateArtwork
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
                                MediaArtworkZoomButton(id: release.item.stablePresentationID) { source in
                                    if let navigateArtwork { navigateArtwork(release.item, source) }
                                    else { navigate?(release.item) }
                                } label: {
                                    PosterCardView(
                                        item: release.item, style: .landscape,
                                        reservesSubtitleSpace: false, statusCue: statusCue(for: release)
                                    ) {}
                                }
                                .buttonStyle(.plain)
                                .frame(width: metrics.cardSlotWidth(for: .landscape, cardStyle: cardStyle))
                            }
                        }
                    }
                }
                .environment(\.plozzCardCaptionView, .home)
            #endif
        }

        private func statusCue(for release: UpcomingRelease) -> Text {
            let date = release.date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
            if let subtitle = release.subtitle {
                return Text(LocalizedStringResource(
                    "upcoming.release.status",
                    defaultValue: "\(date) · \(subtitle)",
                    comment: "Coming Soon card cue. First placeholder is a locale-formatted release date; second is an already localized season/episode subtitle. Preserve both; their order and separator may be adapted."
                ))
            }
            return Text(verbatim: date)
        }
    }

    private struct UpcomingReleaseCard: View {
        let release: UpcomingRelease
        @Environment(\.mediaItemNavigator) private var navigate
        #if os(iOS)
            @Environment(\.mediaItemArtworkNavigator) private var navigateArtwork
        #endif

        var body: some View {
            #if os(iOS)
            MediaArtworkZoomButton(id: release.item.stablePresentationID) { source in
                if let navigateArtwork { navigateArtwork(release.item, source) }
                else { navigate?(release.item) }
            } label: { card }
            .buttonStyle(.plain)
            #else
            card
            #endif
        }

        private var card: some View {
            PosterCardView(
                item: release.item, style: .poster, captionSubtitle: release.posterSubtitle
            ) { navigate?(release.item) }
        }
    }

    struct UpcomingCalendar: View {
        @Binding var selectedDay: Date
        let interval: DateInterval
        var dismissesOnSelection = true
        @Environment(\.dismiss) private var dismiss
        @Environment(\.themePalette) private var palette
        @State private var month: Date = Date()

        var body: some View {
            #if os(tvOS)
                let calendar = Calendar.current
                let start = calendar.dateInterval(of: .month, for: month)!.start
                let dayCount = calendar.range(of: .day, in: .month, for: month)!.count
                let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
                VStack(spacing: 24) {
                    HStack {
                        calendarControl(
                            Button("Previous month", systemImage: "chevron.left") {
                                month = calendar.date(byAdding: .month, value: -1, to: month)!
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("upcoming.calendar.previous")
                            .disabled(start <= interval.start)
                        )
                        Text(month, format: .dateTime.month(.wide).year())
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                            .accessibilityIdentifier("upcoming.calendar.month")
                        calendarControl(
                            Button("Next month", systemImage: "chevron.right") {
                                month = calendar.date(byAdding: .month, value: 1, to: month)!
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("upcoming.calendar.next")
                            .disabled(calendar.date(byAdding: .month, value: 1, to: start)! >= interval.end)
                        )
                    }
                    Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                        GridRow {
                            ForEach(0..<7, id: \.self) { index in
                                Text(
                                    verbatim: calendar.shortStandaloneWeekdaySymbols[
                                        (calendar.firstWeekday - 1 + index) % 7]
                                )
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(0..<((offset + dayCount + 6) / 7), id: \.self) { week in
                            GridRow {
                                ForEach(0..<7, id: \.self) { weekday in
                                    let index = week * 7 + weekday - offset
                                    if index >= 0, index < dayCount {
                                        calendarCell(calendar.date(byAdding: .day, value: index, to: start)!)
                                    } else {
                                        Color.clear.frame(width: 104, height: 66)
                                    }
                                }
                            }
                        }
                    }
                    Button("Cancel") { dismiss() }
                }
                .plozzActionButton(role: .secondary)
                .frame(width: 7 * 104 + 6 * 16)
                .padding(48)
                .onAppear { month = selectedDay }
            #else
                DatePicker(
                    "Date", selection: $selectedDay,
                    in: interval.start...interval.end.addingTimeInterval(-1),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                // A toolbar popover otherwise proposes the button's narrow width.
                .frame(width: 320)
                .fixedSize(horizontal: false, vertical: true)
                .padding([.top, .bottom, .trailing], 16)
                .padding(.leading, dismissesOnSelection ? 16 : 0)
                .accessibilityIdentifier("upcoming.calendar.picker")
                .onChange(of: selectedDay) { _, _ in
                    if dismissesOnSelection { dismiss() }
                }
            #endif
        }

        #if os(tvOS)
        private func calendarCell(_ day: Date) -> some View {
            let calendar = Calendar.current
            return calendarControl(dayButton(day))
                .disabled(day < interval.start || day >= interval.end)
                .accessibilityAddTraits(calendar.isDate(day, inSameDayAs: selectedDay) ? .isSelected : [])
                .accessibilityLabel(Text(day, format: .dateTime.weekday().month().day()))
                .accessibilityValue(calendar.isDateInToday(day) ? Text("Today") : Text(verbatim: ""))
                .accessibilityIdentifier("upcoming.calendar.day.\(calendar.component(.day, from: day))")
        }

        @ViewBuilder
        private func calendarControl(_ control: some View) -> some View {
            if #available(tvOS 26.0, *) {
                control
                    .buttonSizing(.flexible)
                    .frame(width: 104, height: 66)
            } else {
                control.frame(width: 104, height: 66)
            }
        }

        private func dayButton(_ day: Date) -> some View {
            let isToday = Calendar.current.isDateInToday(day)
            let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
            return Button {
                selectedDay = day
                dismiss()
            } label: {
                Text(day, format: .dateTime.day())
                    .font(.body)
                    .fontWeight(isToday ? .bold : .regular)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 40, height: 32)
                    .overlay(alignment: .bottom) {
                        if isToday {
                            Circle().fill()
                                .frame(width: 5, height: 5)
                                .offset(y: 7)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .plozzActionButton(role: isSelected ? .primary : .secondary)
            .tint(palette.primaryText.opacity(isSelected ? 0.3 : 1))
        }
        #endif
    }
#endif
