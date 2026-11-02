#if canImport(SwiftUI)
import SwiftUI

public struct LinkCodeExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval
    let size: CGFloat
    let showsMinutes: Bool
    let tint: Color

    public init(expiresAt: Date, lifetime: TimeInterval, size: CGFloat = 104,
                showsMinutes: Bool = false, tint: Color = .accentColor) {
        self.expiresAt = expiresAt
        self.lifetime = lifetime
        self.size = size
        self.showsMinutes = showsMinutes
        self.tint = tint
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? min(1, remaining / lifetime) : 0
            let tint: Color = remaining <= 30 ? .orange : self.tint
            #if os(iOS)
            let lineWidth = min(8, size / 13)
            #else
            let lineWidth: CGFloat = 8
            #endif
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Group {
                    if showsMinutes {
                        Text(timerInterval: context.date...max(context.date, expiresAt), countsDown: true)
                    } else {
                        Text(Int(remaining.rounded(.up)), format: .number)
                    }
                }
                .font(.system(size: size * 0.327, weight: .semibold, design: .rounded))
                .monospacedDigit()
                #if os(iOS)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(size / 8)
                #endif
                .foregroundStyle(tint)
                #if os(iOS)
                .transaction { $0.animation = nil }
                #else
                .contentTransition(.numericText())
                #endif
            }
            .frame(width: size, height: size)
            .animation(.linear(duration: 1), value: fraction)
            .animation(.easeOut(duration: 0.3), value: tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Code expires in \(Int(remaining.rounded(.up))) seconds")
            .accessibilityIdentifier("connection-code-countdown")
        }
    }
}
#endif
