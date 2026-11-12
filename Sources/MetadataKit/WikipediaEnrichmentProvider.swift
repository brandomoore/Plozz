import Foundation
import CoreModels
import CoreNetworking

public struct WikipediaEnrichmentProvider: MetadataEnrichmentProvider {
    public let id: MetadataSource = .wikipedia
    public let capabilities: Set<MetadataCapability> = [.canonicalText, .poster, .backdrop, .logo]
    public let policy = ProviderPolicy(requestsPerSecond: 1, burst: 2, version: 2)
    private let http: MetadataDiscoveryHTTPClient
    private let artwork: ArtworkEnrichmentAdapter

    public init(
        http: MetadataDiscoveryHTTPClient = .init(),
        artworkProvider: any ArtworkProvider = WikipediaArtworkProvider()
    ) {
        self.http = http
        self.artwork = ArtworkEnrichmentAdapter(
            id: .wikipedia, capabilities: [.poster, .backdrop, .logo], provider: artworkProvider
        )
    }

    public func supports(_ field: MetadataField, at tier: MetadataWorkTier) -> Bool {
        field == .overview || tier == .idleBacklog
    }

    public func enrich(_ query: MetadataQuery, missing: Set<MetadataField>) async -> MetadataEnrichment {
        await enrichReporting(query, missing: missing).enrichment
    }

    public func enrichReporting(_ query: MetadataQuery, missing: Set<MetadataField>) async -> ProviderResponse {
        var result = await artwork.enrich(query, missing: missing.subtracting([.overview]))
        guard missing.contains(.overview),
              Locale.Language(identifier: query.metadataLanguage).languageCode?.identifier == "en",
              query.kind == .movie || query.kind == .series,
              let search = WikipediaArtworkProvider.searchTerm(
                title: query.title, year: query.year, isTV: query.isTV
              ),
              let escaped = metadataEscaped(search),
              let url = URL(string: "https://en.wikipedia.org/w/api.php?action=query&format=json&prop=extracts&exintro=1&explaintext=1&redirects=1&generator=search&gsrnamespace=0&gsrlimit=1&gsrsearch=\(escaped)")
        else { return ProviderResponse(enrichment: result, health: result.isEmpty ? .empty : .ok) }
        do {
            let response = try await http.decode(Response.self, from: URLRequest(url: url))
            if let text = response.query?.pages?.values.first?.extract?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                result.overview = SourcedValue(value: text, source: .wikipedia, sourceURL: url)
            }
            return ProviderResponse(enrichment: result, health: result.isEmpty ? .empty : .ok)
        } catch {
            let failure: ProviderFailureKind
            switch error {
            case MetadataDiscoveryHTTPError.status(401, _), MetadataDiscoveryHTTPError.status(403, _):
                failure = .unauthorized
            case MetadataDiscoveryHTTPError.status(429, let retryAfter):
                failure = .rateLimited(retryAfter: retryAfter)
            default: failure = .transient
            }
            if !Task.isCancelled {
                PlozzLog.networking.error("Wikipedia overview enrichment failed; retaining available metadata.")
            }
            return ProviderResponse(enrichment: result, health: .failure(failure))
        }
    }

    private struct Response: Decodable, Sendable {
        let query: Query?
        struct Query: Decodable, Sendable { let pages: [String: Page]? }
        struct Page: Decodable, Sendable { let extract: String? }
    }
}
