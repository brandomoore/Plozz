#if canImport(SwiftUI)
import SwiftUI

/// Shared first-use introduction; persistence and Back behavior belong to its host.
public struct FirstUseChoiceView: View {
    let symbol: String
    let title: LocalizedStringResource
    let message: LocalizedStringResource
    let firstAction: LocalizedStringResource
    let secondAction: LocalizedStringResource
    let footer: LocalizedStringResource
    let firstIdentifier: String
    let secondIdentifier: String
    let messageAccessory: AnyView?
    let choose: (Bool) -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        symbol: String, title: LocalizedStringResource, message: LocalizedStringResource,
        firstAction: LocalizedStringResource, secondAction: LocalizedStringResource,
        footer: LocalizedStringResource, firstIdentifier: String, secondIdentifier: String,
        messageAccessory: AnyView? = nil,
        choose: @escaping (Bool) -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.firstAction = firstAction
        self.secondAction = secondAction
        self.footer = footer
        self.firstIdentifier = firstIdentifier
        self.secondIdentifier = secondIdentifier
        self.messageAccessory = messageAccessory
        self.choose = choose
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                FirstUseChoiceHeading(symbol: symbol, title: title, message: message, accessory: messageAccessory)
                FirstUseChoiceActions(
                    first: firstAction, second: secondAction,
                    firstIdentifier: firstIdentifier, secondIdentifier: secondIdentifier,
                    choose: choose
                )
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
            HStack(alignment: .top, spacing: 12) {
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
    let first: LocalizedStringResource
    let second: LocalizedStringResource
    let firstIdentifier: String
    let secondIdentifier: String
    let choose: (Bool) -> Void
    @FocusState private var focused: Bool?

    var body: some View {
        #if os(tvOS)
        let layout = AnyLayout(HStackLayout(spacing: 28))
        #else
        let layout = AnyLayout(VStackLayout(spacing: 16))
        #endif
        layout {
            Button { choose(true) } label: {
                Text(first).frame(maxWidth: .infinity)
            }
            .plozzActionButton(role: .secondary)
            .focused($focused, equals: true)
            .accessibilityIdentifier(firstIdentifier)
            Button { choose(false) } label: {
                Text(second).frame(maxWidth: .infinity)
            }
            .plozzActionButton(role: .secondary)
            .focused($focused, equals: false)
            .accessibilityIdentifier(secondIdentifier)
        }
        #if os(tvOS)
        .defaultFocus($focused, true, priority: .userInitiated)
        #endif
    }
}
#endif
