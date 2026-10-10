import SwiftUI

/// A non-interactive setup status, with measured counts rather than estimated completion.
public struct SetupProgressCard: View {
    public let title: LocalizedStringResource
    public let detail: LocalizedStringResource
    public let symbol: String
    public let count: Int?
    public let countLabel: LocalizedStringResource

    @Environment(\.themePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        title: LocalizedStringResource,
        detail: LocalizedStringResource,
        symbol: String = "text.badge.plus",
        count: Int? = nil,
        countLabel: LocalizedStringResource = "Playlist entries read"
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.count = count
        self.countLabel = countLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(palette.primaryText)
                    .padding(16)
                    .background(palette.fill, in: RoundedRectangle(cornerRadius: 16))
                    .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(contrast == .increased ? palette.primaryText : palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let count {
                VStack(alignment: .leading, spacing: 4) {
                    SetupProgressNumber(count: count)
                        .animation(reduceMotion ? nil : .linear(duration: 0.8), value: count)
                        .id(countLabel.key)
                        .accessibilityLabel(Text(count, format: .number))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(countLabel)
                        .font(.subheadline)
                        .foregroundStyle(contrast == .increased ? palette.primaryText : palette.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGroupSurface(cornerRadius: PlozzTheme.Metrics.Radius.card)
        .overlay {
            RoundedRectangle(cornerRadius: PlozzTheme.Metrics.Radius.card, style: .continuous)
                .strokeBorder(
                    palette.primaryText.opacity(contrast == .increased ? 0.8 : 0.22),
                    lineWidth: contrast == .increased ? 2 : 1
                )
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }
}

struct SetupProgressNumber: View, Animatable {
    private var value: Double
    let confirmedCount: Int

    init(count: Int) {
        value = Double(count)
        confirmedCount = count
    }

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var displayedCount: Int {
        value < Double(confirmedCount) ? Int(max(0, value)) : confirmedCount
    }

    var body: some View {
        Text(displayedCount, format: .number)
    }
}
