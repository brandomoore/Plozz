import CoreModels
import CoreNetworking
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import zlib

public struct LiveTVGuideImport: Codable, Sendable {
    public let programs: [LiveTVPrototypeProgram]
    public let matchedChannelCount: Int
    public let guideChannelCount: Int
    public let programCount: Int
    public let coverageStart: Date?
    public let coverageEnd: Date?
    public let matches: [String: LiveTVGuideMatch]
    public let guideChannels: [String: [String]]

    public init(
        programs: [LiveTVPrototypeProgram],
        matchedChannelCount: Int,
        guideChannelCount: Int,
        programCount: Int,
        coverageStart: Date?,
        coverageEnd: Date?,
        matches: [String: LiveTVGuideMatch] = [:],
        guideChannels: [String: [String]] = [:]
    ) {
        self.programs = programs
        self.matchedChannelCount = matchedChannelCount
        self.guideChannelCount = guideChannelCount
        self.programCount = programCount
        self.coverageStart = coverageStart
        self.coverageEnd = coverageEnd
        self.matches = matches
        self.guideChannels = guideChannels
    }
}

public struct LiveTVXMLTVParser: Sendable {
    public static let maximumCompressedBytes = XMLTVResourceLimits.compressedBytes
    public static let maximumExpandedBytes = XMLTVResourceLimits.expandedBytes
    public static let maximumGuideChannels = 100_000
    public static let maximumPrograms = 4_000_000
    public static let maximumTextLength = 16_384
    public static let maximumRetainedPrograms = 250_000
    public static let maximumRetainedTextBytes = 32 * 1_024 * 1_024

    private let maximumExpandedBytes: Int
    private let provider: LiveTVGuideProvider?
    private let preferredLanguage: String?
    private let isCancelled: @Sendable () -> Bool

    public init(
        maximumExpandedBytes: Int = Self.maximumExpandedBytes,
        provider: LiveTVGuideProvider? = nil,
        preferredLanguage: String? = LanguageMatch.deviceLanguageCode,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.maximumExpandedBytes = maximumExpandedBytes
        self.provider = provider
        self.isCancelled = isCancelled
        self.preferredLanguage = LanguageMatch.normalized(
            preferredLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func parse(
        gzipData: Data,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        lookbackDays: Int = 1, lookaheadDays: Int = 7
    ) throws -> LiveTVGuideImport {
        guard gzipData.count <= Self.maximumCompressedBytes else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: {
                try BoundedGzipInputStream(
                    compressedStream: InputStream(data: gzipData),
                    maximumExpandedBytes: maximumExpandedBytes, isCancelled: isCancelled
                )
            },
            channels: channels,
            now: now, overrides: overrides, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
        )
    }

    public func parseXML(
        data: Data,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        lookbackDays: Int = 1, lookaheadDays: Int = 7
    ) throws -> LiveTVGuideImport {
        guard data.count <= maximumExpandedBytes else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: { InputStream(data: data) },
            channels: channels,
            now: now, overrides: overrides, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays
        )
    }

    public func parseIndexed(
        data: Data, channels: [LiveTVPrototypeChannel], now: Date,
        overrides: [String: String] = [:], lookbackDays: Int = 1, lookaheadDays: Int = 7,
        indexGuideStations: Bool = false,
        sink: @escaping (LiveTVPrototypeProgram) throws -> Void
    ) throws -> LiveTVGuideImport {
        guard (0...7).contains(lookbackDays), (1...28).contains(lookaheadDays) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        let gzip = data.starts(with: [0x1f, 0x8b])
        guard data.count <= (gzip ? Self.maximumCompressedBytes : maximumExpandedBytes) else {
            throw LiveTVSourceImportError.guideTooLarge
        }
        return try parseXML(
            makeStream: {
                if gzip {
                    return try BoundedGzipInputStream(
                        compressedStream: InputStream(data: data), maximumExpandedBytes: maximumExpandedBytes,
                        isCancelled: isCancelled
                    )
                }
                return InputStream(data: data)
            }, channels: channels, now: now, overrides: overrides,
            indexGuideStations: indexGuideStations,
            lookbackDays: lookbackDays, lookaheadDays: lookaheadDays, sink: sink
        )
    }

