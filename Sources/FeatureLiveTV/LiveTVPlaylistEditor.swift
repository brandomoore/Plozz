import CoreUI
import CoreModels
import CoreNetworking
import FeatureLiveTVCore
import Observation
import SwiftUI

struct LiveTVPlaylistEditor: View {
    @State private var model: LiveTVPlaylistEditorModel
    @State private var checkRequest: UUID?
    @Environment(\.dismiss) private var dismiss
    let isEditing: Bool
    let save: (LiveTVPlaylistEditorModel.ValidatedInput) throws -> Void

    init(
        name: String = "", playlistURL: URL? = nil, guideURLs: [URL] = [],
        isEditing: Bool = false,
        save: @escaping (LiveTVPlaylistEditorModel.ValidatedInput) throws -> Void
    ) {
        self.isEditing = isEditing
        self.save = save
        _model = State(initialValue: LiveTVPlaylistEditorModel(
            name: name, playlistURL: playlistURL, guideURLs: guideURLs, isEditing: isEditing
        ))
    }

    var body: some View {
        @Bindable var model = model
        LiveTVSettingsPage(title: "IPTV source") {
            SettingsSectionGroup("Playlist") {
                LiveTVSetupField(
                    title: "Playlist or live HLS URL", text: $model.playlistAddress, isAddress: true,
                    identifier: "live-tv-playlist-url", example: "https://example.com/channels.m3u"
                )
                LiveTVSetupField(title: "Name (optional)", text: $model.name)
            } footer: {
                Text("Add channels with an M3U, M3U8 or live HLS URL.")
            }
            .disabled(model.isChecking)

            LiveTVGuideFields(guides: $model.guideAddresses)
                .disabled(model.isChecking)

            VStack(alignment: .leading, spacing: 12) {
                if model.usesUnencryptedAddresses {
                    Text("HTTP is unencrypted. Prefer HTTPS.")
                        .font(.caption)
                }
                if model.isChecking {
                    HStack(spacing: 16) {
                        ProgressView()
                        Text("Checking playlist")
                    }
                    .accessibilityElement(children: .combine)
                } else if let review = model.currentReview {
                    LiveTVPlaylistReviewSummary(channels: review.channelCount, skipped: review.skippedEntryCount)
                }
                Button {
                    if model.isChecking {
                        model.cancelCheck()
                        checkRequest = nil
                    } else if model.currentReview != nil {
                        if model.save(using: save) { dismiss() }
                    } else {
                        checkRequest = UUID()
                    }
                } label: {
                    Group {
                        if model.isChecking {
                            Text("Cancel check")
                        } else if model.currentReview != nil {
                            Text("Save source")
                        } else if isEditing {
                            Text("Save changes")
                        } else {
                            Text("Add source")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .plozzActionButton(role: model.isChecking ? .secondary : .primary)
                .accessibilityIdentifier("live-tv-playlist-action")
                if let issue = model.issue {
                    Label {
                        Text(issue.message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text("Checks the playlist, not individual streams.")
                    .font(.footnote)
                    .settingsRowSecondary()
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: checkRequest) {
            guard let request = checkRequest else { return }
            await model.check()
            guard !Task.isCancelled, checkRequest == request else { return }
            checkRequest = nil
            if model.currentReview != nil, model.save(using: save) {
                dismiss()
            }
        }
        .onDisappear { model.cancelCheck() }
    }
}

private struct LiveTVPlaylistReviewSummary: View {
    let channels: Int
    let skipped: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Found \(channels) channels", systemImage: "checkmark.circle")
                .font(.headline)
            if skipped > 0 {
                Text("\(skipped) unsupported or duplicate entries skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
@Observable
final class LiveTVPlaylistEditorModel {
    struct GuideAddress: Identifiable, Equatable {
        let id = UUID()
        var address = ""
    }

    struct ValidatedInput: Equatable {
        let name: String
        let playlistURL: URL
        let guideURLs: [URL]
    }

    struct Review: Equatable {
        let input: ValidatedInput
        let channelCount: Int
        let skippedEntryCount: Int
    }

    enum Issue: Error, Equatable {
        case invalidPlaylistAddress, invalidGuideAddress, noChannels, checkRequired, saveFailed, sourceChanged, accessDenied
        case download(LiveTVSourceImportError)
        case invalidName, invalidGuideList

        var message: LocalizedStringResource {
            switch self {
            case .invalidPlaylistAddress:
                "Enter a complete HTTP or HTTPS playlist URL, without a username or password before the hostname."
            case .invalidGuideAddress:
                "Each guide needs a complete HTTP or HTTPS URL, or you can leave it blank."
            case .invalidName:
                "Use a shorter source name."
            case .invalidGuideList:
                "Use no more than 32 different guide addresses. Remove duplicate guide links."
            case .noChannels:
                "This playlist has no supported HTTP or HTTPS channels. Check the link from your provider."
            case .checkRequired:
                "Check the updated playlist before saving."
            case .saveFailed:
                "Your source could not be saved. Your previous setup is unchanged. Please try again."
            case .sourceChanged:
                "This source changed while you were editing. Return to Sources and reopen it before saving."
            case .accessDenied:
                "Source management is locked. Reopen Sources and enter the Parental PIN before saving."
            case .download(let failure):
                failure.userDescription
            }
        }
    }

    var name: String
    var playlistAddress: String
    var guideAddresses: [GuideAddress]
    private(set) var isChecking = false
    private(set) var issue: Issue?
    private var review: Review?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let loader: any LiveTVSourceLoading
    @ObservationIgnored private let setupDiagnostics: IPTVSetupDiagnostics
    @ObservationIgnored private let isEditing: Bool
    @ObservationIgnored private var diagnosticAttempt: IPTVSetupAttempt?

    init(
        name: String = "", playlistURL: URL? = nil, guideURLs: [URL] = [],
        isEditing: Bool = false, setupDiagnostics: IPTVSetupDiagnostics = .shared,
        loader: any LiveTVSourceLoading = LiveTVSourceLoader()
    ) {
        self.name = name
        self.playlistAddress = playlistURL?.absoluteString ?? ""
        self.guideAddresses = guideURLs.map { .init(address: $0.absoluteString) }
        self.loader = loader
        self.isEditing = isEditing
        self.setupDiagnostics = setupDiagnostics
    }

    var currentReview: Review? {
        guard let review, let input = validatedInput,
              review.input.playlistURL == input.playlistURL else { return nil }
        return Review(input: input, channelCount: review.channelCount, skippedEntryCount: review.skippedEntryCount)
    }

    private var validatedInput: ValidatedInput? {
        guard case .success(let input) = validatedInputResult else { return nil }
        return input
    }

    var usesUnencryptedAddresses: Bool {
        ([playlistAddress] + guideAddresses.map(\.address)).contains {
            LiveTVPlaylistSource.sourceURL(from: $0)?.scheme?.lowercased() == "http"
        }
    }

    func moveGuide(_ id: UUID, by offset: Int) {
        guard let index = guideAddresses.firstIndex(where: { $0.id == id }),
              guideAddresses.indices.contains(index + offset) else { return }
        guideAddresses.swapAt(index, index + offset)
    }

    private var validatedInputResult: Result<ValidatedInput, Issue> {
        guard let playlistURL = LiveTVPlaylistSource.sourceURL(from: playlistAddress) else {
            return .failure(.invalidPlaylistAddress)
        }
        let addresses = guideAddresses.map(\.address).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let guides = addresses.compactMap { LiveTVPlaylistSource.sourceURL(from: $0) }
        guard guides.count == addresses.count else { return .failure(.invalidGuideAddress) }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = ValidatedInput(
            name: label.isEmpty ? (playlistURL.host ?? "IPTV") : label,
            playlistURL: playlistURL, guideURLs: guides
        )
        do {
            try LiveTVPlaylistSource(
                id: "draft", name: input.name, playlistURL: playlistURL, guideURLs: guides
            ).validate()
            return .success(input)
        } catch LiveTVSourcesValidationError.invalidName {
            return .failure(.invalidName)
        } catch LiveTVSourcesValidationError.invalidGuideSources {
            return .failure(.invalidGuideList)
        } catch {
            return .failure(.invalidGuideAddress)
        }
    }

    func check() async {
        cancelCheck()
        let request = revision
        isChecking = false
        review = nil
        issue = nil
        let attempt = beginDiagnostic()
        diagnosticAttempt = attempt
        var readyToSave = false
        defer {
            if !readyToSave {
                attempt?.finish(.init(.cancelled))
                if request == revision { diagnosticAttempt = nil }
            }
        }
        let input: ValidatedInput
        switch validatedInputResult {
        case .success(let value):
            input = value
        case .failure(let failure):
            issue = failure
            attempt?.finish(.init(.invalidInput))
            return
        }
        isChecking = true
        defer { if request == revision { isChecking = false } }
        do {
            attempt?.advance(to: .playlist)
            let imported = try await IPTVSetupDiagnostics.$current.withValue(attempt) {
                try await loader.loadPlaylist(from: input.playlistURL)
            }
            guard !Task.isCancelled, request == revision, input == validatedInput else { return }
            attempt?.record(entries: imported.entryCount, skippedEntries: imported.skippedEntryCount)
            guard !imported.channels.isEmpty else {
                issue = .noChannels
                attempt?.finish(.init(.empty))
                return
            }
            review = Review(
                input: input, channelCount: imported.channels.count,
                skippedEntryCount: imported.skippedEntryCount
            )
            readyToSave = true
        } catch is CancellationError {
            return
        } catch let failure as LiveTVSourceImportError {
            guard request == revision, !Task.isCancelled, failure != .cancelled else { return }
            attempt?.finish(.sanitized(failure))
            issue = .download(failure)
        } catch {
            guard request == revision, !Task.isCancelled else { return }
            attempt?.finish(.sanitized(error))
            issue = .download(.downloadFailed)
        }
    }

    func cancelCheck() {
        diagnosticAttempt?.finish(.init(.cancelled))
        diagnosticAttempt = nil
        revision &+= 1
        isChecking = false
    }

    func save(using persist: (ValidatedInput) throws -> Void) -> Bool {
        guard let review = currentReview else {
            diagnosticAttempt?.finish(.init(.cancelled))
            diagnosticAttempt = nil
            beginDiagnostic()?.finish(.init(.invalidInput))
            issue = .checkRequired
            return false
        }
        let attempt = diagnosticAttempt ?? beginDiagnostic()
        defer { diagnosticAttempt = nil }
        attempt?.advance(to: .persistence)
        do {
            try persist(review.input)
            attempt?.finish()
            issue = nil
            return true
        } catch LiveTVSourceManagementModel.MutationError.accessDenied {
            attempt?.finish(.init(.accessDenied))
            issue = .accessDenied
            return false
        } catch LiveTVSourceManagementModel.MutationError.changedSource {
            attempt?.finish(.init(.sourceChanged))
            issue = .sourceChanged
            return false
        } catch {
            attempt?.finish(.init(.storage))
            issue = .saveFailed
            return false
        }
    }

    private func beginDiagnostic() -> IPTVSetupAttempt? {
        setupDiagnostics.begin(source: .playlistURL, authentication: .url, entry: isEditing ? .editSource : .addSource)
    }
}
