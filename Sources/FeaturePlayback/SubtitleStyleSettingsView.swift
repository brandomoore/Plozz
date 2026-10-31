#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public struct SubtitleStyleSettingsView: View {
    @Binding private var style: SubtitleStyle
    private let isLiveTV: Bool
    @State private var controls = PlayerControlsModel()
    @State private var secondaryVisible = false
    @State private var prepared = false
    @State private var previewOptions = SubtitlePreviewOptions()
    #if os(tvOS)
    @SettingsPageDismiss private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screen = PlayerControls.SubtitleScreen.style
    @State private var returningToParent = false
    #endif

    public init(style: Binding<SubtitleStyle>, isLiveTV: Bool = false) {
        _style = style
        self.isLiveTV = isLiveTV
    }

    public var body: some View {
        GeometryReader { geometry in
            let context = SubtitleStyleEditingContext(
                controls: controls, style: $style, secondaryPreview: secondaryPreview,
                offersDualSubtitles: !isLiveTV
            )
            #if os(tvOS)
            VStack(alignment: .leading, spacing: SettingsFormMetrics.sectionSpacing) {
                SettingsPageHeader(pageTitle)
                TelevisionSubtitleStyleColumn(
                    context: context, screen: Binding(get: { screen }, set: openScreen),
                    returningToParent: returningToParent, style: style,
                    secondaryVisible: secondaryVisible, previewOptions: previewOptions
                )
                .frame(width: SubtitleStylePanel.panelWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, SettingsFormMetrics.pageTopInset)
            .padding(.bottom, SettingsFormMetrics.pageBottomInset)
            .overlay(alignment: .trailing) {
                SubtitleStylePreview(
                    style: style, secondaryVisible: secondaryVisible,
                    referenceSize: SubtitleStylePreviewMetrics.televisionCanvas,
                    options: previewOptions
                )
                .frame(width: max(0, geometry.size.width - SubtitleStylePanel.panelWidth - 44))
                .allowsHitTesting(false)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("subtitle-style-preview")
            }
            #else
            let width = max(geometry.size.width, geometry.size.height)
            let reference = CGSize(width: width, height: width * 9 / 16)
            let layout = geometry.size.width > geometry.size.height
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
            layout {
                SubtitleStylePreview(
                    style: style, secondaryVisible: secondaryVisible,
                    referenceSize: reference, options: previewOptions
                )
                .frame(maxWidth: .infinity)
                NavigationStack {
                    MobileSubtitleStyleEditor(viewModel: context)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif
        }
        .padding(.horizontal, pageInset)
        #if !os(tvOS)
        .padding(.vertical, 24)
        #endif
        .background { SettingsPageBackground() }
        #if os(tvOS)
        .navigationTitle(Text(verbatim: ""))
        .onExitCommand {
            if screen == .style { dismiss() }
            else { openScreen(screen.parent) }
        }
        #else
        .navigationTitle(Text(pageTitle))
        #if os(iOS)
        .toolbarTitleDisplayMode(.inline)
        #endif
        #endif
        .onChange(of: style, initial: true) { previous, value in
            controls.subtitleStyle = value
            controls.subtitlesRenderHDR = true
            previewOptions.styleDidChange(from: previous, to: value)
            if value.secondary == nil { secondaryVisible = false }
        }
        .onAppear {
            guard !prepared else { return }
            prepared = true
            secondaryVisible = !isLiveTV && style.secondary != nil
        }
    }

    private var pageTitle: LocalizedStringResource {
        isLiveTV ? "Customize Live TV subtitles" : "Customize subtitle style"
    }

    #if os(tvOS)
    private func openScreen(_ next: PlayerControls.SubtitleScreen) {
        returningToParent = next == screen.parent
        withAnimation(reduceMotion ? nil : SettingsPageMotion.animation) {
            screen = next
        }
    }
    #endif

    private var pageInset: CGFloat {
        #if os(tvOS)
        48
        #else
        16
        #endif
    }

    private var secondaryPreview: Binding<Bool> {
        Binding(
            get: { secondaryVisible },
            set: {
                if $0, style.secondary == nil {
                    style.secondary = .init()
                    controls.subtitleStyle = style
                }
                secondaryVisible = $0
            }
        )
    }
}

#if os(tvOS)
private struct TelevisionSubtitleStyleColumn: View {
    let context: SubtitleStyleEditingContext
    @Binding var screen: PlayerControls.SubtitleScreen
    let returningToParent: Bool
    let style: SubtitleStyle
    let secondaryVisible: Bool
    let previewOptions: SubtitlePreviewOptions
    @FocusState private var previewFocus: SubtitlePreviewControl?
    @State private var fullscreenPresented = false

    var body: some View {
        VStack(spacing: SettingsFormMetrics.controlSpacing) {
            TelevisionSubtitleStyleEditor(
                context: context, screen: $screen, returningToParent: returningToParent
            )
            SubtitlePreviewControls(
                style: style, secondaryVisible: secondaryVisible, options: previewOptions,
                fullscreenPresented: $fullscreenPresented, focus: $previewFocus
            )
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct TelevisionSubtitleStyleEditor: View {
    let context: SubtitleStyleEditingContext
    @Binding var screen: PlayerControls.SubtitleScreen
    let returningToParent: Bool
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: PlayerControls.FocusSlot?
    @Environment(SettingsSearchRequest.self) private var searchRequest: SettingsSearchRequest?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                page
            }
            .id(screen)
            .transition(reduceMotion ? .identity : SettingsPageMotion.transition(isReturning: returningToParent))
        }
        .frame(maxHeight: .infinity)
        .padding(.top, SettingsFormMetrics.groupInset)
        .padding(.bottom, SettingsFormMetrics.headingInset)
        .settingsGroupSurface(cornerRadius: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subtitle-style-editor-card")
        .task(id: screen) {
            guard screen != .style || searchRequest?.revealed != false else { return }
            focus = nil
            await Task.yield()
            guard !Task.isCancelled else { return }
            let style = context.effectiveStyle
            switch screen {
            case .styleFont:
                focus = .row(style.systemFont == nil && style.fontDescriptor == nil
                    ? SubtitleFontFamily.allCases.firstIndex(of: style.fontFamily) ?? 0
                    : SubtitleFontFamily.allCases.count)
            case .styleSystemFont:
                focus = .row(SubtitleSystemFonts.all.firstIndex {
                    $0.id == style.systemFont
                } ?? 0)
            default: focus = .row(0)
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: SettingsFormMetrics.relatedControlSpacing) {
            if screen != .style {
                HStack(spacing: 16) {
                    SettingsBackButton {
                        screen = screen.parent
                    }
                    .focused($focus, equals: .subBack)
                    Text(title).font(.headline)
                    Spacer()
                }
                .padding(.horizontal, SettingsFormMetrics.pageInset)
                Divider().padding(.horizontal, SettingsFormMetrics.pageInset)
            }
            SubtitleStylePanel(
                screen: screen, model: context.controls, palette: palette,
                actions: PlayerOptionsActions(setSubtitleStyle: context.applySubtitleStyle),
                focus: $focus,
                openScreen: { screen = $0 },
                secondaryPreview: context.secondaryPreview,
                offersDualSubtitles: context.offersDualSubtitles,
                separatesSettingsRows: true
            )
        }
    }

    private var title: LocalizedStringResource {
        switch screen {
        case .styleFont: "Font"
        case .styleSystemFont: "System Fonts"
        case .styleOutline: "Shadow & Outline"
        case .styleBackground: "Background"
        case .styleDual: "Dual Subtitles"
        case .styleFileFormatting: "File Formatting"
        default: "Appearance"
        }
    }
}
#endif
#endif
