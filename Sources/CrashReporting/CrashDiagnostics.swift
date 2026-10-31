import Foundation
import CoreModels
import CoreNetworking
#if canImport(Sentry)
import Sentry
#endif

/// On-demand technical reports constructed from allowlisted fields.
/// Raw activity messages and free-form playback traces never become attachments.
///
/// This deliberately piggybacks on the existing opt-in Sentry pipe: it only does
/// anything when crash reporting is both **configured** (a DSN was baked into the
/// build) *and* **enabled** (the user turned it on in Help & Diagnostics, so the
/// SDK is actually running). Otherwise it sends nothing and returns `false`, and
/// the caller should tell the user to turn crash reporting on first.
public enum CrashDiagnostics {
    /// Trims the submitted message; missing or whitespace-only messages are invalid.
    public static func normalizedNote(_ note: String?) -> String? {
        guard let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return note
    }

    /// Send a filtered diagnostic attachment and explicitly submitted feedback.
    /// Returns `true` for SDK handoff, not confirmation of server delivery;
    /// `false` when the message is blank, reporting is inactive, or either event was rejected.
    @MainActor
    @discardableResult
    public static func send(note: String? = nil) async -> Bool {
        guard let note = normalizedNote(note) else {
            PlozzLog.app.error("A message is required to submit diagnostics; nothing submitted.")
            return false
        }
        #if canImport(Sentry)
        guard SentrySDK.isEnabled else { return false }
        let scope = DiagnosticExportScope()
        let playbackJournal = await PlaybackDiagnosticJournal.shared.export(scope: scope)
        return send(
            note: note,
            isEnabled: SentrySDK.isEnabled,
            activity: { PlozzLog.activityExport(scope: scope) },
            sourceDiagnostics: { LiveTVSourceDiagnostics.captureExport(scope: scope) },
            preparationDiagnostics: { PlaybackPreparationDiagnostics.export(scope: scope) },
            libraryDiagnostics: { LibraryDiagnosticJournal.shared.export(scope: scope) },
            searchDiagnostics: { SearchDiagnosticJournal.shared.export(scope: scope) },
            connectionDiagnostics: { ServerConnectionDiagnostics.shared.export(scope: scope) },
            playbackDiagnostics: playbackJournal,
            captureEvent: { event, attachment in
                SentrySDK.capture(event: event) { scope in
                    scope.addAttachment(attachment)
                }
            },
            captureFeedback: { SentrySDK.capture(event: $0) }
        )
        #else
        return false
        #endif
    }

    #if canImport(Sentry)
    @MainActor
    static func send(
        note: String?,
        isEnabled: Bool,
        activity: @MainActor () -> PlozzLog.ActivityExport = { PlozzLog.activityExport() },
        sourceDiagnostics: @MainActor () -> LiveTVSourceDiagnostics.Export = {
            LiveTVSourceDiagnostics.captureExport(scope: DiagnosticExportScope())
        },
        preparationDiagnostics: @MainActor () -> PlaybackPreparationDiagnostics.Export = {
            PlaybackPreparationDiagnostics.export(scope: DiagnosticExportScope())
        },
        libraryDiagnostics: @MainActor () -> LibraryDiagnosticJournal.Export = {
            LibraryDiagnosticJournal.shared.export(scope: DiagnosticExportScope())
        },
        searchDiagnostics: @MainActor () -> SearchDiagnosticJournal.Export = {
            SearchDiagnosticJournal.shared.export(scope: DiagnosticExportScope())
        },
        connectionDiagnostics: @MainActor () -> ServerConnectionDiagnostics.Export = {
            ServerConnectionDiagnostics.shared.export(scope: DiagnosticExportScope())
        },
        playbackDiagnostics: PlaybackDiagnosticJournal.Export? = nil,
        operations: PerformanceDiagnostics = .shared,
        captureEvent: (Event, Attachment) -> SentryId,
        captureFeedback: (Event) -> SentryId
    ) -> Bool {
        guard let message = normalizedNote(note) else {
            PlozzLog.app.error("A message is required to submit diagnostics; nothing submitted.")
            return false
        }
        guard isEnabled else { return false }

        let report = TechnicalReport(
            activity: activity(), sources: sourceDiagnostics(), preparation: preparationDiagnostics(),
            library: libraryDiagnostics(), connections: connectionDiagnostics(),
            playback: playbackDiagnostics,
            search: searchDiagnostics(),
            operations: operations.snapshot()
        )
        let body: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            body = try encoder.encode(report)
        } catch {
            PlozzLog.app.error("Unable to encode the privacy-filtered diagnostic report; nothing submitted.")
            return false
        }
        guard body.count <= 4 * 1_024 * 1_024 else {
            PlozzLog.app.error("Privacy-filtered diagnostic report exceeded its size limit; nothing submitted.")
            return false
        }
        let attachment = Attachment(
            data: body,
            filename: "plozz-diagnostics.json",
            contentType: "application/json"
        )

        let event = Event(level: .info)
        event.message = SentryMessage(formatted: "User diagnostics report")
        event.tags = ["report.kind": "user-diagnostics"]
        let eventID = captureEvent(event, attachment)
        guard eventID != .empty else { return false }

        let feedback = SentryFeedback(
            message: message,
            name: nil,
            email: nil,
            source: .custom,
            associatedEventId: eventID
        )
        // Sentry's feedback convenience API bypasses beforeSend. Keep this a
        // normal event until our privacy hook scrubs it and sets the feedback type.
        let feedbackEvent = Event(level: .info)
        feedbackEvent.tags = ["report.kind": "user-feedback"]
        feedbackEvent.context = ["feedback": feedback.serialize()]
        return captureFeedback(feedbackEvent) != .empty
    }

    private struct TechnicalReport: Encodable {
        let format = "plozz-user-diagnostics-2"
        let activity: PlozzLog.ActivityExport
        let sources: LiveTVSourceDiagnostics.Export
        let preparation: PlaybackPreparationDiagnostics.Export
        let library: LibraryDiagnosticJournal.Export
        let connections: ServerConnectionDiagnostics.Export
        let playback: PlaybackDiagnosticJournal.Export?
        let search: SearchDiagnosticJournal.Export
        let operations: PerformanceDiagnostics.Snapshot?
    }
    #endif

    /// Whether a diagnostics report can actually be sent right now (the SDK is
    /// live). UIs can use this to enable/disable a "Send to developer" button,
    /// though gating on the crash-reporting consent flag is usually clearer.
    @MainActor
    public static var isAvailable: Bool {
        #if canImport(Sentry)
        return SentrySDK.isEnabled
        #else
        return false
        #endif
    }
}
