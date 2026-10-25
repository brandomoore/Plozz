#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

struct PublicMetaDBMarkerView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    @State private var showsHighlights = false

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Community timestamps")
            PublicMetaDBContentLabel(content: content)
            Text("Timestamps may describe a different release. During playback, Community timestamps offers confirmed manual jumps. These records never replace server markers or enable automatic skipping.")
                .foregroundStyle(.secondary)
            NavigationLink("Publish skip timestamps") {
                PublicMetaDBMarkerEditor(service: service, content: content, isHighlight: false)
            }
            NavigationLink("Publish a highlight") {
                PublicMetaDBMarkerEditor(service: service, content: content, isHighlight: true)
            }
            Text("Skip timestamps").font(.headline)
            PublicMetaDBReadContent(service: service, load: {
                try await service.skipsForManagement(content, expectedConnectionID: $0)
            }) { records in
                if records.isEmpty { Text("No skip timestamps") }
                ForEach(records) { record in
                    NavigationLink {
                        PublicMetaDBContributionRecordView(
                            service: service, category: .skips, recordID: record.id,
                            delete: { try await service.deleteManagedSkip(record, expectedConnectionID: $0) }
                        ) {
                            PublicMetaDBSkipDescription(skip: record.value)
                            if let contributor = record.contributor { Text(verbatim: contributor) }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            PublicMetaDBSkipDescription(skip: record.value)
                            if let contributor = record.contributor { Text(verbatim: contributor) }
                        }
                    }
                }
            }
            Toggle("Show highlights (may contain spoilers)", isOn: $showsHighlights)
            if showsHighlights {
                PublicMetaDBReadContent(service: service, load: {
                    try await service.highlightsForManagement(content, expectedConnectionID: $0)
                }) { records in
                    if records.isEmpty { Text("No highlights") }
                    ForEach(records) { record in
                        NavigationLink {
                            PublicMetaDBContributionRecordView(
                                service: service, category: .highlights, recordID: record.id,
                                delete: { try await service.deleteManagedHighlight(record, expectedConnectionID: $0) }
                            ) {
                                PublicMetaDBSegmentLabel(segment: record.value.segment)
                                if let description = record.value.description { Text(verbatim: description) }
                                if let contributor = record.contributor { Text(verbatim: contributor) }
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                PublicMetaDBSegmentLabel(segment: record.value.segment)
                                if let description = record.value.description { Text(verbatim: description) }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: service.connectionID) { _, _ in showsHighlights = false }
    }
}

private struct PublicMetaDBSkipDescription: View {
    let skip: PublicMetaDB.Skip
    var body: some View {
        VStack(alignment: .leading) {
            switch skip.source {
            case .streaming: Text("Streaming release")
            case .physical: Text("Physical release")
            case nil: Text("Release source unknown")
            }
            if let segment = skip.intro { LabeledContent("Intro") { PublicMetaDBSegmentLabel(segment: segment) } }
            if let segment = skip.credits { LabeledContent("Credits") { PublicMetaDBSegmentLabel(segment: segment) } }
            if let segment = skip.recap { LabeledContent("Recap") { PublicMetaDBSegmentLabel(segment: segment) } }
            if let segment = skip.preview { LabeledContent("Preview") { PublicMetaDBSegmentLabel(segment: segment) } }
        }
    }
}

private struct PublicMetaDBSegmentLabel: View {
    let segment: PublicMetaDB.Segment
    var body: some View {
        Text("\(segment.startMilliseconds.formatted())–\(segment.endMilliseconds.formatted()) ms")
    }
}

struct PublicMetaDBContributionRecordView<Detail: View>: View {
    let service: PublicMetaDBService
    let category: PublicMetaDB.Contribution
    let recordID: String
    let delete: @MainActor (UUID) async throws -> Void
    @ViewBuilder let detail: () -> Detail
    @State private var operation = PublicMetaDBMutationOperation()
    @State private var confirming = false
    @State private var connection: UUID?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("Community contribution")
            detail()
            if operation.succeeded {
                Text("Contribution removed from PublicMetaDB")
            } else {
                NavigationLink("Vote on this contribution") {
                    PublicMetaDBVoteView(service: service, category: category, recordID: recordID)
                }
                Text("Only the author can delete a contribution. PublicMetaDB verifies ownership using your API key.")
                    .foregroundStyle(.secondary)
                Button("Delete contribution", role: .destructive) {
                    connection = service.connectionID
                    confirming = true
                }
                .disabled(!operation.permitsWrite || service.phase != .connected)
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Delete this contribution?", isPresented: $confirming) {
            Button("Delete contribution", role: .destructive) {
                guard let connection else { return }
                operation.perform { try await delete(connection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Requests deletion of this exact contribution. PublicMetaDB rejects the request if it is not yours. Media-server data is unchanged.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            connection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBSegmentDraft {
    var start = ""
    var end = ""

    func segment() throws -> PublicMetaDB.Segment? {
        let start = start.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = end.trimmingCharacters(in: .whitespacesAndNewlines)
        if start.isEmpty && end.isEmpty { return nil }
        guard let start = Double(start), let end = Double(end) else { throw PublicMetaDB.Failure.invalidInput }
        return try .init(startMilliseconds: start, endMilliseconds: end)
    }
}

private struct PublicMetaDBSegmentFields: View {
    let title: LocalizedStringResource
    @Binding var draft: PublicMetaDBSegmentDraft
    var body: some View {
        Section {
            TextField("Start (milliseconds)", text: $draft.start)
            TextField("End (milliseconds)", text: $draft.end)
        } header: {
            Text(title)
        }
    }
}

private struct PublicMetaDBMarkerEditor: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    let isHighlight: Bool
    @State private var source: PublicMetaDB.ReleaseSource?
    @State private var intro = PublicMetaDBSegmentDraft()
    @State private var credits = PublicMetaDBSegmentDraft()
    @State private var recap = PublicMetaDBSegmentDraft()
    @State private var preview = PublicMetaDBSegmentDraft()
    @State private var highlight = PublicMetaDBSegmentDraft()
    @State private var description = ""
    @State private var verified = false
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var failure: (any Error)?
    @State private var operation = PublicMetaDBMutationOperation()

    private enum Draft {
        case skip(PublicMetaDB.Skip, UUID)
        case highlight(PublicMetaDB.Highlight, UUID)

        @MainActor func publish(to service: PublicMetaDBService) async throws {
            switch self {
            case .skip(let value, let connection):
                try await service.submitManagedSkip(value, expectedConnectionID: connection)
            case .highlight(let value, let connection):
                try await service.submitManagedHighlight(value, expectedConnectionID: connection)
            }
        }
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(isHighlight ? "Publish a highlight" : "Publish skip timestamps")
            PublicMetaDBContentLabel(content: content)
            if operation.succeeded {
                Text("Contribution confirmed on PublicMetaDB")
            } else {
                if isHighlight {
                    PublicMetaDBSegmentFields(title: "Highlight", draft: $highlight)
                    TextField("Description (optional)", text: $description)
                } else {
                    Picker("Release source", selection: $source) {
                        Text("Choose a release source").tag(PublicMetaDB.ReleaseSource?.none)
                        Text("Streaming").tag(Optional(PublicMetaDB.ReleaseSource.streaming))
                        Text("Physical").tag(Optional(PublicMetaDB.ReleaseSource.physical))
                    }
                    PublicMetaDBSegmentFields(title: "Intro (optional)", draft: $intro)
                    PublicMetaDBSegmentFields(title: "Credits (optional)", draft: $credits)
                    if content.mediaType == .tv {
                        PublicMetaDBSegmentFields(title: "Recap (optional)", draft: $recap)
                        PublicMetaDBSegmentFields(title: "Preview (optional)", draft: $preview)
                    }
                }
                Text("Use milliseconds from the release you checked. Leave both fields empty for absent segments. These timestamps and your contributor name will be public.")
                    .foregroundStyle(.secondary)
                Toggle("I verified these timestamps for this title and release", isOn: $verified)
                Button("Review contribution") { prepare() }
                    .disabled(!operation.permitsWrite || !verified || service.phase != .connected)
            }
            if let failure { PublicMetaDBFailureMessage(error: failure) }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Publish this community contribution?", isPresented: $confirming, presenting: draft) { draft in
            Button("Publish contribution") { operation.perform { try await draft.publish(to: service) } }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            switch draft {
            case .skip(let skip, _): PublicMetaDBSkipDescription(skip: skip)
            case .highlight(let highlight, _): PublicMetaDBSegmentLabel(segment: highlight.segment)
            }
            Text("Public on PublicMetaDB. Plozz does not change server markers or enable automatic skipping.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            verified = false
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }

    private func prepare() {
        do {
            guard let connection = service.connectionID else { throw PublicMetaDB.Failure.disconnected }
            if isHighlight {
                guard let segment = try highlight.segment() else { throw PublicMetaDB.Failure.invalidInput }
                let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
                draft = .highlight(try .init(content: content, segment: segment, description: text.isEmpty ? nil : text), connection)
            } else {
                guard let source else { throw PublicMetaDB.Failure.invalidInput }
                draft = .skip(try .init(
                    content: content, source: source, intro: intro.segment(), credits: credits.segment(),
                    recap: recap.segment(), preview: preview.segment()
                ), connection)
            }
            failure = nil
            confirming = true
        } catch { failure = error }
    }
}
#endif