    private func parseXML(
        makeStream: () throws -> InputStream,
        channels: [LiveTVPrototypeChannel],
        now: Date,
        overrides: [String: String] = [:],
        indexGuideStations: Bool = false,
        lookbackDays: Int = 1, lookaheadDays: Int = 7,
        sink: ((LiveTVPrototypeProgram) throws -> Void)? = nil
    ) throws -> LiveTVGuideImport {
        try checkCancellation()
        guard (0...7).contains(lookbackDays), (1...28).contains(lookaheadDays) else {
            throw LiveTVSourceImportError.invalidGuide
        }
        let metadataDelegate = XMLTVDelegate(isCancelled: isCancelled)
        try parseXML(stream: makeStream(), delegate: metadataDelegate)
        try checkCancellation()
        if metadataDelegate.skippedChannelDeclarations > 0 {
            PlozzLog.networking.info(
                "XMLTV_PARSE pass=metadata outcome=succeeded skippedChannels=\(metadataDelegate.skippedChannelDeclarations)"
                    + " reason=channelID mergedChannels=\(metadataDelegate.mergedChannelDeclarations)"
            )
        } else if metadataDelegate.mergedChannelDeclarations > 0 {
            PlozzLog.networking.info(
                "XMLTV_PARSE pass=metadata outcome=succeeded mergedChannels=\(metadataDelegate.mergedChannelDeclarations)"
            )
        }
        var guideChannels = metadataDelegate.guideChannels
        for id in metadataDelegate.undeclaredGuideIDs { guideChannels[id] = [] }
        let matcher = LiveTVGuideMatcher(provider: provider)
        let matching = indexGuideStations
            ? (channelsByGuideID: [String: [LiveTVPrototypeChannel]](), assignments: [String: LiveTVGuideMatch]())
            : matcher.matching(channels: channels, guideChannels: guideChannels, overrides: overrides)
        var channelsByGuideID = matching.channelsByGuideID
        if indexGuideStations {
            // Matching depends on the requested batch. Retain potential stations,
            // then apply the unchanged matcher to that exact batch at query time.
            let ids = Set(channels.compactMap(\.guideID))
            let names = Set(channels.map { matcher.normalizedDisplayName($0.guideName ?? $0.name) })
            channelsByGuideID = [:]
            for (id, stationNames) in guideChannels where ids.contains(id)
                || stationNames.contains(where: { names.contains(matcher.normalizedDisplayName($0)) }) {
                channelsByGuideID[id] = [LiveTVPrototypeChannel(
                    id: id, number: 0, name: stationNames.first ?? id, category: "Live TV",
                    symbol: "tv", accent: 0, source: .iptv, tagline: "", guideID: id
                )]
            }
        }
        try checkCancellation()
        let programmeDelegate = XMLTVDelegate(
            channelsByGuideID: channelsByGuideID,
            initialRetainedTextBytes: metadataDelegate.retainedTextBytes,
            preferredLanguage: preferredLanguage,
            now: now, lookbackDays: lookbackDays, lookaheadDays: lookaheadDays,
            totalPrograms: metadataDelegate.sourceProgramCount, sink: sink, isCancelled: isCancelled
        )
        try parseXML(stream: makeStream(), delegate: programmeDelegate)
        try checkCancellation()
        return try programmeDelegate.makeResult(
            guideChannelCount: guideChannels.count,
            assignments: matching.assignments,
            guideChannels: guideChannels
        )
    }

    private func parseXML(stream: InputStream, delegate: XMLTVDelegate) throws {
        delegate.reportProgress(force: true)
        stream.open()
        defer { stream.close() }
        let guardedStream = EntityRejectingXMLInputStream(source: stream, isCancelled: isCancelled)
        delegate.didStartRoot = { guardedStream.inspectDeclarations = false }
        defer { delegate.didStartRoot = nil }
        let parser = XMLParser(stream: guardedStream)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let parsed = parser.parse()
        if parsed { delegate.reportProgress(force: true) }
        if let streamError = guardedStream.streamError as? LiveTVSourceImportError {
            delegate.logFailure(
                parser, error: streamError,
                reason: guardedStream.rejectedEntity ? .entity : .stream
            )
            throw streamError
        }
        guard parsed, delegate.error == nil else {
            delegate.logFailure(parser, error: delegate.error ?? .invalidGuide)
            if let sinkError = delegate.sinkError { throw sinkError }
            throw delegate.error ?? LiveTVSourceImportError.invalidGuide
        }
    }

