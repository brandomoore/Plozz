import CoreModels
import CoreNetworking
import SwiftUI
#if os(tvOS)
import UIKit
#endif

private struct FamilyGuidanceProviderKey: EnvironmentKey {
    static let defaultValue: (any FamilyGuidanceLoading)? = nil
}

public extension EnvironmentValues {
    var familyGuidanceProvider: (any FamilyGuidanceLoading)? {
        get { self[FamilyGuidanceProviderKey.self] }
        set { self[FamilyGuidanceProviderKey.self] = newValue }
    }
}

struct FamilyGuidanceTile: View {
    let item: MediaItem
    let summary: FamilyGuidanceSummary
    @State private var isPresented = false
    @Environment(\.familyGuidanceProvider) private var provider
    @Environment(\.themePalette) private var palette
    #if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledAgeSize: CGFloat = 48
    #endif

    var body: some View {
        Button { isPresented = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                FamilyGuidanceAge(age: summary.recommendedAge, size: ageSize)
                FamilyGuidanceBrand(compact: true)
                    .font(sourceFont)
                if let overview = summary.overview {
                    Text(overview)
                        .font(summaryFont)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(palette.secondaryText)
                }
            }
            .foregroundStyle(palette.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "chevron.right")
                    .font(sourceFont)
                    .foregroundStyle(palette.secondaryText)
                    .padding(20)
                    .accessibilityHidden(true)
            }
        }
        .plozzCardButton(cornerRadius: 18, focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale)
        .accessibilityIdentifier("family-guidance-tile")
        .accessibilityHint("Open family guidance")
        #if os(tvOS)
        .fullScreenCover(isPresented: $isPresented) {
            FamilyGuidanceSheet(item: item, summary: summary, authorizationID: provider?.contextID)
        }
        #else
        .sheet(isPresented: $isPresented) {
            FamilyGuidanceSheet(item: item, summary: summary, authorizationID: provider?.contextID)
        }
        #endif
    }

    private var ageSize: CGFloat {
        #if os(tvOS)
        76
        #else
        scaledAgeSize
        #endif
    }
    private var sourceFont: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .caption.weight(.semibold)
        #endif
    }
    private var summaryFont: Font {
        #if os(tvOS)
        .system(size: 22)
        #else
        .subheadline
        #endif
    }
}

struct FamilyGuidanceSheet: View {
    let item: MediaItem
    let summary: FamilyGuidanceSummary
    let authorizationID: String?
    @Environment(\.familyGuidanceProvider) private var provider
    @Environment(\.themePalette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<FamilyGuidanceAvailability> = .idle
    @State private var attempt = 0

    var body: some View {
        Group {
            if provider?.contextID == authorizationID {
                #if os(tvOS)
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    TVFamilyGuidanceDialog(
                        title: item.title, summary: displayedSummary, state: state,
                        retry: { attempt += 1 }, close: { dismiss() }
                    )
                    .background(palette.settingsBackground, in: RoundedRectangle(cornerRadius: 28))
                    .shadow(color: .black.opacity(0.4), radius: 32, y: 16)
                }
                .presentationBackground(.clear)
                .onExitCommand { dismiss() }
                #else
                NavigationStack {
                    FamilyGuidanceMobileOverview(
                        title: item.title, summary: displayedSummary, state: state, retry: { attempt += 1 }
                    )
                    .navigationTitle("Family guidance")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: FamilyGuidancePage.self) { page in
                        ScrollView {
                            FamilyGuidanceDetailContent(
                                page: page, summary: displayedSummary, state: state, retry: { attempt += 1 }
                            )
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .background(palette.settingsBackground)
                    }
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
                .presentationBackground(palette.settingsBackground)
                #endif
            }
        }
        .foregroundStyle(palette.primaryText)
        .task(id: attempt) { await load() }
        .onChange(of: provider?.contextID) { _, current in
            if current != authorizationID { dismiss() }
        }
    }

    private var displayedSummary: FamilyGuidanceSummary {
        guard let guidance = state.guidance else { return summary }
        return FamilyGuidanceSummary(
            recommendedAge: guidance.summary.recommendedAge ?? summary.recommendedAge,
            qualityRating: guidance.summary.qualityRating ?? summary.qualityRating,
            overview: guidance.summary.overview ?? summary.overview
        )
    }

    private func load() async {
        guard let provider else {
            state = .loaded(.unavailable)
            return
        }
        state = .loading
        do {
            let result = try await provider.loadFamilyGuidance(for: item)
            try Task.checkCancellation()
            guard provider.contextID == authorizationID else { return }
            state = .loaded(result)
        } catch is CancellationError {
            // The sheet or its profile no longer owns this request.
        } catch {
            guard !Task.isCancelled, provider.contextID == authorizationID else { return }
            PlozzLog.app.error("Family guidance could not be loaded")
            state = .failed((error as? AppError) ?? .invalidResponse)
        }
    }
}

enum FamilyGuidancePage: Hashable {
    case overview, topic(String), reviews, discussion

