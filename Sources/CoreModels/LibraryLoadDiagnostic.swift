import Foundation

/// Only allowlisted response facts may enter a user-shared library report.
public struct ResponseDecodingDiagnostic: Encodable, Equatable, Sendable {
    public enum Route: String, Encodable, Sendable {
        case movieRecommendations, libraryHubs, other
        case collectionCandidates, collectionLibraryScope, collectionMembers
        case continueWatching, continueWatchingItems, continueWatchingHub, onDeck
        case resumeItems, nextUp
        case itemDetail, playbackInventory, serverDiscovery
    }
    public enum Payload: String, Encodable, Sendable { case empty, object, array, scalar, nonJSON }
    public enum Reason: String, Encodable, Sendable { case missingKey, wrongType, nullValue, corruptedData, other }
    public enum ValueType: String, Encodable, Sendable { case string, integer, number, boolean, array, object, other }

    public let route: Route
    public let httpStatus: Int
    public let bytes: Int
    public let payload: Payload
    public let reason: Reason
    public let expected: ValueType?
    public let path: String

    public init(route: Route, httpStatus: Int, bytes: Int, payload: Payload, error: Error) {
        self.route = route
        self.httpStatus = httpStatus
        self.bytes = bytes
        self.payload = payload
        let keys: [CodingKey]
        switch error {
        case let DecodingError.keyNotFound(key, context):
            reason = .missingKey
            expected = nil
            keys = context.codingPath + [key]
        case let DecodingError.typeMismatch(type, context):
            reason = .wrongType
            expected = Self.valueType(type)
            keys = context.codingPath
        case let DecodingError.valueNotFound(type, context):
            reason = .nullValue
            expected = Self.valueType(type)
            keys = context.codingPath
        case let DecodingError.dataCorrupted(context):
            reason = .corruptedData
            expected = nil
            keys = context.codingPath
        default:
            reason = .other
            expected = nil
            keys = []
        }
        // Dynamic dictionary keys and decoder descriptions can contain credentials.
        let fields: Set<String> = [
            "Items", "Id", "Name", "Type", "RecommendationType", "CategoryId", "BaselineItemName",
            "TotalRecordCount", "UserData", "MediaSources", "MediaStreams", "ProviderIds",
            "RunTimeTicks", "Size", "IndexNumber", "ParentIndexNumber", "ProductionYear",
            "MediaContainer", "Metadata", "Hub", "Directory", "ratingKey", "key", "type",
            "title", "size", "totalSize", "offset", "viewOffset", "duration",
            "ErrorCode", "PlaySessionId", "Container", "Protocol", "Path", "IsRemote", "Bitrate",
            "SupportsDirectPlay", "SupportsDirectStream", "SupportsTranscoding",
            "Index", "Codec", "Language", "Width", "Height", "Channels", "SampleRate",
            "Media", "Part", "Stream"
        ]
        path = keys.isEmpty ? "<root>" : keys.prefix(24).map {
            if let index = $0.intValue, $0.stringValue == "Index \(index)" { return "[\(index)]" }
            return fields.contains($0.stringValue) ? $0.stringValue : "<field>"
        }.joined(separator: ".")
    }

    private static func valueType(_ type: Any.Type) -> ValueType {
        if type == String.self { return .string }
        if type == Bool.self { return .boolean }
        if type == Int.self || type == Int64.self || type == Int32.self
            || type == UInt.self || type == UInt64.self { return .integer }
        if type == Double.self || type == Float.self { return .number }
        if String(describing: type).hasPrefix("Array<") { return .array }
        if String(describing: type).hasPrefix("Dictionary<") { return .object }
        return .other
    }
}

public struct LibraryPagingDiagnostic: Encodable, Equatable, Sendable {
    public enum Stage: String, Encodable, Sendable {
        case collectionCandidates, libraryScope, collectionMembers
        case continueWatchingItems, continueWatchingHub, onDeck
    }
    public enum Reason: String, Encodable, Sendable {
        case negativeTotal, emptyID, duplicateInPage, emptyBeforeTotal, nonAdvancing, nonPrefixOverlap
        case unexpectedItemType, itemsPastEnd
        case changedTotal, sizeMismatch, offsetMismatch, repeatedItem, contradictoryMore
    }
    public let stage: Stage
    public let reason: Reason
    public let start: Int
    public let rows: Int
    public let total: Int?

    public init(stage: Stage, reason: Reason, start: Int, rows: Int, total: Int?) {
        self.stage = stage
        self.reason = reason
        self.start = start
        self.rows = rows
        self.total = total
    }
}

public struct ResponseTransportDiagnostic: Encodable, Equatable, Sendable {
    public let route: ResponseDecodingDiagnostic.Route
    public let urlErrorCode: Int

    public init(route: ResponseDecodingDiagnostic.Route, urlErrorCode: Int) {
        self.route = route
        self.urlErrorCode = urlErrorCode
    }
}

public struct ResponseStatusDiagnostic: Encodable, Equatable, Sendable {
    public let route: ResponseDecodingDiagnostic.Route
    public let httpStatus: Int

    public init(route: ResponseDecodingDiagnostic.Route, httpStatus: Int) {
        self.route = route
        self.httpStatus = httpStatus
    }
}

public struct ResponseRequestDiagnostic: Encodable, Equatable, Sendable {
    public let route: ResponseDecodingDiagnostic.Route
    public let method: String
    public let elapsedMilliseconds: Int
    public let httpStatus: Int?
    public let urlErrorCode: Int?
    public let bytes: Int
    public let format: PlaybackFailureDiagnostic.Format
    public let requestTimeoutMilliseconds: Int
    public let resourceTimeoutMilliseconds: Int

