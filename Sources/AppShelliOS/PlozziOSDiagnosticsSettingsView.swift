#if os(iOS)
import CoreModels
import CoreNetworking
import CoreUI
import CrashReporting
import Foundation
import SwiftUI
import UIKit

struct PlozziOSDiagnosticsSettingsView: View {
    let appModel: PlozziOSAppModel
    @Bindable var model: DiagnosticsSettingsModel
    @Bindable var crashReporting: CrashReportingSettingsModel
    @State private var diagnosticNote = ""
    @State private var sendStatus: LocalizedStringResource?
    @State private var isSending = false

    private var report: DiagnosticsReport {
        let version = AppVersionIdentity.current
        let providers = Set(appModel.accounts.map(\.server.provider.displayName))
            .sorted()
            .joined(separator: ", ")
        return DiagnosticsReport(
            appVersion: version.displayVersion,
            appBuild: version.build,
            providers: providers.isEmpty ? "None" : providers,
            repoURL: AppLinks.repository.absoluteString,
            recentLogTail: PlozzLog.privacyFilteredLogText(entries: PlozzLog.recentEntries(limit: 8)),
            marketingVersion: version.marketingVersion
        )
    }

    var body: some View {
        List {
            SettingsSectionGroup("Get Help") {
                if let issueURL = report.newIssueURL {
                    Link(destination: issueURL) {
                        Label("Report a Problem", systemImage: "ladybug")
                    }
                }
                if let feedbackURL = URL(
                    string: "mailto:hello@plozz.app?subject=Plozz%20Feedback"
                ) {
                    Link(destination: feedbackURL) {
                        Label("Send Feedback", systemImage: "envelope")
                    }
                }
                NavigationLink {
                    PlozziOSRecentActivityView()
                } label: {
                    Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                }
            }

            SettingsSectionGroup {
                Toggle(
                    "Share Crash Reports",
                    isOn: $crashReporting.isEnabled
                )
                .disabled(!appModel.crashReportingController.isConfigured)
            } footer: {
                if appModel.crashReportingController.isConfigured {
                    Text(SettingsCopy.automaticDiagnostics)
                    Text(SettingsCopy.automaticDiagnosticsExclusions)
                } else {
                    Text("Crash reporting is unavailable in this build.")
                }
            }

            SettingsSectionGroup("Send Diagnostics") {
                TextField("Optional note", text: $diagnosticNote, axis: .vertical)
                    .lineLimit(2...4)
                Button {
                    appModel.applyCrashReportingPreference()
                    let note = diagnosticNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    isSending = true
                    Task {
                        defer { isSending = false }
                        let sent = await CrashDiagnostics.send(note: note)
                        sendStatus = sent
                            ? "Diagnostics submitted for delivery. Thank you."
                            : "Couldn't submit diagnostics. Check that crash reporting is enabled and try again."
                    }
                } label: {
                    Label("Send to Developer", systemImage: "paperplane")
                }
                .disabled(
                    !appModel.crashReportingController.isConfigured
                        || !crashReporting.isEnabled
                        || isSending
                )

                if let sendStatus {
                    Text(sendStatus)
                        .plozzForeground(.secondary)
                }
            } footer: {
                Text(SettingsCopy.manualDiagnostics)
            }

            SettingsSectionGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Playback Diagnostics Overlay", isOn: $model.settings.isEnabled)
                    Text("Shows codec, bitrate, buffer, and memory during playback.")
                        .font(.footnote)
                        .plozzForeground(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "Home Performance Overlay",
                        isOn: $model.settings.homePerformanceOverlayEnabled
                    )
                    Text("Shows FPS, hitches, and thermal state on Home.")
                        .font(.footnote)
                        .plozzForeground(.secondary)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Help & Diagnostics")
        .onChange(of: crashReporting.isEnabled) {
            appModel.applyCrashReportingPreference()
            sendStatus = nil
        }
    }
}

private struct PlozziOSRecentActivityView: View {
    @State private var entries = PlozzLog.recentEntries(limit: 500)
    @State private var selectedCategory: String? = nil
    @State private var searchText = ""
    @State private var justCopied = false

    /// Distinct categories present, for the filter menu.
    private var categories: [String] {
        Array(Set(entries.map(\.category))).sorted()
    }

    /// Newest-first entries after applying the category + text filters.
    private var filtered: [PlozzLog.LogEntry] {
        entries.reversed().filter { entry in
            if let selectedCategory, entry.category != selectedCategory { return false }
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText),
               !entry.category.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    private var shareText: String {
        PlozzLog.privacyFilteredLogText(entries: Array(filtered.reversed()))
    }

    var body: some View {
        List {
            if filtered.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "No Recent Activity" : "No Matches",
                    systemImage: entries.isEmpty ? "waveform.slash" : "line.3.horizontal.decrease.circle",
                    description: Text(entries.isEmpty
                        ? "Activity recorded during this app session will appear here."
                        : "No log entries match the current filter.")
                )
            } else {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.category.capitalized)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption)
                                .plozzForeground(.secondary)
                        }
                        Text(entry.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .settingsPageSurface()
        .navigationTitle("Recent Activity")
        .searchable(text: $searchText, prompt: "Search messages")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Category", selection: $selectedCategory) {
                        Text("All Categories").tag(String?.none)
                        ForEach(categories, id: \.self) { cat in
                            Text(cat.capitalized).tag(String?.some(cat))
                        }
                    }
                } label: {
                    Label {
                        // The category is a log-subsystem name from our own
                        // logging, so it stays verbatim; "Filter" is copy.
                        selectedCategory.map { Text(verbatim: $0.capitalized) } ?? Text("Filter")
                    } icon: {
                        Image(systemName: selectedCategory == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    entries = PlozzLog.recentEntries(limit: 500)
                }
                // Copy is the reliable path: a toolbar ShareLink's sheet can present
                // with unresponsive buttons on iPad, so copying to the clipboard is
                // the dependable way to get the (filtered) log out for a bug report.
                Button {
                    UIPasteboard.general.string = shareText
                    justCopied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); justCopied = false }
                } label: {
                    Label(justCopied ? "Copied" : "Copy",
                          systemImage: justCopied ? "checkmark" : "doc.on.doc")
                }
                .disabled(filtered.isEmpty)
                ShareLink(item: shareText) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(filtered.isEmpty)
            }
        }
    }
}
#endif