    static func pages(summary: FamilyGuidanceSummary, guidance: FamilyGuidance?) -> [Self] {
        var pages: [Self] = [.overview]
        pages += (guidance?.topics ?? []).map { .topic($0.id) }
        if summary.qualityRating != nil || !(guidance?.audienceRatings ?? []).isEmpty
            || guidance?.qualityOverview != nil {
            pages.append(.reviews)
        }
        if !(guidance?.talkingPoints ?? []).isEmpty { pages.append(.discussion) }
        return pages
    }

    func topic(in guidance: FamilyGuidance?) -> FamilyGuidance.Topic? {
        guard case .topic(let id) = self else { return nil }
        return guidance?.topics.first { $0.id == id }
    }
}

private extension LoadState where Value == FamilyGuidanceAvailability {
    var guidance: FamilyGuidance? {
        guard case .loaded(.available(let guidance)) = self else { return nil }
        return guidance
    }
}

#if os(tvOS)
struct TVFamilyGuidanceDialog: View {
    let title: String // l10n:content — media title supplied by the provider
    let summary: FamilyGuidanceSummary
    let state: LoadState<FamilyGuidanceAvailability>
    let retry: () -> Void
    let close: () -> Void
    @State private var selection: FamilyGuidancePage = .overview
    @FocusState private var focusedPage: FamilyGuidancePage?
    @State private var readerFocused = false
    // Keep the return target exclusive until the menu actually regains focus.
    @State private var returnsToSelection = false
    @Environment(\.themePalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Text("Family guidance").font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Button("Done", action: close)
            }
            .focusSection()
            FamilyGuidanceHeader(title: title, summary: summary)
            Divider()
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(pages, id: \.self) { page in
                            Button {
                                selection = page
                            } label: {
                                FamilyGuidanceMenuLabel(page: page, guidance: state.guidance)
                                    .padding(.horizontal, 18)
                                    .padding(.vertical, 16)
                                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            }
                            .plozzCardButton(cornerRadius: 14, focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale)
                            .focused($focusedPage, equals: page)
                            .disabled(returnsToSelection && page != selection)
                            .accessibilityIdentifier(page.identifier)
                        }
                    }
                    .padding(24)
                }
                .frame(width: 380)
                .focusSection()
                FamilyGuidanceDetailContent(
                    page: selection, summary: summary, state: state, retry: retry,
                    onReaderFocus: {
                        readerFocused = $0
                        if $0 { returnsToSelection = true }
                    }
                )
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 20)
                .background(palette.raised.fill, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(palette.primaryText.opacity(readerFocused ? 0.45 : 0), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .focusSection()
            }
        }
        .padding(.horizontal, 40)
        .padding(.top, 40)
        .padding(.bottom, 24)
        .frame(width: 1480, height: 920)
        .defaultFocus($focusedPage, .overview, priority: .userInitiated)
        .onChange(of: focusedPage) { _, page in
            if let page {
                selection = page
                returnsToSelection = false
            }
        }
        .onChange(of: pages) { _, current in
            if !current.contains(selection) { selection = .overview }
        }
    }

    private var pages: [FamilyGuidancePage] {
        FamilyGuidancePage.pages(summary: summary, guidance: state.guidance)
    }
}
#else
private struct FamilyGuidanceMobileOverview: View {
    let title: String // l10n:content — media title supplied by the provider
    let summary: FamilyGuidanceSummary
    let state: LoadState<FamilyGuidanceAvailability>
    let retry: () -> Void
    @Environment(\.themePalette) private var palette

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                FamilyGuidanceHeader(title: title, summary: summary)
                ForEach(FamilyGuidancePage.pages(summary: summary, guidance: state.guidance), id: \.self) { page in
                    NavigationLink(value: page) {
                        FamilyGuidanceMenuLabel(page: page, guidance: state.guidance)
                            .padding(18)
                    }
                    .plozzCardButton(cornerRadius: 16)
                }
                if state.guidance == nil {
                    FamilyGuidanceStatus(state: state, retry: retry)
                }
            }
            .padding(24)
        }
        .background(palette.settingsBackground)
    }
}
#endif

