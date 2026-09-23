#if canImport(SwiftUI)
import SwiftUI

struct LinkCodeExpiryCountdown: View {
    let expiresAt: Date
    let lifetime: TimeInterval
    var size: CGFloat = 104
    var showsMinutes = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, expiresAt.timeIntervalSince(context.date))
            let fraction = lifetime > 0 ? min(1, remaining / lifetime) : 0
            let tint: Color = remaining <= 30 ? .orange : .accentColor
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
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
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            }
            .frame(width: size, height: size)
            .animation(.linear(duration: 1), value: fraction)
            .animation(.easeOut(duration: 0.3), value: tint)
            .accessibilityLabel("Code expires in \(Int(remaining.rounded(.up))) seconds")
        }
    }
}
#endif