    private func checkCancellation() throws {
        if isCancelled() {
            throw LiveTVSourceImportError.cancelled
        }
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    var didStartRoot: (() -> Void)?
    private let isCancelled: @Sendable () -> Bool
    private enum Pass: String {
        case metadata
        case programmes
    }
    enum FailureReason: String {
        case syntax, structure, root, entity, encoding, stream
    }

    private let pass: Pass
    private let channelsByGuideID: [String: [LiveTVPrototypeChannel]]
    private let lowerBound: Date?
    private let upperBound: Date?
    private let preferredLanguage: String?
    private(set) var guideChannels: [String: [String]] = [:]
    private var mergedChannelNames: [String: Set<String>] = [:]
    private(set) var undeclaredGuideIDs = Set<String>()
    private(set) var retainedTextBytes: Int
    private var programs: [LiveTVPrototypeProgram] = []
    private var retainedProgramCount = 0
    private let sink: ((LiveTVPrototypeProgram) throws -> Void)?
    private(set) var sinkError: (any Error)?
    private var seenProgramIDs = Set<String>()
    private var currentChannelID: String?
    private var currentChannelNames: [String] = []
    private var currentChannelTextBytes = 0
    private var insideChannel = false
    private var insideProgramme = false
    private var currentProgram: PendingProgram?
    private var missingEndPrograms: [String: PendingProgram] = [:]
    private var missingEndTextBytes = 0
    private var parsedDates: [String: Date] = [:]
    private var currentElement: String?
    private var currentElementDepth: Int?
    private var currentTextPriority = 2
    private var selectedTextPriorities: [String: Int] = [:]
    private var text = ""
    private var truncatedDescription = false
    private var truncatedDescriptions = 0
    private var sawTV = false
    private var closedTV = false
    private var depth = 0
    private var channelDeclarationCount = 0
    private(set) var sourceProgramCount = 0
    private var totalPrograms: Int?
    private let progress = ServerLiveTVGuideProgress.report
    private var lastProgress = ContinuousClock.now
    private(set) var mergedChannelDeclarations = 0
    private(set) var skippedChannelDeclarations = 0
    private var failureReason = FailureReason.structure
    private var parseErrorCode: Int?
    private(set) var error: LiveTVSourceImportError?
    private(set) var coverageStart: Date?
    private(set) var coverageEnd: Date?

    func logFailure(
        _ parser: XMLParser, error: LiveTVSourceImportError, reason: FailureReason? = nil
    ) {
        guard error != .cancelled else { return }
        let category: String
        switch error {
        case .guideTooLarge: category = "limit"
        case .cacheFailed: category = "storage"
        default: category = (reason ?? failureReason).rawValue
        }
        // XMLParser's error description can contain feed content and credentialed URLs.
        let code = parseErrorCode ?? parser.parserError.map { ($0 as NSError).code }
        PlozzLog.networking.error(
            "XMLTV_PARSE pass=\(pass.rawValue) outcome=failed reason=\(category)"
                + " code=\(code.map(String.init) ?? "unknown")"
                + " line=\(parser.lineNumber) column=\(parser.columnNumber)"
                + " channels=\(channelDeclarationCount) programmes=\(sourceProgramCount)"
                + " skippedChannels=\(skippedChannelDeclarations)"
        )
    }

    init(isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelled = isCancelled
        pass = .metadata
        channelsByGuideID = [:]
        lowerBound = nil
        upperBound = nil
        preferredLanguage = nil
        retainedTextBytes = 0
        sink = nil
        super.init()
    }

    init(
        channelsByGuideID: [String: [LiveTVPrototypeChannel]],
        initialRetainedTextBytes: Int,
        preferredLanguage: String?,
        now: Date, lookbackDays: Int = 1, lookaheadDays: Int = 7,
        totalPrograms: Int? = nil,
        sink: ((LiveTVPrototypeProgram) throws -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        self.isCancelled = isCancelled
        pass = .programmes
        self.channelsByGuideID = channelsByGuideID
        self.preferredLanguage = preferredLanguage
        lowerBound = now.addingTimeInterval(-Double(lookbackDays) * 86_400)
        upperBound = now.addingTimeInterval(Double(lookaheadDays) * 86_400)
        retainedTextBytes = initialRetainedTextBytes
        self.sink = sink
        self.totalPrograms = totalPrograms
        super.init()
    }

    func reportProgress(force: Bool = false) {
        guard let progress, force || ContinuousClock.now - lastProgress >= .milliseconds(250) else { return }
        lastProgress = .now
        progress(.init(
            stage: pass == .metadata ? .readingGuide : .preparingListings,
            completed: sourceProgramCount, total: totalPrograms
        ))
    }

    func makeResult(
        guideChannelCount: Int,
        assignments: [String: LiveTVGuideMatch],
        guideChannels: [String: [String]]
    ) throws -> LiveTVGuideImport {
        if isCancelled() {
            throw LiveTVSourceImportError.cancelled
        }
        programs.sort {
            ($0.channelID, $0.start, $0.end, $0.title, $0.id)
                < ($1.channelID, $1.start, $1.end, $1.title, $1.id)
        }
        if isCancelled() {
            throw LiveTVSourceImportError.cancelled
        }
        if truncatedDescriptions > 0 {
            PlozzLog.networking.info(
                "XMLTV_PARSE pass=programmes outcome=succeeded truncatedDescriptions=\(truncatedDescriptions)"
            )
        }
        return LiveTVGuideImport(
            programs: programs,
            matchedChannelCount: assignments.count,
            guideChannelCount: guideChannelCount,
            programCount: retainedProgramCount,
            coverageStart: coverageStart,
            coverageEnd: coverageEnd,
            matches: assignments,
            guideChannels: guideChannels
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard error == nil else {
            parser.abortParsing()
            return
        }
        if isCancelled() {
            error = .cancelled
            parser.abortParsing()
            return
        }
        let parentDepth = depth
        depth += 1
        if parentDepth == 0 {
            guard elementName == "tv", !sawTV, !closedTV else {
                failureReason = .root
                error = .invalidGuide
                parser.abortParsing()
                return
            }
            sawTV = true
            didStartRoot?()
            return
        }
        if elementName == "tv" {
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        if parentDepth == 1 {
            switch elementName {
            case "channel":
                channelDeclarationCount += 1
                guard channelDeclarationCount <= LiveTVXMLTVParser.maximumGuideChannels else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                guard case .metadata = pass else { return }
                insideChannel = true
                let rawIdentifier = attributeDict["id"]
                guard (rawIdentifier?.count ?? 0) <= 4_096 else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                guard let rawIdentifier,
                      !rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    skippedChannelDeclarations += 1
                    return
                }
                currentChannelID = rawIdentifier
                currentChannelNames = []
                currentChannelTextBytes = 0
            case "programme":
                sourceProgramCount += 1
                guard sourceProgramCount <= LiveTVXMLTVParser.maximumPrograms else {
                    error = .guideTooLarge
                    parser.abortParsing()
                    return
                }
                if case .metadata = pass {
                    if let id = bounded(attributeDict["channel"], maximum: 4_096),
                       guideChannels[id] == nil, !undeclaredGuideIDs.contains(id) {
                        guard guideChannels.count + undeclaredGuideIDs.count < LiveTVXMLTVParser.maximumGuideChannels,
                              retainedTextBytes + id.utf8.count <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                            error = .guideTooLarge
                            parser.abortParsing()
                            return
                        }
                        undeclaredGuideIDs.insert(id)
                        retainedTextBytes += id.utf8.count
                    }
                    return
                }
                insideProgramme = true
                selectedTextPriorities.removeAll(keepingCapacity: true)
                guard let guideChannelID = bounded(attributeDict["channel"], maximum: 4_096),
                      let startText = bounded(attributeDict["start"], maximum: 64),
                      let start = parsedDate(startText)
                else {
                    currentProgram = nil
                    return
                }
                let end: Date
                if let stop = attributeDict["stop"] {
                    guard let text = bounded(stop, maximum: 64), let parsed = parsedDate(text),
                          parsed > start else { currentProgram = nil; return }
                    end = parsed
                } else {
                    end = start
                }
                if var previous = missingEndPrograms.removeValue(forKey: guideChannelID) {
                    missingEndTextBytes -= previous.textBytes
                    // Missing stops are inferred only from the next valid start for the
                    // same XMLTV channel, strictly increasing and at most six hours.
                    // Out-of-order, final and discontinuous entries remain unscheduled.
                    if start > previous.start, start.timeIntervalSince(previous.start) <= 6 * 3_600 {
                        previous.end = start
                        previous.details.endWasInferred = true
                        emitProgramme(previous, parser: parser)
                        if error != nil { return }
                    }
                }
                coverageStart = min(coverageStart ?? start, start)
                if end > start { coverageEnd = max(coverageEnd ?? end, end) }
                guard let lowerBound, let upperBound,
                      start < upperBound, (end > start ? end : start.addingTimeInterval(6 * 3_600)) > lowerBound,
                      channelsByGuideID[guideChannelID] != nil
                else {
                    currentProgram = nil
                    return
                }
                currentProgram = PendingProgram(
                    guideChannelID: guideChannelID,
                    title: "",
                    subtitle: "",
                    start: start,
                    end: end
                )
            default:
                break
            }
            return
        }
        if parentDepth == 2 {
            switch pass {
            case .metadata where insideChannel && elementName == "display-name":
                beginText(for: elementName)
            case .programmes where insideProgramme
                && ["title", "sub-title", "desc", "episode-num", "category", "language"].contains(elementName):
                beginText(for: elementName, language: attributeDict["lang"])
                if let language = bounded(attributeDict["lang"], maximum: 64),
                   (currentProgram?.details.languages.count ?? 0) < 32,
                   currentProgram?.details.languages.contains(language) == false {
                    currentProgram?.details.languages.append(language)
                }
            case .programmes where insideProgramme && elementName == "icon":
                if let address = bounded(attributeDict["src"], maximum: 4_096),
                   let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                   url.user == nil, url.password == nil {
                    currentProgram?.details.artworkURL = url
                }
            default:
                break
            }
            return
        }
        if parentDepth == 3, insideProgramme, elementName == "value" {
            beginText(for: elementName)
        }
        if elementName == "channel" || elementName == "programme" {
            error = .invalidGuide
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        if currentElement == "desc" {
            guard currentProgram != nil, !truncatedDescription else { return }
            var remaining = LiveTVXMLTVParser.maximumTextLength - text.utf8.count
            if string.utf8.count > remaining {
                truncatedDescription = true
                truncatedDescriptions += 1
                // Optional prose must not invalidate an otherwise usable schedule.
                for scalar in string.unicodeScalars {
                    let size = String(scalar).utf8.count
                    guard size <= remaining else { break }
                    text.unicodeScalars.append(scalar)
                    remaining -= size
                }
                return
            }
        }
        guard text.utf8.count + string.utf8.count <= LiveTVXMLTVParser.maximumTextLength else {
            error = .guideTooLarge
            parser.abortParsing()
            return
        }
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            failureReason = .encoding
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        self.parser(parser, foundCharacters: string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard depth > 0 else {
            error = .invalidGuide
            parser.abortParsing()
            return
        }
        depth -= 1
        let elementDepth = depth

        if currentElement == elementName, currentElementDepth == elementDepth {
            switch elementName {
            case "display-name":
                guard currentChannelID != nil else { break }
                if let value = normalizedText(text) {
                    let byteCount = value.utf8.count
                    guard retainedTextBytes + currentChannelTextBytes + byteCount
                        <= LiveTVXMLTVParser.maximumRetainedTextBytes
                    else {
                        error = .guideTooLarge
                        parser.abortParsing()
                        return
                    }
                    currentChannelNames.append(value)
                    currentChannelTextBytes += byteCount
                }
            case "title", "sub-title", "desc":
                if currentProgram != nil, let value = normalizedText(text),
                   currentTextPriority < selectedTextPriorities[elementName, default: Int.max] {
                    switch elementName {
                    case "title": currentProgram?.title = value
                    case "sub-title": currentProgram?.subtitle = value
                    default: currentProgram?.details.description = value
                    }
                    selectedTextPriorities[elementName] = currentTextPriority
                }
            case "episode-num": currentProgram?.details.episode = normalizedText(text)
            case "category":
                if let value = normalizedText(text), currentProgram?.details.categories.count ?? 0 < 32 {
                    currentProgram?.details.categories.append(value)
                }
            case "language":
                if let value = normalizedText(text), currentProgram?.details.languages.count ?? 0 < 32 {
                    currentProgram?.details.languages.append(value)
                }
            case "value": currentProgram?.details.rating = normalizedText(text)
            default:
                break
            }
            currentElement = nil
            currentElementDepth = nil
            text = ""
        }

        if elementDepth == 1 {
            switch elementName {
            case "channel":
                finishChannel(parser)
            case "programme":
                finishProgramme(parser)
                if sourceProgramCount.isMultiple(of: 1_000) { reportProgress() }
            default:
                break
            }
        } else if elementDepth == 0 {
            guard elementName == "tv", sawTV, !closedTV else {
                error = .invalidGuide
                parser.abortParsing()
                return
            }
            closedTV = true
        }
    }

    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) {
        failureReason = .entity
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        failureReason = .entity
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        failureReason = .entity
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?,
        notationName: String?
    ) {
        failureReason = .entity
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        foundNotationDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        error = .invalidGuide
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if error == nil {
            failureReason = .syntax
            parseErrorCode = (parseError as NSError).code
            error = isCancelled() ? .cancelled : .invalidGuide
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        if (!sawTV || !closedTV || depth != 0), error == nil {
            error = .invalidGuide
        }
    }

    private func beginText(for elementName: String, language: String? = nil) {
        truncatedDescription = false
        currentElement = elementName
        currentElementDepth = depth - 1
        let language = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == nil || language?.isEmpty == true {
            currentTextPriority = 1
        } else if let language, language.count <= 64,
                  LanguageMatch.matches(language, preferredLanguage) {
            currentTextPriority = 0
        } else {
            currentTextPriority = 2
        }
        text = ""
    }

    private func finishChannel(_ parser: XMLParser) {
        defer {
            insideChannel = false
            currentChannelID = nil
            currentChannelNames = []
            currentChannelTextBytes = 0
        }
        guard case .metadata = pass, let identifier = currentChannelID else { return }
        if guideChannels[identifier] != nil {
            if mergedChannelNames[identifier] == nil {
                mergedChannelNames[identifier] = Set(guideChannels[identifier, default: []])
            }
            let additions = currentChannelNames.filter {
                mergedChannelNames[identifier, default: []].insert($0).inserted
            }
            let addedBytes = additions.reduce(0) { $0 + $1.utf8.count }
            guard retainedTextBytes + addedBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            guideChannels[identifier, default: []].append(contentsOf: additions)
            retainedTextBytes += addedBytes
            mergedChannelDeclarations += 1
        } else {
            let wasReferenced = undeclaredGuideIDs.contains(identifier)
            let addedBytes = currentChannelTextBytes + (wasReferenced ? 0 : identifier.utf8.count)
            guard guideChannels.count + undeclaredGuideIDs.count + (wasReferenced ? 0 : 1)
                    <= LiveTVXMLTVParser.maximumGuideChannels,
                  retainedTextBytes + addedBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            undeclaredGuideIDs.remove(identifier)
            guideChannels[identifier] = currentChannelNames
            retainedTextBytes += addedBytes
        }
    }

    private func finishProgramme(_ parser: XMLParser) {
        defer {
            insideProgramme = false
            currentProgram = nil
        }
        guard case .programmes = pass,
              let program = currentProgram,
              !program.title.isEmpty
        else { return }
        if program.end == program.start {
            missingEndTextBytes += program.textBytes
            guard missingEndPrograms.count < LiveTVXMLTVParser.maximumGuideChannels,
                  missingEndTextBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            missingEndPrograms[program.guideChannelID] = program
            return
        }
        emitProgramme(program, parser: parser)
    }

    private func emitProgramme(_ program: PendingProgram, parser: XMLParser) {
        guard let lowerBound, let upperBound, program.start < upperBound, program.end > lowerBound else { return }
        coverageEnd = max(coverageEnd ?? program.end, program.end)
        if sink == nil {
            retainedTextBytes += program.textBytes
        }
        guard retainedTextBytes <= LiveTVXMLTVParser.maximumRetainedTextBytes else {
            error = .guideTooLarge
            parser.abortParsing()
            return
        }
        for channel in channelsByGuideID[program.guideChannelID] ?? [] {
            if isCancelled() {
                error = .cancelled
                parser.abortParsing()
                return
            }
            let identifier = LiveTVXMLTVParser.stableProgramID(
                channelID: channel.id,
                guideChannelID: program.guideChannelID,
                title: program.title,
                subtitle: program.subtitle,
                start: program.start,
                end: program.end
            )
            if sink == nil, !seenProgramIDs.insert(identifier).inserted { continue }
            guard retainedProgramCount < (sink == nil ? LiveTVXMLTVParser.maximumRetainedPrograms : LiveTVXMLTVParser.maximumPrograms) else {
                error = .guideTooLarge
                parser.abortParsing()
                return
            }
            let value = LiveTVPrototypeProgram(
                id: identifier,
                channelID: channel.id,
                title: program.title,
                subtitle: program.subtitle,
                start: program.start,
                end: program.end,
                details: program.details
            )
            if let sink {
                do { try sink(value) }
                catch {
                    sinkError = error
                    self.error = .cacheFailed
                    parser.abortParsing()
                    return
                }
            } else {
                programs.append(value)
            }
            retainedProgramCount += 1
        }
    }

}

extension LiveTVXMLTVParser {
    static func stableProgramID(
        channelID: String,
        guideChannelID: String,
        title: String,
        subtitle: String,
        start: Date,
        end: Date
    ) -> String {
        let components = [
            channelID,
            guideChannelID,
            title,
            subtitle,
            String(Int64(start.timeIntervalSince1970)),
            String(Int64(end.timeIntervalSince1970)),
        ]
        let digest = SHA256.hash(
            data: Data(components.joined(separator: "\u{1F}").utf8)
        )
        return "xmltv-" + LiveTVIdentityDigest.hex(digest)
    }
}

extension XMLTVDelegate {
    private func normalizedText(_ text: String) -> String? {
        let result = text.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    private func bounded(_ text: String?, maximum: Int) -> String? {
        guard let text, !text.isEmpty, text.count <= maximum else { return nil }
        return text
    }

    private func parsedDate(_ text: String) -> Date? {
        if let existing = parsedDates[text] { return existing }
        guard let date = XMLTVDateParser.date(from: text) else { return nil }
        if parsedDates.count >= 2_048 { parsedDates.removeAll(keepingCapacity: true) }
        parsedDates[text] = date
        return date
    }
}

private struct PendingProgram {
    let guideChannelID: String
    var title: String
    var subtitle: String
    let start: Date
    var end: Date
    var details = LiveTVProgramDetails()
    var textBytes: Int {
        title.utf8.count + subtitle.utf8.count + details.retainedTextBytes
    }
}

public enum XMLTVDateParser {
    public static func date(from input: String) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard timestamp.count == 12 || timestamp.count == 14 else { return nil }
        let remainder = trimmed[timestamp.endIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let offsetText: String
        if remainder.isEmpty {
            offsetText = "+0000"
        } else if ["Z", "UTC", "GMT"].contains(remainder) {
            offsetText = "+0000"
        } else {
            let parts = remainder.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, parts[0].utf8.count == 3, parts[1].utf8.count == 2 {
                offsetText = parts.joined()
            } else {
                offsetText = remainder
            }
            guard offsetText.utf8.count == 5,
                  ["+", "-"].contains(String(offsetText.prefix(1))),
                  offsetText.utf8.dropFirst().allSatisfy({ (48...57).contains($0) })
            else { return nil }
        }
        let digits = Array(timestamp.utf8)
        func integer(_ start: Int, _ count: Int) -> Int {
            digits[start..<(start + count)].reduce(0) {
                $0 * 10 + Int($1 - 48)
            }
        }
        let year = integer(0, 4)
        let month = integer(4, 2)
        let day = integer(6, 2)
        let hour = integer(8, 2)
        let minute = integer(10, 2)
        let second = digits.count == 14 ? integer(12, 2) : 0
        guard (1...9_999).contains(year),
              (1...12).contains(month),
              (1...daysInMonth(month, year: year)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...60).contains(second),
              let offsetHours = Int(offsetText.dropFirst().prefix(2)),
              let offsetMinutes = Int(offsetText.suffix(2)),
              offsetHours <= 23,
              offsetMinutes <= 59
        else { return nil }
        let direction = offsetText.first == "-" ? -1 : 1
        let offset = direction * ((offsetHours * 60 + offsetMinutes) * 60)
        let seconds = daysFromCivil(year: year, month: month, day: day) * 86_400
            + hour * 3_600
            + minute * 60
            + second
            - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = year.isMultiple(of: 4)
                && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = year - (month <= 2 ? 1 : 0)
        let era = adjustedYear / 400
        let yearOfEra = adjustedYear - era * 400
        let adjustedMonth = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

private final class BoundedGzipInputStream: InputStream {
    private let compressedStream: InputStream
    private let maximumExpandedBytes: Int
    private var zstream = z_stream()
    private let input = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1_024)
    private var output = [UInt8]()
    private var outputIndex = 0
    private var expandedBytes = 0
    private var reachedEnd = false
    private var failure: LiveTVSourceImportError?

    private let isCancelled: @Sendable () -> Bool

    init(
        compressedStream: InputStream, maximumExpandedBytes: Int,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        self.compressedStream = compressedStream
        self.maximumExpandedBytes = maximumExpandedBytes
        self.isCancelled = isCancelled
        super.init(data: Data())
        let status = inflateInit2_(
            &zstream,
            15 + 32,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw LiveTVSourceImportError.invalidGuide
        }
    }

    deinit {
        inflateEnd(&zstream)
        input.deallocate()
    }

    override var hasBytesAvailable: Bool {
        failure == nil && (outputIndex < output.count || !reachedEnd)
    }

    override var streamStatus: Stream.Status {
        if failure != nil { return .error }
        if reachedEnd && outputIndex >= output.count { return .atEnd }
        return .open
    }

    override var streamError: Error? {
        failure
    }

    override func open() {
        compressedStream.open()
    }

    override func close() {
        compressedStream.close()
    }

    override func read(
        _ buffer: UnsafeMutablePointer<UInt8>,
        maxLength len: Int
    ) -> Int {
        guard failure == nil else { return -1 }
        if isCancelled() {
            failure = .cancelled
            return -1
        }
        if outputIndex >= output.count, !fillOutput() {
            return failure == nil ? 0 : -1
        }
        let count = min(len, output.count - outputIndex)
        output.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.update(
                from: base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: outputIndex),
                count: count
            )
        }
        outputIndex += count
        return count
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    private func fillOutput() -> Bool {
        output = []
        outputIndex = 0
        guard !reachedEnd else { return false }

        while output.isEmpty && !reachedEnd && failure == nil {
            if isCancelled() {
                failure = .cancelled
                break
            }
            if zstream.avail_in == 0 {
                let count = compressedStream.read(input, maxLength: 64 * 1_024)
                guard count > 0 else {
                    failure = .invalidGuide
                    break
                }
                zstream.next_in = input
                zstream.avail_in = uInt(count)
            }

            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            let status: Int32 = chunk.withUnsafeMutableBytes {
                zstream.next_out = $0.baseAddress!
                    .assumingMemoryBound(to: Bytef.self)
                zstream.avail_out = uInt($0.count)
                return inflate(&zstream, Z_NO_FLUSH)
            }
            let produced = chunk.count - Int(zstream.avail_out)
            if produced > 0 {
                expandedBytes += produced
                guard expandedBytes <= maximumExpandedBytes else {
                    failure = .guideTooLarge
                    break
                }
                output = Array(chunk.prefix(produced))
            }
            if status == Z_STREAM_END {
                if zstream.avail_in == 0 {
                    let count = compressedStream.read(input, maxLength: 64 * 1_024)
                    if count < 0 {
                        failure = .invalidGuide
                    } else if count == 0 {
                        reachedEnd = true
                    } else {
                        zstream.next_in = input
                        zstream.avail_in = uInt(count)
                    }
                }
                if !reachedEnd, failure == nil {
                    let next = zstream.next_in
                    let available = zstream.avail_in
                    guard inflateReset2(&zstream, 15 + 16) == Z_OK else {
                        failure = .invalidGuide
                        break
                    }
                    zstream.next_in = next
                    zstream.avail_in = available
                }
            } else if status != Z_OK {
                failure = .invalidGuide
            }
        }
        return !output.isEmpty
    }
}

private final class EntityRejectingXMLInputStream: InputStream {
    var inspectDeclarations = true
    private static let forbidden = Array("<!ENTITY".utf8)
    private static let comment = Array("<!--".utf8)
    private static let instruction = Array("<?".utf8)
    private static let cdata = Array("<![CDATA[".utf8)
    private enum ScanState { case text, markup, comment, instruction, cdata }
    private let source: InputStream
    private let isCancelled: @Sendable () -> Bool
    private var state = ScanState.text
    private var prefix = [UInt8]()
    private var previous: UInt8 = 0
    private var beforePrevious: UInt8 = 0
    private var failure: LiveTVSourceImportError?
    private(set) var rejectedEntity = false

    init(source: InputStream, isCancelled: @escaping @Sendable () -> Bool) {
        self.source = source
        self.isCancelled = isCancelled
        super.init(data: Data())
    }

    override var hasBytesAvailable: Bool { failure == nil && source.hasBytesAvailable }
    override var streamStatus: Stream.Status { failure == nil ? source.streamStatus : .error }
    override var streamError: Error? { failure ?? source.streamError }
    override func open() {}
    override func close() {}

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard failure == nil else { return -1 }
        if isCancelled() {
            failure = .cancelled
            return -1
        }
        // Check cancellation between bounded reads, including long XML prologs.
        let count = source.read(buffer, maxLength: min(len, 64 * 1_024))
        guard count > 0 else { return count }
        // Declarations are legal only in the prolog. Once XMLParser reports
        // the real root, it rejects any later declaration as malformed XML.
        guard inspectDeclarations else { return count }
        // XMLParser can silently skip external declarations on tvOS. Reject
        // them before parsing, including UTF-16/32's zero-padded ASCII tokens.
        for byte in UnsafeBufferPointer(start: buffer, count: count) where byte != 0 {
            switch state {
            case .text:
                if byte == 60 {
                    prefix = [byte]
                    state = .markup
                }
            case .markup:
                prefix.append(byte)
                if prefix == Self.forbidden {
                    rejectedEntity = true
                    failure = .invalidGuide
                    return -1
                } else if prefix == Self.comment {
                    state = .comment
                    previous = 0
                    beforePrevious = 0
                } else if prefix == Self.instruction {
                    state = .instruction
                    previous = 0
                } else if prefix == Self.cdata {
                    state = .cdata
                    previous = 0
                    beforePrevious = 0
                } else if !Self.forbidden.starts(with: prefix) && !Self.comment.starts(with: prefix)
                    && !Self.instruction.starts(with: prefix) && !Self.cdata.starts(with: prefix) {
                    state = byte == 60 ? .markup : .text
                    prefix = byte == 60 ? [byte] : []
                }
            case .comment, .cdata:
                let terminator: UInt8 = state == .comment ? 45 : 93
                if beforePrevious == terminator, previous == terminator, byte == 62 { state = .text }
                beforePrevious = previous
                previous = byte
            case .instruction:
                if previous == 63, byte == 62 { state = .text }
                previous = byte
            }
        }
        return count
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }
}