private extension FamilyGuidancePage {
    var identifier: String {
        switch self {
        case .overview: "family-guidance-overview"
        case .topic(let id): "family-guidance-topic-\(id)"
        case .reviews: "family-guidance-reviews"
        case .discussion: "family-guidance-discussion"
        }
    }
}

private struct FamilyGuidanceAge: View {
    let age: Double?
    let size: CGFloat

    var body: some View {
        if let age {
            Text(verbatim: age.formatted(.number.precision(.fractionLength(0...1))) + "+")
                .font(.system(size: size, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("Recommended age: \(age, format: .number.precision(.fractionLength(0...1)))+")
        } else {
            Text("No age recommendation").font(.headline)
        }
    }
}

struct FamilyGuidanceHeader: View {
    let title: String // l10n:content — media title supplied by the provider
    let summary: FamilyGuidanceSummary
    @Environment(\.themePalette) private var palette
    #if os(iOS)
    @ScaledMetric(relativeTo: .largeTitle) private var scaledAgeSize: CGFloat = 60
    #endif

    var body: some View {
        layout {
            VStack(alignment: .leading, spacing: 4) {
                FamilyGuidanceAge(age: summary.recommendedAge, size: ageSize)
                Text("Recommended age").font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(titleFont).lineLimit(2)
                FamilyGuidanceBrand(compact: false)
                    .font(brandFont)
                    .foregroundStyle(palette.secondaryText)
                if let overview = summary.overview {
                    Text(overview)
                        .font(summaryFont)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("family-guidance-header")
    }

    private var layout: AnyLayout {
        #if os(tvOS)
        AnyLayout(HStackLayout(alignment: .center, spacing: 28))
        #else
        AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        #endif
    }

    private var ageSize: CGFloat {
        #if os(tvOS)
        92
        #else
        scaledAgeSize
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .headline
        #endif
    }
    private var brandFont: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }
    private var summaryFont: Font {
        #if os(tvOS)
        .system(size: 24)
        #else
        .body
        #endif
    }
}

private struct FamilyGuidancePageLabel: View {
    let page: FamilyGuidancePage
    let guidance: FamilyGuidance?
    var isMenu = false

    var body: some View {
        switch page {
        case .overview:
            if isMenu { Text("Overview") } else { Text("What parents need to know") }
        case .topic:
            if let topic = page.topic(in: guidance) { Text(topic.label) }
        case .reviews: Text("Review scores")
        case .discussion: Text("Talk with your family")
        }
    }
}

private struct FamilyGuidanceMenuLabel: View {
    let page: FamilyGuidancePage
    let guidance: FamilyGuidance?

    var body: some View {
        HStack(spacing: 14) {
            FamilyGuidancePageLabel(page: page, guidance: guidance, isMenu: true)
                .font(labelFont)
                #if os(tvOS)
                .lineLimit(2)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
            if let topic = page.topic(in: guidance) {
                FamilyGuidanceIntensity(value: topic.rating)
            }
        }
    }

    private var labelFont: Font {
        #if os(tvOS)
        .system(size: 22, weight: .medium)
        #else
        .body.weight(.medium)
        #endif
    }
}

private struct FamilyGuidanceDetailContent: View {
    let page: FamilyGuidancePage
    let summary: FamilyGuidanceSummary
    let state: LoadState<FamilyGuidanceAvailability>
    let retry: () -> Void
    #if os(tvOS)
    let onReaderFocus: @MainActor (Bool) -> Void
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            FamilyGuidancePageLabel(page: page, guidance: state.guidance)
                #if os(tvOS)
                .font(.system(size: 28, weight: .semibold))
                #else
                .font(.title2.bold())
                #endif
            if page == .reviews {
                FamilyGuidanceReviewScores(summary: summary, guidance: state.guidance)
                if let overview = state.guidance?.qualityOverview { text(overview) }
            } else if let guidance = state.guidance {
                switch page {
                case .overview:
                    if let overview = guidance.parentsNeedToKnow {
                        text(overview)
                    } else {
                        Text("Select a content topic to read its explanation.")
                    }
                case .topic:
                    if let topic = page.topic(in: guidance) {
                        FamilyGuidanceIntensity(value: topic.rating)
                        if let explanation = topic.explanation {
                            text(explanation)
                        } else {
                            Text("No explanation was provided for this topic.")
                        }
                    }
                case .discussion:
                    text(guidance.talkingPoints.joined(separator: "\n\n"))
                case .reviews: EmptyView()
                }
            } else {
                FamilyGuidanceStatus(state: state, retry: retry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func text(_ value: String) -> some View {
        #if os(tvOS)
        TVFamilyGuidanceReader(text: value, onFocus: onReaderFocus)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("family-guidance-reader")
        #else
        Text(value).fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

private struct FamilyGuidanceStatus: View {
    let state: LoadState<FamilyGuidanceAvailability>
    let retry: () -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView("Loading family guidance…")
        case .failed(let error):
            Text(error.userMessage)
            Button("Retry", action: retry).accessibilityIdentifier("family-guidance-retry")
        case .loaded(.restricted):
            Text("Detailed guidance requires Plex Pass access for the account viewing this title.")
        case .empty, .loaded(.unavailable):
            Text("Detailed guidance is not available for this title.")
        case .loaded(.available):
            EmptyView()
        }
    }
}

private struct FamilyGuidanceIntensity: View {
    let value: Double?
    @Environment(\.themePalette) private var palette

    var body: some View {
        if let value {
            HStack(spacing: 4) {
                ForEach(0..<5) { index in
                    Capsule().fill(palette.primaryText.opacity(Double(index) < value ? 0.85 : 0.15))
                        .frame(width: 13, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Content level: \(value, format: .number.precision(.fractionLength(0...1))) out of 5")
        } else {
            Text("Not rated").font(.caption).foregroundStyle(palette.secondaryText)
        }
    }
}

private struct FamilyGuidanceReviewScores: View {
    let summary: FamilyGuidanceSummary
    let guidance: FamilyGuidance?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Quality ratings, not age recommendations")
                .font(.subheadline)
                .plozzForeground(.secondary)
            HStack {
                Text(verbatim: "Common Sense Media")
                Spacer()
                FamilyGuidanceStars(value: summary.qualityRating)
            }
            ForEach((guidance?.audienceRatings ?? []).filter { $0.audience != .official }) { rating in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if rating.audience == .parents { Text("Parents’ rating") } else { Text("Kids’ rating") }
                        Spacer()
                        FamilyGuidanceStars(value: rating.qualityRating)
                    }
                    if let age = rating.recommendedAge {
                        Text("Average recommended age: \(age, format: .number.precision(.fractionLength(0...1)))+")
                            .font(.caption)
                            .plozzForeground(.secondary)
                    }
                }
            }
        }
    }
}

private struct FamilyGuidanceStars: View {
    let value: Double?

    var body: some View {
        if let value {
            HStack(spacing: 5) {
                ForEach(0..<5) { index in
                    Image(systemName: value >= Double(index) + 0.75 ? "star.fill" :
                            value >= Double(index) + 0.25 ? "star.leadinghalf.filled" : "star")
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Quality rating: \(value, format: .number.precision(.fractionLength(0...1))) out of 5")
        } else {
            Text("Not rated").font(.caption).plozzForeground(.secondary)
        }
    }
}

#if os(tvOS)
struct TVFamilyGuidanceReader: UIViewRepresentable {
    let text: String
    let onFocus: @MainActor (Bool) -> Void
    @Environment(\.themePalette) private var palette

    @MainActor
    final class Coordinator {
        var onFocus: @MainActor (Bool) -> Void
        init(onFocus: @escaping @MainActor (Bool) -> Void) { self.onFocus = onFocus }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    func makeUIView(context: Context) -> Reader {
        let view = Reader()
        view.onFocus = { [weak coordinator = context.coordinator] in coordinator?.onFocus($0) }
        view.backgroundColor = .clear
        view.isSelectable = true
        view.isScrollEnabled = true
        view.isUserInteractionEnabled = context.environment.isEnabled
        view.textContainerInset = UIEdgeInsets(top: 0, left: 0, bottom: 8, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.accessibilityIdentifier = "family-guidance-reader"
        return view
    }

    func updateUIView(_ view: Reader, context: Context) {
        context.coordinator.onFocus = onFocus
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 16
        let content = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 26),
            .foregroundColor: UIColor(palette.primaryText),
            .paragraphStyle: style
        ])
        if view.attributedText?.isEqual(to: content) != true { view.attributedText = content }
        view.isUserInteractionEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Reader, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    final class Reader: UITextView {
        var onFocus: (@MainActor (Bool) -> Void)?
        private var ownsFocus = false
        override var canBecomeFocused: Bool { true }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            let leavingReader = context.previouslyFocusedItem.map { $0 === self || self.contains($0) } == true
                && context.nextFocusedItem.map { $0 === self || self.contains($0) } != true
            if leavingReader && (context.focusHeading.contains(.up) || context.focusHeading.contains(.down)) {
                return false
            }
            return super.shouldUpdateFocus(in: context)
        }

        // UITextView handles remote swipes; physical arrows need bounded page scrolling.
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            let vertical = presses.filter { $0.type == .upArrow || $0.type == .downArrow }
            guard ownsFocus, let press = vertical.first else {
                super.pressesBegan(presses, with: event)
                return
            }
            let minimumY = -adjustedContentInset.top
            let maximumY = max(minimumY, contentSize.height - bounds.height + adjustedContentInset.bottom)
            let direction: CGFloat = press.type == .downArrow ? 1 : -1
            let nextY = min(maximumY, max(minimumY, contentOffset.y + direction * bounds.height * 0.75))
            setContentOffset(CGPoint(x: contentOffset.x, y: nextY), animated: true)
            let remaining = presses.subtracting(vertical)
            if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
        }

        override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
            super.didUpdateFocus(in: context, with: coordinator)
            // UITextView can focus a paragraph item rather than a UIView.
            ownsFocus = context.nextFocusedItem.map { $0 === self || self.contains($0) } ?? false
            onFocus?(ownsFocus)
        }
    }
}
#endif

private struct FamilyGuidanceBrand: View {
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            FamilyGuidanceIcon(size: 32)
            Text(verbatim: compact ? "Common Sense" : "Common Sense Media")
        }
    }
}

struct FamilyGuidanceIcon: View {
    let size: CGFloat
    @Environment(\.themePalette) private var palette

    var body: some View {
        Image("CommonSenseMedia", bundle: .module)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .background(palette.isLight ? ThemePalette.dark.settingsBackground : .clear, in: Circle())
            .accessibilityHidden(true)
    }
}
