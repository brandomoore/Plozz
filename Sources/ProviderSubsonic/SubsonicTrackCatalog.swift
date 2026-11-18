import CoreModels
import Foundation

/// Classic servers need not support an empty search. Incrementally walk albums
/// instead, sharing in-flight reads and retaining the cursor for later pages.
actor SubsonicTrackCatalog {
    private let client: SubsonicClient
    private var albums: [SubsonicNode] = []
    private var albumOffset = 0
    private var tracks: [SubsonicNode] = []
    private var seenAlbums: Set<String> = []
    private var seenTracks: Set<String> = []
    private var complete = false
    private var pending: (id: UUID, task: Task<SubsonicResponse, Error>)?

    init(client: SubsonicClient) { self.client = client }

    func page(start: Int, limit: Int) async throws -> (nodes: [SubsonicNode], total: Int) {
        guard start >= 0, limit > 0, start <= Int.max - limit else { throw AppError.invalidResponse }
        if start == 0, pending == nil, !tracks.isEmpty {
            albums = []
            albumOffset = 0
            tracks = []
            seenAlbums = []
            seenTracks = []
            complete = false
        }
        while tracks.count < start + limit && !complete {
            try Task.checkCancellation()
            let loadingAlbums = albums.isEmpty
            let request: (id: UUID, task: Task<SubsonicResponse, Error>)
            if let pending {
                request = pending
            } else {
                let client = client, offset = albumOffset, albumID = albums.first?.id
                request = (UUID(), Task {
                    if let albumID {
                        return try await client.request("getAlbum", [.init(name: "id", value: albumID)])
                    }
                    return try await client.request("getAlbumList2", [
                        .init(name: "type", value: "alphabeticalByName"),
                        .init(name: "size", value: "100"), .init(name: "offset", value: String(offset))
                    ])
                })
                pending = request
            }
            do {
                let response = try await request.task.value
                // Another waiter may already have applied this exact response.
                if pending?.id == request.id {
                    pending = nil
                    if loadingAlbums {
                        guard let list = response.albumList2 else { throw AppError.invalidResponse }
                        let nodes = list.album ?? []
                        if nodes.isEmpty { complete = true }
                        else {
                            guard nodes.allSatisfy({ !$0.id.isEmpty && !seenAlbums.contains($0.id) }),
                                  Set(nodes.map(\.id)).count == nodes.count else {
                                throw AppError.invalidResponse
                            }
                            seenAlbums.formUnion(nodes.map(\.id))
                            albumOffset += nodes.count
                            albums = nodes
                        }
                    } else {
                        guard let album = response.album, album.id == albums.first?.id else {
                            throw AppError.invalidResponse
                        }
                        tracks += (album.song ?? []).filter { seenTracks.insert($0.id).inserted }
                        albums.removeFirst()
                    }
                }
            } catch {
                if pending?.id == request.id { pending = nil }
                throw error
            }
        }
        try Task.checkCancellation()
        return (Array(tracks.dropFirst(start).prefix(limit)), tracks.count + (complete ? 0 : 1))
    }
}
