import CoreModels
import CoreNetworking
import Foundation

public protocol IPTVGuideIndexLoading: Sendable {
    func programmes(
        url: URL, channels: [IPTVProvider.IPTVGuideChannel], from: Date, to: Date,
        catalog: @escaping @Sendable () async throws -> [IPTVProvider.IPTVGuideChannel],
        download: @escaping @Sendable () async throws -> XMLTVDownloadedDocument
    ) async throws -> [ServerLiveTVProgramme]
    func invalidate() async
    func cancel() async
}
