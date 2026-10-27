#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import SwiftUI

/// Mounted only after the user opens version selection.
struct MediaVersionInventoryContent<Content: View>: View {
    let versions: [MediaVersion]
    let loadVersions: MediaVersionInventoryLoader?
    @ViewBuilder let content: ([MediaVersion]) -> Content
    @State private var loaded: [MediaVersion]?
    @State private var failure: LocalizedStringResource?
    @State private var attempt = 0
    @State private var resultID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if loadVersions == nil {
                content(versions)
            } else if resultID != loadVersions?.id {
                ProgressView("Loading…")
            } else if let loaded {
                if loaded.isEmpty {
                    Text("Version")
                } else {
                    content(loaded)
                }
            } else if let failure {
                VStack(alignment: .leading, spacing: 12) {
                    InlineErrorMessage(Text(failure))
                    Button("Retry") { attempt += 1 }
                        .plozzActionButton(role: .secondary)
                }
            } else {
                ProgressView("Loading…")
            }
        }
        .task(id: "\(loadVersions?.id ?? "static"):\(attempt)") {
            guard let loadVersions else { return }
            loaded = nil
            failure = nil
            resultID = loadVersions.id
            do {
                let result = try await loadVersions.load()
                try Task.checkCancellation()
                loaded = result
            } catch {
                guard !Task.isCancelled else { return }
                if error is CancellationError {
                    dismiss()
                    return
                }
                PlozzLog.playback.error("Explicit version selection could not load source inventory.")
                failure = (error as? AppError)?.userMessage
                    ?? (error as? StreamingQualityError)?.userMessage
                    ?? StreamingQualityError.negotiationFailed.userMessage
            }
        }
    }
}
#endif
