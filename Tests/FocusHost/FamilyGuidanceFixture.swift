import CoreModels
import CoreUI
import SwiftUI

struct FamilyGuidanceFixture: View {
    @State private var loader = FixtureGuidanceLoader()

    var body: some View {
        VStack {
            Text("Family guidance fixture ready").accessibilityIdentifier("family-guidance-fixture-ready")
            DetailInformationSections(
                item: MediaItem(
                    id: "fixture", title: "Family guidance fixture", kind: .movie,
                    familyGuidance: .init(recommendedAge: 14, qualityRating: 3,
                                          overview: "A fictional summary for interface checks.")
                ),
                horizontalInset: 90
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .environment(\.themePalette, .dark)
        .environment(\.colorScheme, .dark)
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
            summary: .init(recommendedAge: 16, qualityRating: 3),
            audienceRatings: [.init(audience: .parents, recommendedAge: 13.5, qualityRating: 4)],
            topics: [
                .init(id: "violence", label: "Violence", rating: 0,
                      explanation: "No violence appears in this fictional fixture.", isPositive: false),
                .init(id: "language", label: "Language", rating: 2,
                      explanation: "A fictional description of language.", isPositive: false)
            ],
            parentsNeedToKnow: "This is fictional guidance used only to exercise the interface."
        ))
    }
}
