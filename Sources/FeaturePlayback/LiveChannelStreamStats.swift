#if canImport(AVFoundation)
import AVFoundation
import CoreModels
import Foundation
import Observation

/// The Stats tab's data: what the engine reports about the picture it is
/// presenting, and — for an HLS channel — what the origin's playlist offers.
///
/// The playlist is fetched once, when the tab first opens, with the same
/// headers the player uses. It is never logged: stream URLs carry credentials.
@MainActor
@Observable
final class LiveChannelStreamStats {
    enum PlaylistState: Equatable {
        case notApplicable
        case loading
        case loaded(HLSPlaylistSummary, masterURL: URL)
        case failed
    }

    private(set) var playlist: PlaylistState = .notApplicable
    private var loadedInput: LiveChannelInput?

    func load(input: LiveChannelInput) async {
        guard loadedInput != input else { return }
        loadedInput = input
        guard case .stream(let url, let headers) = input, url.scheme?.hasPrefix("http") == true else {
            playlist = .notApplicable
            return
        }
        playlist = .loading
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard loadedInput == input else { return }
            guard data.count <= Self.maximumPlaylistBytes,
                  let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U") else {
                // A raw transport stream or a non-HLS origin: nothing to list.
                playlist = .notApplicable
                return
            }
            playlist = .loaded(HLSPlaylistSummary(playlist: text), masterURL: response.url ?? url)
        } catch {
            guard loadedInput == input else { return }
            playlist = .failed
        }
    }

    /// The variant on screen, as far as it can be known.
    ///
    /// AVPlayer playing the origin directly reports the variant it chose in its
    /// access log. When the engine ingests the stream itself it always takes the
    /// highest-bandwidth variant, so that is the answer there.
    func currentVariant(engine: any LiveChannelEngine) -> (variant: HLSPlaylistSummary.Variant, isInferred: Bool)? {
        guard case .loaded(let summary, let masterURL) = playlist, summary.isMaster else { return nil }
        if engine.liveSnapshot.route == .nativeHLS,
           let event = engine.nowPlayingPlayer?.currentItem?.accessLog()?.events.last {
            if let uri = event.uri, let match = summary.variants.first(where: {
                URL(string: $0.uri, relativeTo: masterURL)?.absoluteString == uri
            }) {
                return (match, false)
            }
            if let match = summary.variant(nearestBandwidth: event.indicatedBitrate) { return (match, false) }
        }
        guard let highest = summary.variants.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }
        return (highest, true)
    }

    private static let maximumPlaylistBytes = 1_048_576
}
#endif
