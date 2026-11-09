#if canImport(SwiftUI)
import SwiftUI

/// Shared first-use introduction; persistence and Back behavior belong to its host.
public struct FirstUseChoiceView: View {
    public struct Action: Identifiable {
        public let id: String
        let title: LocalizedStringResource
        let perform: () -> Void

        public init(_ title: LocalizedStringResource, identifier: String, perform: @escaping () -> Void) {
            self.id = identifier
            self.title = title
            self.perform = perform
        }
    }

    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let actions: [Action]
    let footer: LocalizedStringResource
    let messageAccessory: AnyView?
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        symbol: String, title: LocalizedStringResource, message: LocalizedStringResource,
        firstAction: LocalizedStringResource, secondAction: LocalizedStringResource,
        footer: LocalizedStringResource, firstIdentifier: String, secondIdentifier: String,
        messageAccessory: AnyView? = nil,
        choose: @escaping (Bool) -> Void
    ) {
        self.init(
            symbol: symbol, title: title, message: message,
            actions: [
                Action(firstAction, identifier: firstIdentifier) { choose(true) },
                Action(secondAction, identifier: secondIdentifier) { choose(false) }
            ],
            footer: footer, messageAccessory: messageAccessory
        )
    }

    public init(
        symbol: String, title: LocalizedStringResource, message: LocalizedStringResource,
        actions: [Action], footer: LocalizedStringResource, messageAccessory: AnyView? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actions = actions
        self.footer = footer
        self.messageAccessory = messageAccessory
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                FirstUseChoiceHeading(symbol: symbol, title: title, message: message, accessory: messageAccessory)
                FirstUseChoiceActions(actions: actions)
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if os(tvOS)
            .padding(56)
            .frame(maxWidth: 1_100, alignment: .leading)
            #else
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            #endif
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .tint(palette.accent)
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .transaction { if reduceMotion { $0.disablesAnimations = true } }
    }
}

private struct FirstUseChoiceHeading: View {
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let accessory: AnyView?
    @Environment(\.themePalette) private var palette
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(palette.primaryText)
                .accessibilityHidden(true)
            Text(title)
                #if os(tvOS)
                .font(.system(size: titleSize, weight: .bold, design: .rounded))
                #else
                .font(.title.bold())
                #endif
                .foregroundStyle(palette.primaryText)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .center, spacing: 12) {
                Text(message)
                    .font(.body)
                    .foregroundStyle(palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
            }
        }
    }
}

private struct FirstUseChoiceActions: View {
    let actions: [FirstUseChoiceView.Action]
    @FocusState private var focused: String?

    var body: some View {
        #if os(tvOS)
        let layout = actions.count > 2
            ? AnyLayout(VStackLayout(spacing: 20)) : AnyLayout(HStackLayout(spacing: 28))
        #else
        let layout = AnyLayout(VStackLayout(spacing: 16))
        #endif
        layout {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Text(action.title).frame(maxWidth: .infinity)
                }
                .plozzActionButton(role: .secondary)
                .focused($focused, equals: action.id)
                .accessibilityIdentifier(action.id)
            }
        }
        #if os(tvOS)
        .defaultFocus($focused, actions.first?.id, priority: .userInitiated)
        #endif
    }
}
#endif
