import CoreModels
import FeatureProfiles
import Observation

/// Mobile profile creation that must wait for the Settings sheet to dismiss.
///
/// Kept as a small observable facet rather than a stored property on
/// `PlozziOSAppModel`: the root observes this value across the sheet's animated
/// dismissal, and the app model's observation surface has a decreasing budget.
@MainActor
@Observable
final class PendingProfileCreation {
    struct Request {
        let draft: ProfileDraft
        let isKids: Bool
    }

    var request: Request?
}
