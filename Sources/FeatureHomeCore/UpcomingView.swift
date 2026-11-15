#if canImport(SwiftUI)
    import SwiftUI
    import CoreModels
    import CoreUI

    public struct UpcomingView: View {
        @Bindable private var model: UpcomingFeedModel
        @Environment(\.themePalette) private var palette
        #if os(tvOS)
            @Environment(\.plozzNavigationContentInset) private var navigationInset
            @Environment(\.plozzTopNavigationContentInsets) private var topNavigationInsets
        #elseif os(iOS)
            @Environment(\.horizontalSizeClass) private var sizeClass
            @Environment(\.accessibilityReduceMotion) private var reduceMotion
            @Environment(\.plozzMetrics) private var metrics
            @Environment(\.plozzCardStyle) private var cardStyle
            @State private var availableSize = CGSize.zero
            @State private var agendaSize = CGSize.zero
            @State private var calendarIsMinimized = false
            @State private var scrollDay: Date? = Calendar.current.startOfDay(for: Date())
        #endif
        @State private var selectedDay = Calendar.current.startOfDay(for: Date())
        @State private var showingCalendar = false
        @State private var didScrollInitially = false
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
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView {
                            UpcomingAgenda(
                                model: model, selectedDay: selectedDay,
                                minimumSelectedHeight: agendaHeight, contentWidth: agendaContentWidth
                            )
                            .opacity(model.visibleReleases.isEmpty ? 0 : 1)
                            #if os(tvOS)
                            .padding(.vertical)
                            #endif
                        }
                        .overlay {
                            if model.visibleReleases.isEmpty {
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
                        .scrollPosition(id: $scrollDay, anchor: .top)
                        .modifier(UpcomingScrollEdge())
                        .task(id: agendaSize.width) {
                            guard agendaSize.width > 0 else { return }
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            proxy.scrollTo(scrollDay ?? selectedDay, anchor: .top)
                        }
                        .onChange(of: selectedDay) { _, day in
                            scrollDay = day
                        }
                        #else
                        .onChange(of: selectedDay) { _, day in
                            proxy.scrollTo(day, anchor: .top)
                        }
                        .task(id: model.releases.isEmpty) {
                            if !model.releases.isEmpty, !didScrollInitially {
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
                                selectedDay: $selectedDay, interval: interval, dismissesOnSelection: false
                            )
                            .transition(.opacity)
                        }
                        #endif
                    }
                    if model.lastHiddenTitle != nil {
                        Button("Undo hide", action: model.undoHide)
                    }
                }
                #if os(tvOS)
                .padding(.horizontal)
                .padding(.leading, navigationInset)
                .padding(.top, topNavigationInsets.top)
                #else
                .navigationTitle("")
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        calendarButton
                        UpcomingFilterMenu(model: model)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { availableSize = $0 }
                .onChange(of: supportsInlineCalendar) { _, supported in
                    if supported { showingCalendar = false }
                }
                #endif
                .tint(palette.primaryText)
                .onAppear { model.refreshIfStale() }
                #if os(tvOS)
                .sheet(isPresented: $showingCalendar) {
                    UpcomingCalendar(selectedDay: $selectedDay, interval: interval)
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
                UpcomingCalendar(selectedDay: $selectedDay, interval: interval)
                    .presentationCompactAdaptation(.popover)
            }
            #endif
        }

        private var agendaHeight: CGFloat {
            #if os(iOS)
            max(0, agendaSize.height - 32)
            #else
            0
            #endif
        }

        private var agendaContentWidth: CGFloat {
            #if os(iOS)
            max(0, agendaSize.width - 2 * agendaInset)
            #else
            0
            #endif
        }

        #if os(iOS)
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
        let model: UpcomingFeedModel
        let selectedDay: Date
        let minimumSelectedHeight: CGFloat
        let contentWidth: CGFloat
        @Environment(\.plozzMetrics) private var metrics
        @Environment(\.plozzCardStyle) private var cardStyle

        var body: some View {
            let calendar = Calendar.current
            let groups = Dictionary(grouping: model.visibleReleases) { calendar.startOfDay(for: $0.date) }
            let days = Set(groups.keys).union([selectedDay]).sorted()
            #if os(tvOS)
                let visibleDays = days.filter { $0 >= selectedDay }
                let spacing = metrics.cardSpacing
                let gridMetrics = metrics
                let width = metrics.cardSlotWidth(for: .poster, cardStyle: cardStyle)
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
                let history = visibleDays.filter { $0 < selectedDay }
                if !history.isEmpty {
                    dateGroups(history, groups: groups, columns: columns, metrics: gridMetrics, width: width)
                }
                VStack(alignment: .leading, spacing: 20) {
                    dateGroups(
                        visibleDays.filter { $0 >= selectedDay }, groups: groups,
                        columns: columns, metrics: gridMetrics, width: width
                    )
                    refreshError
                }
                .frame(minHeight: minimumSelectedHeight, alignment: .top)
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

        private func dateGroups(
            _ days: [Date], groups: [Date: [UpcomingRelease]],
            columns: [GridItem], metrics: PlozzMetrics, width: CGFloat
        ) -> some View {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 12) {
                        Group {
                            if Calendar.current.isDateInToday(day) {
                                Text("Today")
                            } else {
                                Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
                            }
                        }
                        #if os(tvOS)
                        .font(PlozzRailTitle.font(sectionHeaderFontSize: metrics.sectionHeaderFontSize))
                        #else
                        .font(PlozziOSMediaRailLayout.headingFont)
                        .padding(.horizontal, cardStyle == .framed ? metrics.cardInset : metrics.borderlessCardSideMargin)
                        #endif
                        .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.gridSpacing) {
                            ForEach(groups[day] ?? []) { release in
                                UpcomingReleaseCard(release: release)
                                    .environment(\.plozzMetrics, metrics)
                                    .frame(width: width)
                                    .contextMenu { Button("Hide title") { model.hide(release) } }
                            }
                        }
                    }
                    .id(day)
                }
            }
            #if os(iOS)
            .scrollTargetLayout()
            #endif
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

        var body: some View {
            PosterCardView(
                item: release.item, style: .poster, captionSubtitle: release.posterSubtitle
            ) { navigate?(release.item) }
        }
    }

    private struct UpcomingCalendar: View {
        @Binding var selectedDay: Date
        let interval: DateInterval
        var dismissesOnSelection = true
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
                .padding()
                .accessibilityIdentifier("upcoming.calendar.picker")
                .onChange(of: selectedDay) { _, _ in
                    if dismissesOnSelection { dismiss() }
                }
            #endif
        }
    }
#endif
