#if canImport(SwiftUI)
import CoreUI
import PublicMetaDBService
import SwiftUI

enum PublicMetaDBHistoryAction {
    case deletePlay(PublicMetaDB.Record<PublicMetaDB.Watch>)
    case clearResume(PublicMetaDB.Record<PublicMetaDB.Resume>)
    case undrop(PublicMetaDB.Record<PublicMetaDB.Content>)
    case drop(PublicMetaDB.Content)

    var content: PublicMetaDB.Content {
        switch self {
        case .deletePlay(let record): record.value.content
        case .clearResume(let record): record.value.content
        case .undrop(let record): record.value
        case .drop(let content): content
        }
    }

    var label: LocalizedStringResource {
        switch self {
        case .deletePlay: "Delete this play"
        case .clearResume: "Clear this resume point"
        case .undrop: "Undrop title"
        case .drop: "Drop show"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .deletePlay:
            "Deletes only this play on PublicMetaDB, not other plays of the title. Plozz does not change media-server history."
        case .clearResume:
            "Clears this title's saved position on PublicMetaDB. Plozz does not clear the media server's position."
        case .undrop:
            "Removes this title from PublicMetaDB's dropped titles. Watched history and media-server state are unchanged."
        case .drop:
            "Hides this show from PublicMetaDB's Up Next, Progress, and Calendar without deleting watch history. Recording another episode or adding the show to a list can automatically undrop it. Plozz does not change media-server state."
        }
    }

    var role: ButtonRole? {
        switch self {
        case .deletePlay, .clearResume, .drop: .destructive
        case .undrop: nil
        }
    }

    @MainActor
    func perform(service: PublicMetaDBService, connectionID: UUID) async throws {
        switch self {
        case .deletePlay(let record): try await service.deleteHistoryPlay(record, expectedConnectionID: connectionID)
        case .clearResume(let record): try await service.clearHistoryResume(record, expectedConnectionID: connectionID)
        case .undrop(let record): try await service.restoreDroppedTitle(record, expectedConnectionID: connectionID)
        case .drop(let content): try await service.dropTitle(content, expectedConnectionID: connectionID)
        }
    }
}

