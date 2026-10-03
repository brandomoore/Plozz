#if canImport(SwiftUI) && canImport(UIKit)
import CoreUI
import SwiftUI

struct PlayerOptionsRowSpec: Identifiable {
    enum Kind {
        case number(value: Text, step: (Int) -> Void)
        case choice(value: Text, prev: () -> Void, next: () -> Void)
        case toggle(isOn: Bool, flip: () -> Void)
        case submenu(summary: Text, open: () -> Void)
        case action(run: () -> Void)
    }

    let slot: Int
    let title: LocalizedStringResource
    let kind: Kind
    var id: Int { slot }
}

struct PlayerOptionsRow: View {
    let row: PlayerOptionsRowSpec
    let palette: ThemePalette
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    var titleLineLimit = 1

    private var isFocused: Bool { focus == .row(row.slot) }

    var body: some View {
        Button {
            switch row.kind {
            case let .number(_, step): step(1)
            case let .choice(_, _, next): next()
            case let .toggle(_, flip): flip()
            case let .submenu(_, open): open()
            case let .action(run): run()
            }
        } label: {
            HStack(spacing: 10) {
                Text(row.title)
                    .font(.body)
                    .lineLimit(titleLineLimit)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlayerMenuRowButtonStyle())
        .focusEffectDisabled()
        .focused($focus, equals: .row(row.slot))
        .accessibilityIdentifier("player-settings-row-\(row.slot)")
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if case .number = row.kind, isFocused {
                Image(systemName: "minus").font(.body.weight(.semibold))
            }
            value
            switch row.kind {
            case .number:
                if isFocused { Image(systemName: "plus").font(.body.weight(.semibold)) }
            case .submenu:
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .playerMenuRowSecondary()
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        switch row.kind {
        case let .number(value, _):
            value.font(.body).monospacedDigit().playerMenuRowSecondary()
        case let .choice(value, _, _):
            value.font(.body).lineLimit(2).multilineTextAlignment(.trailing).playerMenuRowSecondary()
        case let .toggle(isOn, _):
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .playerMenuRowMark(isSelected: isOn, accent: palette.accent)
        case let .submenu(summary, _):
            summary.font(.body).playerMenuRowSecondary()
        case .action:
            EmptyView()
        }
    }
}

struct PlayerOptionsInputScope<Screen: Equatable, Content: View>: View {
    let screen: Screen
    let rows: [PlayerOptionsRowSpec]
    @FocusState.Binding var focus: PlayerControls.FocusSlot?
    let content: Content
    @State private var accelerator = SubtitleStyleAccelerator()

    var body: some View {
        #if os(tvOS)
        PlayerOptionsFocusScope(
            content: content,
            screen: screen,
            adjustableRow: {
                guard let row = focusedRow else { return nil }
                switch row.kind {
                case .number, .choice: return row.slot
                default: return nil
                }
            },
            submenuRow: {
                guard let row = focusedRow, case .submenu = row.kind else { return nil }
                return row.slot
            },
            onMove: { direction, isRepeat in
                if !isRepeat { accelerator = SubtitleStyleAccelerator() }
                move(direction)
            }
        )
        #else
        content
        #endif
    }

    private var focusedRow: PlayerOptionsRowSpec? {
        guard case let .row(slot)? = focus else { return nil }
        return rows.first { $0.slot == slot }
    }

    private func move(_ direction: PlozzMoveCommandDirection) {
        guard let row = focusedRow else { return }
        switch (direction, row.kind) {
        case let (.left, .number(_, step)):
            step(-accelerator.magnitude(slot: row.slot, sign: -1))
        case let (.right, .number(_, step)):
            step(accelerator.magnitude(slot: row.slot, sign: 1))
        case let (.left, .choice(_, prev, _)): prev()
        case let (.right, .choice(_, _, next)): next()
        case let (.right, .submenu(_, open)): open()
        default: break
        }
    }
}
#endif
