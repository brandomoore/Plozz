import Foundation
import FeatureHomeCore

/// Shared values used by refresh lifecycle tests. Keeping them here prevents
/// each suite from inventing its own "long enough" duration or surface identity.
public enum ContentRefreshTestConstants {
    public static let shortAway: TimeInterval = 5
    public static let longAway: TimeInterval = 10 * 60
    public static let detailThreshold: TimeInterval = 5 * 60
    public static let homeThreshold: TimeInterval = 15

    public static let home = ContentRefreshSurfaceID(kind: .home)
    public static let series = ContentRefreshSurfaceID(
        kind: .seriesDetail, accountID: "acct", itemID: "series-1"
    )
    public static let episode = ContentRefreshSurfaceID(
        kind: .episodeDetail, accountID: "acct", itemID: "episode-1"
    )
    public static let movie = ContentRefreshSurfaceID(
        kind: .movieDetail, accountID: "acct", itemID: "movie-1"
    )
}
