import CoreModels
import CoreUI
import SwiftUI

struct FamilyGuidanceFixture: View {
    @State private var loader = FixtureGuidanceLoader()
    private var palette: ThemePalette {
        ProcessInfo.processInfo.arguments.contains("--family-guidance-light") ? .light : .dark
    }

    var body: some View {
        VStack {
            Text("Family guidance fixture ready").accessibilityIdentifier("family-guidance-fixture-ready")
            RatingsBadgeRow(
                ratings: DetailPageSettings.default.headerRatings(from: [
                    .init(source: .imdb, value: 8, scale: .outOfTen),
                    .init(source: .rottenTomatoes, value: 94, scale: .percent),
                    .init(source: .rottenTomatoesAudience, value: 88, scale: .percent)
                ], isAnime: false, hidesRatings: false),
                familyGuidanceAge: 14
            )
            DetailInformationSections(
                item: MediaItem(
                    id: "fixture", title: "Family guidance fixture", kind: .movie,
                    familyGuidance: .init(recommendedAge: 14, qualityRating: 5,
                                          overview: "A sci-fi mystery with tense scenes, strong language, and unsettling images.")
                ),
                horizontalInset: 90
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.settingsBackground)
        .environment(\.themePalette, palette)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .environment(\.plozzCardFocusStyle, .system)
        .environment(\.familyGuidanceProvider, loader)
    }
}

@MainActor
private final class FixtureGuidanceLoader: FamilyGuidanceLoading {
    let contextID = "fixture"
    private var requests = 0

    func loadFamilyGuidance(for item: MediaItem) async throws -> FamilyGuidanceAvailability {
        requests += 1
        if ProcessInfo.processInfo.arguments.contains("--family-guidance-restricted") { return .restricted }
        if requests == 1 && ProcessInfo.processInfo.arguments.contains("--family-guidance-failure") {
            throw AppError.serverUnreachable
        }
        return .available(FamilyGuidance(
            summary: .init(recommendedAge: 16, qualityRating: 5),
            audienceRatings: [
                .init(audience: .parents, recommendedAge: 13.5, qualityRating: 4),
                .init(audience: .kids, recommendedAge: 12, qualityRating: 3.5)
            ],
            topics: [
                .init(id: "message", label: "Positive Messages", rating: 3,
                      explanation: "Characters learn to listen and work together.", isPositive: true),
                .init(id: "role_model", label: "Positive Role Models", rating: 2,
                      explanation: "The fictional characters make both helpful and unhelpful choices.", isPositive: true),
                .init(id: "violence", label: "Violence", rating: 0,
                      explanation: "No violence appears in this fictional fixture.", isPositive: false),
                .init(id: "language", label: "Language", rating: 2,
                      explanation: "A fictional description of language.", isPositive: false),
                .init(id: "sex", label: "Sex, Romance & Nudity", rating: 1,
                      explanation: "A fictional description of romantic content.", isPositive: false),
                .init(id: "consumerism", label: "Products & Purchases", rating: nil,
                      explanation: "No score was supplied for this fictional category.", isPositive: false),
                .init(id: "drugs", label: "Drinking, Drugs & Smoking", rating: 2,
                      explanation: "A fictional description of this category.", isPositive: false)
            ],
            parentsNeedToKnow: (1...5).map { index in
                "Review paragraph \(index). This fictional review is deliberately long enough to require reading beyond one screen. It describes a tense mystery, difficult choices, and scenes that some younger viewers may find unsettling. Families can use the individual content categories to understand those details without reading every explanation at once."
            }.joined(separator: "\n\n"),
            qualityOverview: "This fictional quality review is separate from the age recommendation.",
            talkingPoints: ["What helped the characters understand each other?", "How would you respond to their choices?"]
        ))
    }
}
