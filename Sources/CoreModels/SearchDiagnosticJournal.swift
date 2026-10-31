import Foundation

/// Consent-scoped search evidence, retained separately from general network activity.
/// Query text, provider identifiers, names, URLs and cursor values never enter this journal.
public final class SearchDiagnosticJournal: @unchecked Sendable {
    public static let shared = SearchDiagnosticJournal()
    @TaskLocal public static var currentSource: Source?

    public enum Outcome: String, Encodable, Sendable { case running, results, empty, failed, cancelled }
    public enum PagingFailure: String, Encodable, Sendable { case emptyPage, missingCursor, repeatedCursor }

    public struct Page: Encodable, Sendable {
        public fileprivate(set) var library: Int?
        public fileprivate(set) var number: Int
        public fileprivate(set) var limit: Int
        public fileprivate(set) var usedCursor: Bool
        public fileprivate(set) var rows: Int?
        public fileprivate(set) var hasMore: Bool?
        public fileprivate(set) var hasNextCursor: Bool?
        public fileprivate(set) var failure: PagingFailure?
    }

    public struct Facts: Encodable, Sendable {
        public fileprivate(set) var source: Int
        public fileprivate(set) var provider: ProviderKind
        public fileprivate(set) var limit: Int
        public fileprivate(set) var disabledLibraryCount: Int
        public fileprivate(set) var availableLibraryCount: Int?
        public fileprivate(set) var excludedLibraryCount: Int?
        public fileprivate(set) var librariesStarted: Int?
        public fileprivate(set) var outcome: Outcome = .running
        public fileprivate(set) var reason: String?
        public fileprivate(set) var resultCount: Int?
        public fileprivate(set) var elapsedMilliseconds: Int = 0
        public fileprivate(set) var pageCount: Int = 0
        public fileprivate(set) var pages: [Page] = []
        public fileprivate(set) var requestCount: Int = 0
        public fileprivate(set) var requests: [ResponseRequestDiagnostic] = []
        public fileprivate(set) var responses: [ResponseDecodingDiagnostic] = []
        public fileprivate(set) var http: [ResponseStatusDiagnostic] = []
        public fileprivate(set) var transport: [ResponseTransportDiagnostic] = []
    }

    public struct Search: Sendable {
        fileprivate let journal: SearchDiagnosticJournal
        fileprivate let generation: UUID
        fileprivate let id: UUID

        public func source(index: Int, provider: ProviderKind, limit: Int, disabledLibraries: Int) -> Source? {
            journal.beginSource(search: self, index: index, provider: provider,
                                limit: limit, disabledLibraries: disabledLibraries)
        }
    }

    public struct Source: Sendable {
        fileprivate let search: Search
        fileprivate let id: UUID

        public func libraries(available: Int, excluded: Int) {
            update {
                $0.facts.availableLibraryCount = max(0, available)
                $0.facts.excludedLibraryCount = max(0, excluded)
                $0.facts.librariesStarted = 0
            }
        }

        public func beginLibrary(index: Int) {
            update {
                $0.library = max(0, index)
                $0.facts.librariesStarted = ($0.facts.librariesStarted ?? 0) + 1
            }
        }

        public func beginPage(limit: Int, usedCursor: Bool) {
            update {
                $0.facts.pageCount += 1
                $0.facts.pages.append(Page(library: $0.library, number: $0.facts.pageCount,
                                          limit: max(0, limit), usedCursor: usedCursor))
                $0.facts.pages = Array($0.facts.pages.suffix(8))
            }
        }

        public func finishPage(rows: Int, hasMore: Bool, hasNextCursor: Bool, failure: PagingFailure?) {
            update {
                guard let index = $0.facts.pages.indices.last else { return }
                $0.facts.pages[index].rows = max(0, rows)
                $0.facts.pages[index].hasMore = hasMore
                $0.facts.pages[index].hasNextCursor = hasNextCursor
                $0.facts.pages[index].failure = failure
            }
        }

        public func request(_ value: ResponseRequestDiagnostic) {
            update {
                $0.facts.requestCount += 1
                $0.facts.requests = Array(($0.facts.requests + [value]).suffix(8))
            }
        }

        public func decoding(_ value: ResponseDecodingDiagnostic) {
            update { $0.facts.responses = Array(($0.facts.responses + [value]).suffix(4)) }
        }

