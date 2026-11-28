#if os(tvOS)
import TVServices

/// Shared by the extension and tests, without the app's model or artwork stack.
public enum TopShelfContentBuilder {
    public static func makeContent(from snapshot: TopShelfSnapshot) -> (any TVTopShelfContent)? {
        // tvOS may retain native items between reloads. A new viewer must not
        // reuse another viewer's card, even for the same server and item ID.
        func identifier(for item: TopShelfSnapshot.Item) -> String {
            guard let authorization = snapshot.authorizationID else { return item.shelfIdentifier }
            return "\(authorization.uuidString)/\(item.shelfIdentifier)"
        }
        if snapshot.usesFullScreen {
            var seen = Set<String>()
            let items = snapshot.sections.flatMap { section in
                section.items.compactMap { item -> TVTopShelfCarouselItem? in
                    guard seen.insert(item.shelfIdentifier).inserted else { return nil }
                    let result = TVTopShelfCarouselItem(identifier: identifier(for: item))
                    configure(result, from: item)
                    result.contextTitle = [section.title, item.subtitle].compactMap { $0 }.joined(separator: " · ")
                    result.summary = item.summary
                    result.genre = item.genre
                    result.creationDate = item.releaseDate.flatMap { releaseDateForDisplay($0) }
                    if let duration = item.duration, duration.isFinite, duration > 0 {
                        result.duration = duration
                    }
                    result.displayAction = TVTopShelfAction(url: TopShelf.itemDeepLink(
                        id: item.id, accountID: item.accountID, action: .details
                    ))
                    result.mediaOptions = mediaOptions(from: item.mediaOptions ?? [])
                    result.namedAttributes = (item.namedAttributes ?? []).prefix(4).map {
                        TVTopShelfNamedAttribute(name: $0.name, values: $0.values)
                    }
                    return result
                }
            }
            return items.isEmpty ? nil : TVTopShelfCarouselContent(style: .details, items: items)
        }

        let sections = snapshot.sections.compactMap { section -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? in
            guard !section.items.isEmpty else { return nil }
            let items = section.items.map { item in
                let result = TVTopShelfSectionedItem(identifier: identifier(for: item))
                configure(result, from: item)
                result.imageShape = .poster
                result.displayAction = result.playAction
                return result
            }
            let result = TVTopShelfItemCollection(items: items)
            result.title = section.title
            return result
        }
        return sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections)
    }

    private static func configure(_ result: TVTopShelfItem, from item: TopShelfSnapshot.Item) {
        result.title = item.title
        if let imageURL = item.imageURL {
            result.setImageURL(imageURL, for: .screenScale1x)
            result.setImageURL(imageURL, for: .screenScale2x)
        }
        result.playAction = TVTopShelfAction(url: TopShelf.itemDeepLink(id: item.id, accountID: item.accountID))
    }

    private static func mediaOptions(from options: [TopShelfSnapshot.MediaOption]) -> TVTopShelfCarouselItem.MediaOptions {
        var result: TVTopShelfCarouselItem.MediaOptions = []
        if options.contains(.ultraHD) { result.insert(.videoResolution4K) }
        else if options.contains(.hd) { result.insert(.videoResolutionHD) }
        if options.contains(.dolbyVision) { result.insert(.videoColorSpaceDolbyVision) }
        else if options.contains(.hdr) { result.insert(.videoColorSpaceHDR) }
        if options.contains(.dolbyAtmos) { result.insert(.audioDolbyAtmos) }
        if options.contains(.closedCaptions) { result.insert(.audioTranscriptionClosedCaptioning) }
        if options.contains(.sdh) { result.insert(.audioTranscriptionSDH) }
        return result
    }

    static func releaseDateForDisplay(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> Date? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        // Provider release dates are UTC calendar days; keep January 1 in its
        // correct year when tvOS formats the date in the device's time zone.
        components.hour = 12
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }
}
#endif
