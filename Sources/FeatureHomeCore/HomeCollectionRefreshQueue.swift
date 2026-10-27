import CoreModels
import Foundation

/// One bounded preview per source, with one delayed follow-up for server automation.
struct HomeCollectionRefreshQueue {
    struct Request {
        let source: HeroCollectionSelection
        let revision: UInt64
        let priority: Int
        let order: Int
        var due: ContinuousClock.Instant
        var isFollowUp = false
    }

    static let previewLimit = 20
    static let spacing: Duration = .milliseconds(250)
    private let debounce: Duration
    private let followUp: Duration
    private var revision: UInt64 = 0
    private var requests: [HeroCollectionSelection.ID: Request] = [:]
    var isEmpty: Bool { requests.isEmpty }

    init(debounce: Duration = .milliseconds(750), followUp: Duration = .seconds(3)) {
        self.debounce = debounce
        self.followUp = followUp
    }

    mutating func enqueue(_ sections: [CollectionSection], now: ContinuousClock.Instant) {
        revision &+= 1
        for (index, section) in sections.enumerated() {
            let priority = Self.isWatchlistLike(section.title) || Self.isWatchlistLike(section.source.title) ? 0 : 1
            let previous = requests[section.source.id].flatMap { $0.revision == revision ? $0 : nil }
            requests[section.source.id] = Request(
                source: section.source, revision: revision,
                priority: min(previous?.priority ?? priority, priority),
                order: previous?.order ?? index,
                due: now.advanced(by: debounce)
            )
        }
    }

    func next(now: ContinuousClock.Instant) -> Request? {
        let ready = requests.values.filter { $0.due <= now }
        if !ready.isEmpty {
            return ready.min {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                if $0.due != $1.due { return $0.due < $1.due }
                return $0.order < $1.order
            }
        }
        return requests.values.min { $0.due < $1.due }
    }

    func contains(_ request: Request) -> Bool {
        requests[request.source.id]?.revision == request.revision
    }

    mutating func discard(_ request: Request) {
        guard contains(request) else { return }
        requests[request.source.id] = nil
    }

    mutating func finish(_ request: Request, now: ContinuousClock.Instant) {
        guard contains(request) else { return }
        if request.isFollowUp {
            requests[request.source.id] = nil
        } else {
            var followUpRequest = request
            followUpRequest.isFollowUp = true
            followUpRequest.due = now.advanced(by: followUp)
            requests[request.source.id] = followUpRequest
        }
    }

    private static func isWatchlistLike(_ name: String) -> Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { $0.isLetter || $0.isNumber }
        return ["watchlist", "watchlater", "towatch", "watchnext", "watchqueue", "wishlist", "favorites", "favourites", "mylist"]
            .contains { normalized.contains($0) }
    }
}