        public func http(_ value: ResponseStatusDiagnostic) {
            update { $0.facts.http = Array(($0.facts.http + [value]).suffix(4)) }
        }

        public func transport(_ value: ResponseTransportDiagnostic) {
            update { $0.facts.transport = Array(($0.facts.transport + [value]).suffix(4)) }
        }

        public func finish(resultCount: Int) {
            search.journal.finish(source: self, resultCount: resultCount, error: nil,
                                  cancelled: Task.isCancelled)
        }

        public func finish(error: AppError) {
            search.journal.finish(source: self, resultCount: nil, error: error,
                                  cancelled: Task.isCancelled || error == .cancelled)
        }

        private func update(_ body: (inout Entry) -> Void) {
            search.journal.lock.withLock {
                guard search.journal.generation == search.generation,
                      var entry = search.journal.active[id] else { return }
                body(&entry)
                search.journal.active[id] = entry
            }
        }
    }

    private struct Entry: Sendable {
        let search: UUID
        let started: UInt64
        let date: Date
        var library: Int?
        var facts: Facts
    }

    public struct Export: Encodable, Sendable {
        public let schema = 1
        public let enabled: Bool
        public let dropped: Int
        public let entries: [ExportEntry]
    }

    public struct ExportEntry: Encodable, Sendable {
        public let ageMilliseconds: Int?
        public let search: String
        public let facts: Facts
    }

    private let lock = NSLock()
    private var generation: UUID?
    private var active: [UUID: Entry] = [:]
    private var completed = DiagnosticRecordBuffer<Entry>()
    private var dropped = 0

    public init() {}

    public func start() {
        lock.withLock {
            if generation == nil { generation = UUID() }
        }
    }

    public func stop() {
        lock.withLock {
            generation = nil
            active.removeAll()
            completed = DiagnosticRecordBuffer()
            dropped = 0
        }
    }

    public func beginSearch() -> Search? {
        lock.withLock {
            guard let generation else { return nil }
            return Search(journal: self, generation: generation, id: UUID())
        }
    }

    private func beginSource(
        search: Search, index: Int, provider: ProviderKind, limit: Int, disabledLibraries: Int
    ) -> Source? {
        lock.withLock {
            guard generation == search.generation else { return nil }
            guard active.count < 32 else {
                dropped = min(1_000_000_000, dropped + 1)
                return nil
            }
            let id = UUID()
            active[id] = Entry(
                search: search.id, started: DispatchTime.now().uptimeNanoseconds, date: Date(),
                facts: Facts(source: max(0, index), provider: provider, limit: max(0, limit),
                             disabledLibraryCount: max(0, disabledLibraries))
            )
            return Source(search: search, id: id)
        }
    }

    private func finish(source: Source, resultCount: Int?, error: AppError?, cancelled: Bool) {
        lock.withLock {
            guard generation == source.search.generation,
                  var entry = active.removeValue(forKey: source.id) else { return }
            entry.facts.elapsedMilliseconds = Self.elapsed(since: entry.started)
            if cancelled {
                entry.facts.outcome = .cancelled
            } else if let error {
                entry.facts.outcome = .failed
                entry.facts.reason = HandoffDiagnostics.errorCode(error)
            } else if let resultCount {
                entry.facts.resultCount = max(0, resultCount)
                entry.facts.outcome = resultCount > 0 ? .results : .empty
            }
            completed.append(entry)
        }
    }

    public func export(scope: DiagnosticExportScope) -> Export {
        lock.withLock {
            let saved = completed.snapshot()
            let entries = (saved.entries.map(\.value) + active.values).sorted { $0.started < $1.started }
            return Export(
                enabled: generation != nil, dropped: dropped + saved.dropped,
                entries: entries.map {
                    var facts = $0.facts
                    if facts.outcome == .running { facts.elapsedMilliseconds = Self.elapsed(since: $0.started) }
                    return ExportEntry(ageMilliseconds: scope.ageMilliseconds(for: $0.date),
                                       search: scope.alias(for: $0.search.uuidString), facts: facts)
                }
            )
        }
    }

    private static func elapsed(since started: UInt64) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        return Int(min(UInt64(PerformanceDiagnostics.maximumMilliseconds), (now - min(now, started)) / 1_000_000))
    }
}
