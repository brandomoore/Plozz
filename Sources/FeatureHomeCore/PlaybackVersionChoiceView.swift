#if canImport(SwiftUI)
import CoreModels
import CoreUI
import SwiftUI

public extension View {
    func playbackVersionChoice(_ model: PlaybackVersionChoiceModel) -> some View {
        modifier(PlaybackVersionChoicePresentation(model: model))
    }
}

private struct PlaybackVersionChoicePresentation: ViewModifier {
    let model: PlaybackVersionChoiceModel

    func body(content: Content) -> some View {
        #if os(tvOS)
        // The player is already a full-screen presentation. A second cover
        // would disappear/cancel the playback owner while it waits for a choice.
        content
            .disabled(model.prompt != nil)
            .allowsHitTesting(model.prompt == nil)
            .accessibilityHidden(model.prompt != nil)
            .overlay {
                if model.prompt != nil {
                    GeometryReader { geometry in
                        ZStack {
                            PlozzDialogBackdrop()
                            ViewThatFits(in: .vertical) {
                                PlaybackVersionChoiceView(model: model)
                                    .fixedSize(horizontal: false, vertical: true)
                                PlaybackVersionChoiceView(model: model)
                            }
                            .frame(width: min(1_100, max(0, geometry.size.width - 64)))
                            .plozzSurface(.overlay, cornerRadius: 32)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("version-choice-dialog")
                            // Bound the proposal without stretching the card's surface.
                            .frame(maxHeight: min(860, max(0, geometry.size.height - 64)))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        #else
        content.plozzSheet(isPresented: Binding(
            get: { model.prompt != nil },
            set: { if !$0 { model.cancel() } }
        )) {
            PlaybackVersionChoiceView(model: model)
                .interactiveDismissDisabled()
        }
        #endif
    }
}

public struct PlaybackVersionChoiceView: View {
    let model: PlaybackVersionChoiceModel

    public init(model: PlaybackVersionChoiceModel) { self.model = model }

    public var body: some View {
        if let prompt = model.prompt {
            #if os(iOS)
            NavigationStack {
                PlaybackVersionChoiceContent(model: model, prompt: prompt)
                    .navigationTitle("Choose a version")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { model.cancel() }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("version-choice-cancel")
                        }
                    }
            }
            #else
            VStack(spacing: 0) {
                PlaybackVersionChoiceContent(model: model, prompt: prompt)
                Button("Cancel") { model.cancel() }
                    .plozzActionButton(role: .secondary)
                    .accessibilityIdentifier("version-choice-cancel")
                    .padding()
            }
            #if os(tvOS)
            .onExitCommand { model.cancel() }
            #endif
            #endif
        }
    }
}

private struct PlaybackVersionChoiceContent: View {
    let model: PlaybackVersionChoiceModel
    let prompt: PlaybackVersionChoiceModel.Prompt

    var body: some View {
        if prompt.needsIntroduction {
            FirstUseChoiceView(
                symbol: "square.stack",
                title: "Do you want to choose a version every time?",
                message: "Some videos have more than one version. Choose before each video, including the next episode, or let Plozz choose automatically.",
                firstAction: "Ask every time",
                secondAction: "Choose automatically",
                footer: "Change this any time in Settings > Playback > Version selection.",
                firstIdentifier: "version-choice-ask",
                secondIdentifier: "version-choice-automatic"
            ) { ask in
                model.chooseMode(ask ? .askEveryTime : .automatic, promptID: prompt.id)
            }
        } else {
            PlaybackVersionChoiceList(prompt: prompt) {
                model.chooseVersion($0, promptID: prompt.id)
            }
        }
    }
}

private struct PlaybackVersionChoiceList: View {
    let prompt: PlaybackVersionChoiceModel.Prompt
    let select: (String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.themePalette) private var palette
    @FocusState private var focusedID: String?
    #if os(tvOS)
    @ScaledMetric(relativeTo: .headline) private var headingSize: CGFloat = 34
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                #if !os(iOS)
                Text("Choose a version")
                    #if os(tvOS)
                    .font(.system(size: headingSize, weight: .semibold))
                    #else
                    .font(.title.bold())
                    #endif
                    .foregroundStyle(palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                #endif
                Text(verbatim: prompt.item.title)
                    .font(.headline)
                    .foregroundStyle(palette.secondaryText)
                ForEach(prompt.versions) { version in
                    MediaVersionChoiceButton(
                        presentation: .init(version, locale: locale),
                        isSelected: prompt.selectedVersionID == version.id,
                        isFocused: focusedID == version.id
                    ) {
                        select(version.id)
                    }
                    .focused($focusedID, equals: version.id)
                    .accessibilityIdentifier("version-choice-\(version.id)")
                }
            }
            .padding(32)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(tvOS)
        .defaultFocus($focusedID, prompt.selectedVersionID ?? prompt.versions.first?.id, priority: .userInitiated)
        #endif
    }
}

#endif
