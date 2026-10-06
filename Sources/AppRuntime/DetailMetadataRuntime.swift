import CoreModels
import CoreSecureStore
import MetadataKit

public extension DetailMetadataResolver {
    /// Read the same household settings and credential as the share pipeline on each open.
    static let household: DetailMetadataResolver = {
        let keys = TMDBUserKeyStore(secureStore: KeychainStore(service: "com.plozz.app.household"))
        return DetailMetadataResolver(providerConfig: {
            MetadataProviderConfig.resolved().withUserToken(keys.load())
        })
    }()
}
