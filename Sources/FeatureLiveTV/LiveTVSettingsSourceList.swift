import CoreUI
import SwiftUI

struct LiveTVSettingsSourceList<Source: Identifiable, Content: View, Setup: View>: View {
    let sources: [Source]
    @ViewBuilder let content: (Source) -> Content
    @ViewBuilder let setup: () -> Setup
    @State private var addingSource = false

    var body: some View {
        SettingsSectionGroup(SettingsCopy.tvSources, accessory: {
            Button { addingSource = true } label: {
                Label {
                    Text(SettingsCopy.addTVSource)
                } icon: {
                    Image(systemName: "plus")
                }
            }
                .font(.body)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("live-tv-add-source")
        }) {
            if sources.isEmpty {
                Text("Connect an IPTV provider or use Live TV from a media server.")
                    .settingsRowSecondary()
            } else {
                LiveTVBoundedSourceRows {
                    ForEach(sources) { source in content(source) }
                }
            }
        }
        .settingsPageDestination(isPresented: $addingSource, destination: setup)
    }
}

struct LiveTVBoundedSourceRows<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @State private var heights: [Subview.ID: CGFloat] = [:]

    var body: some View {
        Group(subviews: content()) { rows in
            if rows.count > 4 {
                FadingScrollView(
                    maxHeight: maximumHeight(for: rows),
                    fadeLength: 34, verticalContentInset: 8
                ) {
                    LiveTVMeasuredSourceRows(rows: rows, heights: $heights)
                }
                #if os(tvOS)
                .focusSection()
                #endif
                .accessibilityIdentifier("live-tv-sources-list")
            } else {
                LiveTVMeasuredSourceRows(rows: rows, heights: $heights)
                    .accessibilityIdentifier("live-tv-sources-list")
            }
        }
    }

    private func maximumHeight(for rows: SubviewsCollection) -> CGFloat {
        let measured = rows.prefix(5).map { heights[$0.id] ?? 100 }
        return 8 + measured.prefix(4).reduce(0, +)
            + (measured.last ?? 100) / 2 + 4 * SettingsRowMetrics.formRowSpacing
    }
}

private struct LiveTVMeasuredSourceRows: View {
    let rows: SubviewsCollection
    @Binding var heights: [Subview.ID: CGFloat]

    var body: some View {
        VStack(spacing: SettingsRowMetrics.formRowSpacing) {
            ForEach(rows) { row in
                row
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > 0 else { return }
                        heights[row.id] = height
                    }
            }
        }
    }
}