    public init(
        route: ResponseDecodingDiagnostic.Route, method: String, elapsedMilliseconds: Int,
        httpStatus: Int?, urlErrorCode: Int?, bytes: Int, format: PlaybackFailureDiagnostic.Format,
        requestTimeoutMilliseconds: Int, resourceTimeoutMilliseconds: Int
    ) {
        self.route = route
        self.method = ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method) ? method : "other"
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.httpStatus = httpStatus
        self.urlErrorCode = urlErrorCode
        self.bytes = max(0, bytes)
        self.format = format
        self.requestTimeoutMilliseconds = max(0, requestTimeoutMilliseconds)
        self.resourceTimeoutMilliseconds = max(0, resourceTimeoutMilliseconds)
    }
}

public struct ResponseValidationDiagnostic: Encodable, Equatable, Sendable {
    public enum Reason: String, Encodable, Sendable {
        case emptySources, missingSourceID, blankSourceID, duplicateSourceID, unavailablePlaceholder
        case serverRejected, missingMetadata
        case itemIDMismatch, itemKindMismatch, accountMismatch
    }

    public let route: ResponseDecodingDiagnostic.Route
    public let reason: Reason
    public let sourceCount: Int?

    public init(route: ResponseDecodingDiagnostic.Route, reason: Reason, sourceCount: Int? = nil) {
        self.route = route
        self.reason = reason
        self.sourceCount = sourceCount.map { max(0, $0) }
    }
}

public struct LibraryLoadDiagnostic: Equatable, Sendable {
    public enum Operation: String, Encodable, Sendable { case libraryRecommendations, libraryBrowse, homeContinueWatching }
    public enum Section: String, Encodable, Sendable {
        case continueWatching, recommendations, recentlyAdded
        case browse, collections, playlists, collectionMembers, playlistMembers

        public var title: LocalizedStringResource {
            switch self {
            case .continueWatching: "Continue Watching"
            case .recommendations: "Recommended"
            case .recentlyAdded: "Recently Added"
            case .browse: "Browse"
            case .collections, .collectionMembers: "Collections"
            case .playlists, .playlistMembers: "Playlists"
            }
        }
    }

    public struct Failure: Equatable, Sendable {
        public let section: Section
        public let error: AppError
        public let responses: [ResponseDecodingDiagnostic]
        public let paging: [LibraryPagingDiagnostic]
        public let transport: [ResponseTransportDiagnostic]
        public let http: [ResponseStatusDiagnostic]

        public init(
            section: Section, error: AppError,
            responses: [ResponseDecodingDiagnostic] = [], paging: [LibraryPagingDiagnostic] = [],
            transport: [ResponseTransportDiagnostic] = [], http: [ResponseStatusDiagnostic] = []
        ) {
            self.section = section
            self.error = error
            self.responses = Array(responses.suffix(4))
            self.paging = Array(paging.suffix(4))
            self.transport = Array(transport.suffix(4))
            self.http = Array(http.suffix(4))
        }
    }

    public let provider: ProviderKind
    public let operation: Operation
    public let failures: [Failure]

    public init(provider: ProviderKind, operation: Operation = .libraryRecommendations, failures: [Failure]) {
        self.provider = provider
        self.operation = operation
        self.failures = failures
    }

    // l10n:content — closed-vocabulary, credential-free support protocol
    public var supportText: String {
        var fields = ["format=plozz-library-1", "operation=\(operation.rawValue)", "provider=\(provider.rawValue)"]
        for (index, failure) in failures.enumerated() {
            let prefix = "failure_\(index)"
            fields += ["\(prefix).section=\(failure.section.rawValue)", "\(prefix).reason=\(Self.code(failure.error))"]
            for (responseIndex, response) in failure.responses.enumerated() {
                let request = "\(prefix).response_\(responseIndex)"
                fields += [
                    "\(request).route=\(response.route.rawValue)", "\(request).http_status=\(response.httpStatus)",
                    "\(request).bytes=\(response.bytes)", "\(request).payload=\(response.payload.rawValue)",
                    "\(request).decode=\(response.reason.rawValue)", "\(request).path=\(response.path)"
                ]
                if let expected = response.expected { fields.append("\(request).expected=\(expected.rawValue)") }
            }
            for (pageIndex, page) in failure.paging.enumerated() {
                let key = "\(prefix).page_\(pageIndex)"
                fields += [
                    "\(key).stage=\(page.stage.rawValue)", "\(key).reason=\(page.reason.rawValue)",
                    "\(key).start=\(page.start)", "\(key).rows=\(page.rows)"
                ]
                if let total = page.total { fields.append("\(key).total=\(total)") }
            }
            for (requestIndex, request) in failure.transport.enumerated() {
                let key = "\(prefix).transport_\(requestIndex)"
                fields += ["\(key).route=\(request.route.rawValue)", "\(key).url_error_code=\(request.urlErrorCode)"]
            }
            for (requestIndex, request) in failure.http.enumerated() {
                let key = "\(prefix).http_\(requestIndex)"
                fields += ["\(key).route=\(request.route.rawValue)", "\(key).status=\(request.httpStatus)"]
            }
        }
        return fields.joined(separator: "\n")
    }

    private static func code(_ error: AppError) -> String {
        switch error {
        case .serverUnreachable: "serverUnreachable"
        case .invalidResponse: "invalidResponse"
        case .unauthorized: "unauthorized"
        case .accessRestricted: "accessRestricted"
        case .invalidCredentials: "invalidCredentials"
        case .notFound: "notFound"
        case .conflict: "conflict"
        case .rateLimited: "rateLimited"
        case .quickConnectUnavailable: "quickConnectUnavailable"
        case .quickConnectExpired: "quickConnectExpired"
        case .cancelled: "cancelled"
        case .decoding: "decoding"
        case .unknown: "unknown"
        }
    }
}
