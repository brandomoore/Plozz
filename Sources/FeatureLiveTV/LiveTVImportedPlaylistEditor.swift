import CoreModels
import CoreNetworking
import CoreUI
import FeatureLiveTVCore
import SwiftUI
#if os(iOS)
import UniformTypeIdentifiers
#endif

struct LiveTVImportedPlaylistEditor: View {
    let sources: LiveTVSourceManagementModel
    let imports: LiveTVPrototypeImportModel?
    let original: LiveTVPlaylistSource?
    let didConfigurePlaylist: () -> Void
    let didImportPlaylist: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var guides: [LiveTVPlaylistEditorModel.GuideAddress]
    @State private var baseAddress = ""
    @State private var fileURL: URL?
    @State private var choosingFile = false
    @State private var saveRequest: UUID?
    @State private var saving = false
    @State private var issue: LocalizedStringResource?

    init(
        sources: LiveTVSourceManagementModel, imports: LiveTVPrototypeImportModel?,
        original: LiveTVPlaylistSource? = nil, didConfigurePlaylist: @escaping () -> Void,
        didImportPlaylist: @escaping (String) -> Void = { _ in }
    ) {
        self.sources = sources
        self.imports = imports
        self.original = original
        self.didConfigurePlaylist = didConfigurePlaylist
        self.didImportPlaylist = didImportPlaylist
        _name = State(initialValue: original?.name ?? "")
        _guides = State(initialValue: (original?.guideURLs ?? []).map { .init(address: $0.absoluteString) })
    }

    var body: some View {
        LiveTVSettingsPage(title: "Imported playlist") {
            SettingsSectionGroup("Playlist") {
                LiveTVSetupField(title: "Name (optional)", text: $name)
                if original == nil {
                    #if os(iOS)
                    Button { choosingFile = true } label: {
                        LiveTVSetupActionLabel(
                            title: fileURL == nil ? "Choose M3U file" : "Choose another file",
                            symbol: "doc"
                        )
                    }
                    .buttonStyle(SettingsFocusButtonStyle(size: .contained))
                    #endif
                    if fileURL != nil { Label("Playlist selected", systemImage: "doc") }
                    LiveTVSetupField(
                        title: "Base URL for relative addresses (optional)", text: $baseAddress, isAddress: true,
                        example: "https://example.com/"
                    )
                }
                Text("The imported copy is encrypted on this device and syncs to the same profile through encrypted iCloud storage when iCloud Sync is on.")
                    .font(.caption)
            }
            .disabled(saving)
            LiveTVGuideFields(guides: $guides)
                .disabled(saving)
            SettingsSectionGroup {
                if saving { ProgressView("Importing playlist") }
                Button { saveRequest = UUID() } label: {
                    Text(original == nil ? LocalizedStringResource("Import playlist") : LocalizedStringResource("Save source"))
                        .frame(maxWidth: .infinity)
                }
                .plozzActionButton()
                .disabled(saving || (original == nil && fileURL == nil))
                if let issue { Text(issue) }
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.data]) { result in
            do { fileURL = try result.get() }
            catch { issue = "The selected file couldn't be opened." }
        }
        #endif
        .task(id: saveRequest) {
            guard let request = saveRequest else { return }
            await save(request: request)
        }
    }

    @MainActor
    private func save(request: UUID) async {
        let attempt = IPTVSetupDiagnostics.shared.begin(
            source: .playlistFile, authentication: .none, entry: original == nil ? .addSource : .editSource
        )
        await IPTVSetupDiagnostics.$current.withValue(attempt) {
            await save(request: request, diagnostic: attempt)
        }
    }

    @MainActor
    private func save(request: UUID, diagnostic: IPTVSetupAttempt?) async {
        saving = true
        issue = nil
        defer { saving = false }
        var importedID: UUID?
        var committed = false
        var persisting = false
        do {
            try sources.ensureCanMutate()
            let urls = try guides.compactMap { entry -> URL? in
                let value = entry.address.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                guard let url = LiveTVPlaylistSource.sourceURL(from: value) else {
                    throw LiveTVSourcesValidationError.invalidGuideURL
                }
                return url
            }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var source: LiveTVPlaylistSource
            if let original {
                source = original
                source.name = displayName.isEmpty ? "Imported playlist" : displayName
                source.guideURLs = urls
            } else {
                guard let imports, let fileURL,
                      let locator = URL(string: "plozz-playlist://" + request.uuidString.lowercased()) else {
                    throw LiveTVSourceImportError.invalidPlaylist
                }
                let address = baseAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let baseURL = address.isEmpty ? nil : LiveTVPlaylistSource.sourceURL(from: address)
                guard address.isEmpty || baseURL != nil else {
                    throw LiveTVSourcesValidationError.invalidPlaylistURL
                }
                importedID = request
                diagnostic?.advance(to: .playlist)
                let imported = try await imports.importPlaylistFile(at: fileURL, id: request, baseURL: baseURL)
                diagnostic?.record(entries: imported.entryCount, skippedEntries: imported.skippedEntryCount)
                try Task.checkCancellation()
                source = LiveTVPlaylistSource(
                    id: request.uuidString.lowercased(), name: displayName.isEmpty ? "Imported playlist" : displayName,
                    playlistURL: locator, guideURLs: urls
                )
            }
            persisting = true
            diagnostic?.advance(to: .persistence)
            try IPTVSetupDiagnostics.$current.withValue(nil) {
                try sources.saveImportedPlaylist(source, replacing: original)
                committed = true
                didConfigurePlaylist()
                if original == nil { didImportPlaylist(source.id) }
                diagnostic?.finish()
                dismiss()
            }
        } catch {
            let failure: IPTVSetupDiagnostic.Failure
            switch error {
            case LiveTVSourceManagementModel.MutationError.accessDenied: failure = .init(.accessDenied)
            case LiveTVSourceManagementModel.MutationError.changedSource: failure = .init(.sourceChanged)
            case is LiveTVSourcesValidationError: failure = .init(.invalidInput)
            default: failure = persisting ? .init(.storage) : .sanitized(error)
            }
            diagnostic?.finish(Task.isCancelled ? .init(.cancelled) : failure)
            if !Task.isCancelled {
                issue = (error as? LiveTVSourceImportError)?.userDescription
                    ?? "The playlist couldn't be saved. Check its addresses and source-management permission."
            }
            if let importedID, !committed, let imports {
                do { try await imports.removeImportedPlaylistFile(id: importedID) }
                catch { issue = "The source wasn't saved, but its encrypted local copy couldn't be removed." }
            }
        }
    }
}
