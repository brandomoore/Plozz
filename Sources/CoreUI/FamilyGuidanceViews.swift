import CoreModels
import CoreNetworking
import SwiftUI

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

    var body: some View {
        Button { isPresented = true } label: {
            VStack(spacing: 10) {
                Text(verbatim: "Common Sense Media")
                    .font(sourceFont)
                    .multilineTextAlignment(.center)
                if let age = summary.recommendedAge {
                    Text(verbatim: age.formatted(.number.precision(.fractionLength(0...1))) + "+")
                        .font(valueFont)
                        .monospacedDigit()
                    Text("Recommended age", comment: "Common Sense Media's age recommendation, not the official content certificate.")
                        .font(captionFont)
                }
                if let score = summary.qualityRating {
                    FamilyGuidanceScore(value: score, usesStar: true)
                        .font(captionFont)
                }
            }
            .foregroundStyle(palette.primaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
        }
        .plozzCardButton(cornerRadius: 18, focusedScale: PlozzTheme.Metrics.readOnlyFocusedCardScale)
        .accessibilityIdentifier("family-guidance-tile")
        .sheet(isPresented: $isPresented) {
            FamilyGuidanceSheet(item: item, summary: summary, authorizationID: provider?.contextID)
        }
    }

    private var sourceFont: Font {
        #if os(tvOS)
        .system(size: 18, weight: .semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }

    private var valueFont: Font {
        #if os(tvOS)
        .system(size: 40, weight: .semibold)
        #else
        .title2.weight(.semibold)
        #endif
    }

    private var captionFont: Font {
        #if os(tvOS)
        .system(size: 18)
        #else
        .caption
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
            #if os(tvOS)
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Family guidance").font(.title2.bold())
                    Spacer()
                    Button("Done") { dismiss() }
                }
                Text(item.title).font(.headline)
                scrollContent
            }
            .padding(48)
            .frame(width: 1100, height: 840)
            .background(palette.settingsBackground, in: RoundedRectangle(cornerRadius: 28))
            #else
            NavigationStack {
                scrollContent
                    .navigationTitle("Family guidance")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
            }
            .presentationBackground(palette.settingsBackground)
            #endif
        }
        .foregroundStyle(palette.primaryText)
        .accessibilityIdentifier("family-guidance-sheet")
        .task(id: attempt) { await load() }
        .onChange(of: provider?.contextID) { _, current in
            if current != authorizationID { dismiss() }
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if provider?.contextID == authorizationID {
                    FamilyGuidanceSummaryView(summary: displayedSummary)
                    if let overview = displayedSummary.overview {
                        Text(overview)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    resultContent
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(palette.settingsBackground)
    }

    private var displayedSummary: FamilyGuidanceSummary {
        guard case .loaded(.available(let guidance)) = state else { return summary }
        return FamilyGuidanceSummary(
            recommendedAge: guidance.summary.recommendedAge ?? summary.recommendedAge,
            qualityRating: guidance.summary.qualityRating ?? summary.qualityRating,
            overview: guidance.summary.overview ?? summary.overview
        )
    }

    @ViewBuilder
    private var resultContent: some View {
        switch state {
        case .idle, .loading:
            ProgressView("Loading family guidance…")
        case .failed(let error):
            Text(error.userMessage)
            Button("Retry") { attempt += 1 }
                .accessibilityIdentifier("family-guidance-retry")
        case .loaded(.restricted):
            Text("Detailed guidance requires Plex Pass access for the account viewing this title.")
        case .empty, .loaded(.unavailable):
            Text("Detailed guidance is not available for this title.")
        case .loaded(.available(let guidance)):
            FamilyGuidanceDetailsView(guidance: guidance)
        }
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

private struct FamilyGuidanceSummaryView: View {
    let summary: FamilyGuidanceSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Common Sense Media").font(.title3.bold())
            if let age = summary.recommendedAge {
                Text("Recommended age: \(age, format: .number.precision(.fractionLength(0...1)))+")
                    .font(.headline)
            }
            if let score = summary.qualityRating {
                HStack {
                    Text("Quality rating")
                    FamilyGuidanceScore(value: score, usesStar: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FamilyGuidanceDetailsView: View {
    let guidance: FamilyGuidance

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !guidance.hasDetails {
                Text("Only the basic rating is available. Detailed guidance depends on Plex Pass access and coverage for this title.")
            }
            if let explanation = guidance.parentsNeedToKnow {
                FamilyGuidanceParagraph(title: "What parents need to know", text: explanation)
            }
            if !guidance.topics.isEmpty {
                Text("Content guidance").font(.headline)
                ForEach(guidance.topics) { topic in
                    FamilyGuidanceTopicView(topic: topic)
                }
                Text("Category scores describe how much of that content is present, not an overall age recommendation.")
                    .font(.caption)
                    .plozzForeground(.secondary)
            }
            if let quality = guidance.qualityOverview {
                FamilyGuidanceParagraph(title: "Is it any good?", text: quality)
            }
            ForEach(guidance.audienceRatings.filter { $0.audience != .official }) { rating in
                FamilyGuidanceAudienceView(rating: rating)
            }
            if !guidance.talkingPoints.isEmpty {
                FamilyGuidanceParagraph(
                    title: "Talk with your family",
                    text: guidance.talkingPoints.joined(separator: "\n\n")
                )
            }
            Text("Ratings and guidance provided by Common Sense Media through Plex.")
                .font(.caption)
                .plozzForeground(.secondary)
        }
    }
}

private struct FamilyGuidanceTopicView: View {
    let topic: FamilyGuidance.Topic

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(topic.label).font(.headline)
                Spacer()
                if let rating = topic.rating {
                    FamilyGuidanceScore(value: rating, usesStar: false)
                }
            }
            if let explanation = topic.explanation {
                Text(explanation).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .plozzFocusableCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

private struct FamilyGuidanceParagraph: View {
    let title: LocalizedStringResource
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .plozzFocusableCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

private struct FamilyGuidanceAudienceView: View {
    let rating: FamilyGuidance.AudienceRating

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if rating.audience == .parents {
                Text("Parents’ rating").font(.headline)
            } else {
                Text("Kids’ rating").font(.headline)
            }
            if let age = rating.recommendedAge {
                Text("Average recommended age: \(age, format: .number.precision(.fractionLength(0...1)))+")
            }
            if let score = rating.qualityRating {
                FamilyGuidanceScore(value: score, usesStar: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .plozzFocusableCard(cornerRadius: 18)
    }
}

private struct FamilyGuidanceScore: View {
    let value: Double
    let usesStar: Bool

    var body: some View {
        HStack(spacing: 6) {
            if usesStar { Image(systemName: "star.fill").accessibilityHidden(true) }
            Text(value, format: .number.precision(.fractionLength(0...1)))
            Text(verbatim: "/ 5")
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value, format: .number.precision(.fractionLength(0...1))) out of 5")
    }
}
