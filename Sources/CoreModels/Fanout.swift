import Foundation

/// Publication policy for a fan-out fetch.
public enum FanoutPublication: Sendable, Equatable {
    /// Publish only once every source has answered. Use when a partial aggregate
    /// would look wrong (a merged "Next Up" list that reorders as servers report).
    case completeOnly
    /// Publish the merged value after each source answers.
    ///
    /// The merge function must therefore be **stable**: same inputs in the same
    /// order produce the same value, and adding one source's items must refine the
    /// result rather than reshuffle it. A merge that reorders on every call turns
    /// progressive publication into visible churn.
    case progressive
}

/// Result of one fan-out fetch.
public struct FanoutResult<Value: Sendable>: Sendable {
    public var value: Value
    /// Source identifier → the failure it reported. A failed source is not
    /// pending; it contributed nothing.
    public var failures: [String: AppError]
    /// Sources that have not answered yet.
    public var pending: Set<String>

    public var isComplete: Bool { pending.isEmpty }

    public init(value: Value, failures: [String: AppError], pending: Set<String>) {
        self.value = value
        self.failures = failures
        self.pending = pending
    }
}

/// One fetch/merge path for every surface that reads from more than one account.
///
/// The problem this exists to stop: Home, the hero, the detail page and the
/// library rails each grew their own "loop over accounts and merge" code. Those
/// copies disagree about ordering, about what an empty answer means, and about
/// when to publish, so a single-server install and a multi-server install render
/// differently for reasons spread across several files.
///
/// Two rules are encoded here rather than left to callers:
///
/// - **One source is not a special case, it is the fast path.** With a single
///   source there is no aggregation, no merge delay and no partial state: the
///   fetch is awaited once and published once. Multi-source is the general case;
///   single-source is not a degraded variant of it.
/// - **Completeness is explicit.** `FanoutResult.isComplete` separates "every
///   account answered" from "nothing arrived yet" — the distinction every
///   cached-first surface needs, and which most of them were guessing at.
public enum Fanout {
    /// Runs `fetch` for each source and merges the values that arrived.
    ///
    /// - Parameters:
    ///   - sources: stable identifiers (account ids). Their order defines merge
    ///     order, so a different arrival sequence cannot reorder the result.
    ///   - publication: when intermediate values are published.
    ///   - fetch: per-source work; a failure contributes nothing but is reported in
    ///     `failures`.
    ///   - merge: combines the values that arrived, in `sources` order.
    ///   - onProgress: called for the first publication, after each arrival while
    ///     publishing progressively, and once at the end when publishing only on
    ///     completion.
    public static func run<Element: Sendable, Value: Sendable>(
        sources: [String],
        publication: FanoutPublication = .progressive,
        fetch: @escaping @Sendable (String) async -> Result<Element, AppError>,
        merge: @Sendable ([Element]) -> Value,
        onProgress: @Sendable (FanoutResult<Value>) async -> Void
    ) async -> FanoutResult<Value> {
        var uniqueSources: [String] = []
        for source in sources where !uniqueSources.contains(source) {
            uniqueSources.append(source)
        }

        // Fast path: one source is the common case on a single-server install and
        // must not pay for grouping, task setup or a second publication.
        if uniqueSources.count <= 1 {
            guard let source = uniqueSources.first else {
                let empty = FanoutResult(value: merge([]), failures: [:], pending: [])
                await onProgress(empty)
                return empty
            }
            var failures: [String: AppError] = [:]
            var elements: [Element] = []
            switch await fetch(source) {
            case let .success(element): elements.append(element)
            case let .failure(error): failures[source] = error
            }
            let result = FanoutResult(value: merge(elements), failures: failures, pending: [])
            await onProgress(result)
            return result
        }

        var values: [String: Element] = [:]
        var failures: [String: AppError] = [:]
        var pending = Set(uniqueSources)
        var published = false

        await withTaskGroup(of: (String, Result<Element, AppError>).self) { group in
            for source in uniqueSources {
                group.addTask { (source, await fetch(source)) }
            }
            for await (source, outcome) in group {
                pending.remove(source)
                switch outcome {
                case let .success(element):
                    values[source] = element
                case let .failure(error):
                    failures[source] = error
                }
                let snapshot = FanoutResult(
                    value: merge(uniqueSources.compactMap { values[$0] }),
                    failures: failures,
                    pending: pending
                )
                if publication == .progressive || snapshot.isComplete {
                    published = true
                    await onProgress(snapshot)
                }
            }
        }

        let final = FanoutResult(
            value: merge(uniqueSources.compactMap { values[$0] }),
            failures: failures,
            pending: []
        )
        if !published {
            await onProgress(final)
        }
        return final
    }
}
