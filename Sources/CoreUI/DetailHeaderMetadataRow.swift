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

/// One line at every width; formats yield before lower-priority ratings.
/// The disclosure always retains the full metadata without shrinking its text.
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
            Button { showsDetails = true } label: {
                ViewThatFits(in: .horizontal) {
                    metadataLine(ratingCount: ratings.count, showsFormats: true)
                    ForEach(Array((0...ratings.count).reversed()), id: \.self) { count in
                        metadataLine(ratingCount: count, showsFormats: false)
                    }
                    disclosureChevron
                        .accessibilityLabel(Text(detailsTitle))
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityHint(Text(detailsTitle))
            .accessibilityIdentifier("detail-header-metadata")
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

    private func metadataLine(ratingCount: Int, showsFormats: Bool) -> some View {
        HStack(spacing: 12) {
            if let familyGuidanceAge {
                FamilyGuidanceAgeBadge(age: familyGuidanceAge)
            }
            ForEach(Array(ratings.prefix(ratingCount))) { RatingBadge(rating: $0) }
            if showsFormats, !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges) { MetadataMediaBadgeChip(badge: $0) }
                }
            }
            disclosureChevron.accessibilityHidden(true)
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.forward")
            .font(.caption.weight(.semibold))
            .plozzForeground(.secondary)
    }

    private var detailsTitle: LocalizedStringResource {
        if ratings.isEmpty && familyGuidanceAge == nil { return "Picture & sound" }
        if badges.isEmpty { return "Ratings" }
        return "Ratings & formats"
    }
}
