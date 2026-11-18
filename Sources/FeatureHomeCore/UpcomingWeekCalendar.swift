#if os(tvOS)
import CoreUI
import SwiftUI

struct UpcomingCalendarWeek {
    let days: [Date]
    let previous: Date
    let next: Date

    init(containing date: Date, calendar: Calendar) {
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        days = (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        previous = calendar.date(byAdding: .weekOfYear, value: -1, to: start)!
        next = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
    }

    func canMoveBackward(in interval: DateInterval) -> Bool { days[0] > interval.start }
    func canMoveForward(in interval: DateInterval) -> Bool { next < interval.end }
}

struct UpcomingWeekCalendar: View {
    @Binding var selectedDay: Date
    @Binding var displayedWeek: Date
    let interval: DateInterval
    @Environment(\.calendar) private var calendar
    @Environment(\.themePalette) private var palette

    var body: some View {
        let week = UpcomingCalendarWeek(containing: displayedWeek, calendar: calendar)
        VStack(alignment: .leading, spacing: 16) {
            Text(week.days[0]..<week.days[6], format: .interval.month(.wide).day().year())
                .font(.headline)
                .foregroundStyle(palette.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("upcoming.week.range")
            HStack(spacing: 16) {
                control(
                    Button { displayedWeek = week.previous } label: {
                        Image(systemName: "chevron.backward")
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.regular)
                            .frame(width: 24, height: 48)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                        .accessibilityLabel("Previous week")
                        .help("Previous week")
                        .accessibilityIdentifier("upcoming.week.previous")
                        .disabled(!week.canMoveBackward(in: interval)),
                    width: 80
                )
                ForEach(week.days, id: \.self) { day in
                    control(dayButton(day))
                        .modifier(UpcomingDateSelectionBackground(
                            isSelected: calendar.isDate(day, inSameDayAs: selectedDay)
                        ))
                        .disabled(day < interval.start || day >= interval.end)
                }
                control(
                    Button { displayedWeek = week.next } label: {
                        Image(systemName: "chevron.forward")
                            .resizable()
                            .scaledToFit()
                            .fontWeight(.regular)
                            .frame(width: 24, height: 48)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                        .buttonBorderShape(.roundedRectangle(radius: 16))
                        .accessibilityLabel("Next week")
                        .help("Next week")
                        .accessibilityIdentifier("upcoming.week.next")
                        .disabled(!week.canMoveForward(in: interval)),
                    width: 80
                )
            }
        }
        .plozzActionButton(role: .secondary)
        .tint(palette.primaryText)
        .focusSection()
        .navigationEntryFocus(.fallback)
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selectedDay)
        let isToday = calendar.isDateInToday(day)
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 4) {
                (isToday ? Text("Today") : Text(day, format: .dateTime.weekday(.abbreviated)))
                    .font(.caption)
                Text(day, format: .dateTime.day())
                    .font(.title3)
                    .fontWeight(isToday ? .bold : .regular)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
        }
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .plozzActionButton(role: .secondary)
        .navigationEntryFocus(isSelected ? .content : nil)
        .accessibilityLabel(Text(day, format: .dateTime.weekday(.wide).month(.wide).day().year()))
        .accessibilityValue(isToday ? Text("Today") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("upcoming.week.day.\(Int(day.timeIntervalSinceReferenceDate))")
    }

    @ViewBuilder
    private func control(_ button: some View, width: CGFloat? = nil) -> some View {
        if #available(tvOS 26.0, *) {
            button.buttonSizing(.flexible)
                .frame(minWidth: width, maxWidth: width ?? .infinity, minHeight: 92, maxHeight: 92)
        } else {
            button.frame(minWidth: width, maxWidth: width ?? .infinity, minHeight: 92, maxHeight: 92)
        }
    }
}

struct UpcomingDateSelectionBackground: ViewModifier {
    let isSelected: Bool
    @Environment(\.themePalette) private var palette

    func body(content: Content) -> some View {
        content.background(
            palette.primaryText.opacity(isSelected ? 0.14 : 0),
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}
#endif
