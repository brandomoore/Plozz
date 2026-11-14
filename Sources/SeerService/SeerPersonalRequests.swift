import CoreModels
import CoreNetworking
import Foundation

struct SeerPersonalRequestPage: Decodable {
    struct Request: Decodable {
        struct Media: Decodable {
            let tmdbId: Int
            let mediaType: String
        }
        struct User: Decodable { let id: Int }
        let id: Int
        let status: Int
        let media: Media
        let requestedBy: User
    }
    let pageInfo: SeerPageInfo
    let results: [Request]
}
