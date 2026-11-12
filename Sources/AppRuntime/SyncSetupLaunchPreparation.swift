import CoreModels
import CoreNetworking
import CoreSecureStore
import Foundation

public enum SyncSetupLaunchPreparation {
    /// False blocks app-model construction until a retry can classify the installation.
    public static func prepare(
        flag: SyncSetupFeatureFlag = SyncSetupFeatureFlag(),
        profiles: ProfileStore = ProfileStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
    ) -> Bool {
        guard flag.needsLaunchPreparation else { return true }
        do {
            flag.prepareForLaunch(hasExistingInstallation: try profiles.hasPersistedProfiles())
            return true
        } catch {
            PlozzLog.sync.error("Could not classify iCloud onboarding; waiting for retry before starting the app")
            return false
        }
    }
}
