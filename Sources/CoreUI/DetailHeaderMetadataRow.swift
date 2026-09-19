import SwiftUI
import CoreModels

private struct DetailHeaderSettingsKey: EnvironmentKey {
    static let defaultValue: DetailPageSettingsModel? = nil
}

public extension EnvironmentValues {
    var detailHeaderSettings: DetailPageSettingsModel? {
        get { self[DetailHeaderSettingsKey.self] }
        set { self[DetailHeaderSettingsKey.self] = newValue }
    }
}

public struct HeaderRatingPreviewControls: View {
    @Binding private var settings: DetailPageSettings

    public init(settings: Binding<DetailPageSettings>) {
        _settings = settings
    }

    public var body: some View {
        Toggle("Show Common Sense age", isOn: $settings.showsHeaderFamilyGuidance)
        Picker("Review scores shown", selection: $settings.maxHeaderRatings) {
            ForEach(Array(DetailPageSettings.headerRatingCountRange), id: \.self) { count in
                Text(count, format: .number).tag(count)
            }
        }
    }
}

/// Richer previews wrap without hiding the recommended age or extra review scores.
public struct DetailHeaderMetadataRow: View {
    private let ratings: [ExternalRating]
    private let badges: [MediaBadge]
    private let familyGuidanceAge: Double?
    @State private var showsDetails = false

    public init(ratings: [ExternalRating], badges: [MediaBadge], familyGuidanceAge: Double? = nil) {
        self.ratings = ratings
        self.badges = badges
        self.familyGuidanceAge = familyGuidanceAge
    }

    public var body: some View {
        if !ratings.isEmpty || !badges.isEmpty || familyGuidanceAge != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    if let familyGuidanceAge {
                        FamilyGuidanceAgeBadge(age: familyGuidanceAge)
                    }
                    ForEach(ratings) { RatingBadge(rating: $0) }
                    if !badges.isEmpty {
                        Button { showsDetails = true } label: {
                            HStack(spacing: 10) {
                                ForEach(badges) { badge in
                                    MetadataMediaBadgeChip(badge: badge)
                                }
                            }
                        }
                        .accessibilityLabel("Picture & sound")
                        .accessibilityValue(badges.map(\.accessibilityText).joined(separator: ", "))
                    }
                }
                .fixedSize(horizontal: true, vertical: true)

                HStack(spacing: 12) {
                    if let familyGuidanceAge {
                        FamilyGuidanceAgeBadge(age: familyGuidanceAge)
                    }
                    ForEach(ratings) { RatingBadge(rating: $0) }
                    if !badges.isEmpty {
                        formatsDisclosure
                    }
                }
                .fixedSize(horizontal: true, vertical: true)

                if ratings.count > 2 || familyGuidanceAge != nil {
                    WrappingHStackLayout(
                        alignment: .center,
                        spacing: 12,
                        lineSpacing: 8,
                        balancesLastRow: true
                    ) {
                        if let familyGuidanceAge {
                            FamilyGuidanceAgeBadge(age: familyGuidanceAge)
                        }
                        ForEach(ratings) { RatingBadge(rating: $0) }
                        if !badges.isEmpty {
                            formatsDisclosure
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        Button { showsDetails = true } label: {
                            Text(detailsTitle)
                                .font(.subheadline.weight(.medium))
                        }
                        .fixedSize(horizontal: true, vertical: true)

                        Button { showsDetails = true } label: {
                            Image(systemName: "info.circle")
                                .font(.body)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(Text(detailsTitle))
                    }
                }
            }
            .lineLimit(1)
            .buttonStyle(.plain)
            .plozzForeground(.primary)
            .frame(maxWidth: .infinity, alignment: .center)
            .sheet(isPresented: $showsDetails) {
                NavigationStack {
                    List {
                        if !ratings.isEmpty || familyGuidanceAge != nil {
                            Section("Ratings") {
                                if let familyGuidanceAge {
                                    HStack {
                                        Text("Recommended age")
                                        Spacer()
                                        FamilyGuidanceAgeBadge(age: familyGuidanceAge)
                                    }
                                }
                                ForEach(ratings) { rating in
                                    HStack {
                                        Text(verbatim: rating.source.displayName)
                                        Spacer()
                                        RatingBadge(rating: rating)
                                    }
                                }
                            }
                        }
                        if !badges.isEmpty {
                            Section("Picture & sound") {
                                ForEach(badges) { badge in
                                    MediaBadgeChip(badge: badge)
                                }
                            }
                        }
                    }
                    .lineLimit(nil)
                    .navigationTitle(Text(detailsTitle))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsDetails = false }
                        }
                    }
                }
            }
        }
    }

    private var formatsDisclosure: some View {
        Button { showsDetails = true } label: {
            Label("Formats", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
        }
    }

    private var detailsTitle: LocalizedStringResource {
        if ratings.isEmpty && familyGuidanceAge == nil { return "Picture & sound" }
        if badges.isEmpty { return "Ratings" }
        return "Ratings & formats"
    }
}
