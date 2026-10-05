#if os(iOS)
import CoreUI
import FeatureLiveTVCore
import SwiftUI

struct LiveTVMultiviewTouchChrome: View {
    let coordinator: LiveTVMultiviewCoordinator
    let safeAreaInsets: EdgeInsets
    let exit: () -> Void
    let collapse: () -> Void
    let watch: () -> Void
    let setup: () -> Void
    let editing: () -> Void
    let add: () -> Void
    let replace: () -> Void
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?
    let onEditingInsetsChange: (EdgeInsets) -> Void
    @State private var headerHeight: CGFloat = 0
    @State private var toolbarHeight: CGFloat = 0
    @Environment(\.plozzReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .body) private var glyphHeight: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                .background {
                    LinearGradient(colors: [.black.opacity(0.72), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                        .allowsHitTesting(false)
                }
            Spacer(minLength: 12)
            toolbar
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(ThemePalette.dark.cardSurface.opacity(reduceTransparency ? 1 : 0.94))
                        .overlay {
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolbarHeight = $0 }
        }
        // The player canvas is physical-screen sized. Its parent passes the
        // original safe area before expanding that canvas under system chrome.
        .padding(safeAreaInsets)
        .foregroundStyle(.white)
        .tint(.white)
        .environment(\.themePalette, ThemePalette.dark)
        .onChange(of: editingInsets, initial: true) { _, insets in
            guard headerHeight > 0, toolbarHeight > 0 else { return }
            onEditingInsetsChange(insets)
        }
    }

    private var editingInsets: EdgeInsets {
        EdgeInsets(
            top: safeAreaInsets.top + headerHeight + 8,
            leading: safeAreaInsets.leading + 24,
            bottom: safeAreaInsets.bottom + toolbarHeight + 8,
            trailing: safeAreaInsets.trailing + 24
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: exit) {
                Label("Close Multiview", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(TouchHeroActionButtonStyle(kind: .secondary, circular: true))
            .accessibilityIdentifier("live-multiview-done")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("Multiview").font(.headline).fixedSize()
                    Spacer(minLength: 0)
                    watchButton
                }
                HStack {
                    Spacer(minLength: 0)
                    watchButton
                }
            }
        }
    }

    @ViewBuilder private var watchButton: some View {
        if coordinator.isEditingLayout {
            Button(action: watch) { Label("Watch", systemImage: "play.fill") }
                .buttonStyle(TouchHeroActionButtonStyle(kind: .primary))
                .accessibilityIdentifier("live-multiview-watch")
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarItems.fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                toolbarItems.fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
    }

    private var toolbarItems: some View {
        HStack(alignment: .top, spacing: 4) {
            if coordinator.isEditingLayout {
                if coordinator.canAdd {
                    Button(action: add) { toolLabel("Add", symbol: "plus") }
                        .accessibilityLabel("Add channel")
                        .accessibilityIdentifier("live-multiview-add")
                }
                Menu {
                    LiveTVMultiviewLayoutOptions(coordinator: coordinator, setup: setup)
                } label: {
                    toolLabel("Layout", symbol: "rectangle.split.2x1")
                }
                .accessibilityIdentifier("live-multiview-layout")
                .simultaneousGesture(TapGesture().onEnded { editing() })
            } else if coordinator.expandedPaneID != nil {
                Button(action: collapse) { toolLabel("Show all", symbol: "rectangle.split.2x2") }
                    .accessibilityIdentifier("live-multiview-collapse")
            } else {
                Button(action: setup) { toolLabel("Edit layout", symbol: "rectangle.split.2x2") }
                    .accessibilityIdentifier("live-multiview-edit")
            }
            if coordinator.panes.count > 1 {
                Menu {
                    ForEach(coordinator.panes) { pane in
                        Button {
                            coordinator.selectAudio(pane.id)
                        } label: {
                            Label {
                                if let name = pane.channel?.name { Text(verbatim: name) } else { Text("Channel") }
                            } icon: {
                                Image(systemName: coordinator.audiblePaneID == pane.id ? "checkmark" : "speaker")
                            }
                        }
                        .disabled(pane.preparation.current == nil)
                        .accessibilityIdentifier("live-multiview-listen-\(pane.id.uuidString)")
                    }
                } label: {
                    toolLabel("Audio", symbol: "speaker.wave.2")
                }
                .accessibilityIdentifier("live-multiview-audio")
                .simultaneousGesture(TapGesture().onEnded { editing() })
            }
            if toggleFavorite != nil || coordinator.isEditingLayout {
                moreMenu
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let toggleFavorite {
                Button(action: toggleFavorite) {
                    Label {
                        Text(isFavorite ? LocalizedStringResource("Unfavorite") : LocalizedStringResource("Favorite"))
                    } icon: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                    }
                }
                .accessibilityIdentifier("live-multiview-favorite")
                .accessibilityValue(isFavorite ? "Saved" : "Not saved")
            }
            if coordinator.isEditingLayout {
                Button("Replace", systemImage: "arrow.triangle.2.circlepath", action: replace)
                    .accessibilityIdentifier("live-multiview-replace")
                if coordinator.panes.count > 1 {
                    if coordinator.audiblePaneID != coordinator.primaryPaneID {
                        Button("Make main", systemImage: "rectangle.inset.filled") {
                            coordinator.promote(coordinator.audiblePaneID)
                        }
                        .accessibilityIdentifier("live-multiview-promote")
                    }
                    Button("Remove", systemImage: "minus.circle", role: .destructive) {
                        coordinator.remove(coordinator.audiblePaneID)
                    }
                    .accessibilityIdentifier("live-multiview-remove")
                }
            }
        } label: {
            toolLabel("More", symbol: "ellipsis")
        }
        .accessibilityIdentifier("live-multiview-more")
        .simultaneousGesture(TapGesture().onEnded { editing() })
    }

    private func toolLabel(_ title: LocalizedStringResource, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(height: glyphHeight)
            Text(title)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(minWidth: 52, minHeight: 52, alignment: .top)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
#endif