struct PublicMetaDBHistoryRecordView: View {
    let service: PublicMetaDBService
    let action: PublicMetaDBHistoryAction
    @State private var operation = PublicMetaDBMutationOperation()
    @State private var confirming = false
    @State private var approvedConnection: UUID?

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader("PublicMetaDB record")
            PublicMetaDBContentLabel(content: action.content)
            NavigationLink("Title controls") { PublicMetaDBContentView(service: service, content: action.content) }
            if operation.succeeded {
                Text("Change confirmed on PublicMetaDB")
            } else {
                if case .deletePlay(let record) = action {
                    PublicMetaDBWatchDateLabel(date: record.value.watchedAt)
                    NavigationLink("Change watch date") {
                        PublicMetaDBHistoryDateView(service: service, content: record.value.content, existing: record)
                    }
                    NavigationLink("Add another play") {
                        PublicMetaDBHistoryDateView(service: service, content: record.value.content)
                    }
                }
                if case .clearResume(let record) = action {
                    Text(record.value.progress / 100, format: .percent.precision(.fractionLength(1)))
                }
                Text(action.explanation).foregroundStyle(.secondary)
                Button(role: action.role) {
                    approvedConnection = service.connectionID
                    confirming = true
                } label: { Text(action.label) }
                .disabled(!operation.permitsWrite || service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.history.action")
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Change this PublicMetaDB record?", isPresented: $confirming) {
            Button(role: action.role) {
                guard let approvedConnection else { return }
                operation.perform { try await action.perform(service: service, connectionID: approvedConnection) }
            } label: { Text(action.label) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(action.explanation)
            Text("Other apps connected to PublicMetaDB may also react to this change.")
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            approvedConnection = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}

struct PublicMetaDBWatchDateLabel: View {
    let date: Date?
    var body: some View {
        if let date {
            Text(date, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
        } else {
            Text("Watch date unknown").foregroundStyle(.secondary)
        }
    }
}

struct PublicMetaDBHistoryDateView: View {
    let service: PublicMetaDBService
    let content: PublicMetaDB.Content
    var existing: PublicMetaDB.Record<PublicMetaDB.Watch>?
    @State private var unknownDate = false
    @State private var date = Date()
    @State private var dateText = ""
    @State private var initialized = false
    @State private var confirming = false
    @State private var draft: Draft?
    @State private var operation = PublicMetaDBMutationOperation()

    private struct Draft {
        let date: PublicMetaDB.WatchDate
        let connectionID: UUID
    }

    private var selectedDate: PublicMetaDB.WatchDate? {
        if unknownDate { return .unknown }
        #if os(tvOS)
        return Self.parsedDate(dateText).map(PublicMetaDB.WatchDate.known)
        #else
        return .known(date)
        #endif
    }

    static func parsedDate(_ input: String) -> Date? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 40,
              text.range(
                of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$"#,
                options: .regularExpression
              ) != nil,
              let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
                ?? (try? Date.ISO8601FormatStyle().parse(text)) else { return nil }
        var offset = 0
        if !text.hasSuffix("Z") {
            let suffix = Array(text.suffix(6))
            guard let hours = Int(String(suffix[1...2])), let minutes = Int(String(suffix[4...5])),
                  hours <= 23, minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (suffix[0] == "-" ? -1 : 1)
        }
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let supplied = text.prefix(19).components(separatedBy: CharacterSet(charactersIn: "-T:")).compactMap(Int.init)
        guard [fields.year, fields.month, fields.day, fields.hour, fields.minute, fields.second].compactMap({ $0 }) == supplied else {
            return nil
        }
        return date
    }

    var body: some View {
        PublicMetaDBPage {
            SettingsPageHeader(existing == nil ? "Add a watched play" : "Change watch date")
            PublicMetaDBContentLabel(content: content)
            if operation.succeeded {
                Text("Change confirmed on PublicMetaDB")
            } else {
                Toggle("Watch date unknown", isOn: $unknownDate)
                if !unknownDate {
                    #if os(tvOS)
                    TextField("Date and time (ISO 8601)", text: $dateText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Include the time zone, for example 2026-01-15T20:30:00Z.")
                        .foregroundStyle(.secondary)
                    if selectedDate == nil { Text("Enter a valid date and time with its time zone.") }
                    #else
                    DatePicker("Watch date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                    #endif
                }
                if existing == nil {
                    Text("Adds a separate play on PublicMetaDB, even if this title was watched before. This is not a media-server history import.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Changes only this play's date on PublicMetaDB. Media-server history is unchanged.")
                        .foregroundStyle(.secondary)
                }
                Button("Review change") {
                    guard let selectedDate, let connectionID = service.connectionID else { return }
                    draft = Draft(date: selectedDate, connectionID: connectionID)
                    confirming = true
                }
                .disabled(!initialized || !operation.permitsWrite || selectedDate == nil || service.phase != .connected)
                .accessibilityIdentifier("publicmetadb.history.review-date")
            }
            PublicMetaDBMutationStatus(operation: operation)
        }
        .confirmationDialog("Save this PublicMetaDB play?", isPresented: $confirming, presenting: draft) { draft in
            Button("Save play") {
                operation.perform {
                    if let existing {
                        try await service.changeHistoryDate(existing, to: draft.date, expectedConnectionID: draft.connectionID)
                    } else {
                        try await service.addHistoryPlay(content, at: draft.date, expectedConnectionID: draft.connectionID)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { draft in
            if case .known(let date) = draft.date {
                Text(date, format: .dateTime.year().month().day().hour().minute())
            } else {
                Text("Watch date unknown")
            }
            if existing == nil { Text("This creates another play; it does not replace earlier plays.") }
            Text("Other apps connected to PublicMetaDB may also react to this change.")
        }
        .task {
            guard !initialized else { return }
            date = existing?.value.watchedAt ?? Date()
            unknownDate = existing != nil && existing?.value.watchedAt == nil
            dateText = date.formatted(.iso8601)
            initialized = true
        }
        .onChange(of: service.connectionID) { _, _ in
            confirming = false
            draft = nil
            operation.cancel()
        }
        .onDisappear { operation.cancel() }
    }
}
#endif
