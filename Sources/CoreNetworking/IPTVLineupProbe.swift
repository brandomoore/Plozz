#if DEBUG
/// Scoped fixture work counts. No listener is installed in the app, and events carry no identities.
package enum IPTVLineupProbe {
    package enum Event: String, CaseIterable, Sendable {
        case fullClientMaps, providerIDMaps, adapterMaps, projectionBuilds
        case nonemptySourceQueries, guideDownloads, guideImports
    }

    @TaskLocal package static var record: (@Sendable (Event) -> Void)?
}
#endif
