import MailModel
import SwiftUI

/// Meeting details under the header of an invite, like Outlook's: when and where, who, the answer buttons,
/// and notes about missing answers and conflicts.
struct InviteCard: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let message: Message
    let invite: Invite

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                attendees("Required:", invite.required)
                if !invite.optional.isEmpty { attendees("Optional:", invite.optional) }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(invite.when()).font(.system(size: 13, weight: .semibold))
                        if !invite.location.isEmpty { Text(invite.location).font(.system(size: 13, weight: .semibold)) }
                    }
                }
                .padding(.top, 2)
                if !store.canAnswer(message.id) {
                    // Your own invite or cancellation: nothing to answer, as in Outlook.
                } else if invite.isCancellation == true {
                    // Outlook offers only this for a cancellation.
                    Button { store.removeFromCalendar(message.id) } label: {
                        Label("Remove from Calendar", systemImage: "xmark").font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                } else {
                    HStack(spacing: 8) {
                        answer(.accept, "Accept", "checkmark")
                        answer(.tentative, "Tentative", "questionmark")
                        answer(.decline, "Decline", "xmark")
                        Menu {
                            Button("Tentative and Propose New Time…") { write(.tentative, proposing: true) }
                            Button("Decline and Propose New Time…") { write(.decline, proposing: true) }
                        } label: {
                            Label("Propose New Time", systemImage: "clock").font(.system(size: 12))
                        }
                        .fixedSize()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if invite.isCancellation != true, store.canAnswer(message.id) {
                if let r = invite.response {
                    banner(answered(r), "checkmark.circle", .blue)
                } else {
                    banner("Please respond.", "info.circle", .blue)
                }
            }
            let conflicts = invite.conflicts(in: store.dayEvents[message.id] ?? [], subject: message.subject)
            if invite.isCancellation != true, !conflicts.isEmpty {
                banner(conflicts.count == 1 ? "This meeting conflicts with another event on your calendar."
                       : "This meeting conflicts with \(conflicts.count) other events on your calendar.",
                       "exclamationmark.triangle", .yellow)
            }
        }
    }

    private func attendees(_ label: String, _ list: [Contact]) -> some View {
        let shown = list.prefix(8).map(\.name).joined(separator: "; ")
        let more = list.count > 8 ? "  + \(list.count - 8) more" : ""
        return (Text(label + " ").foregroundStyle(.secondary) + Text(shown) + Text(more).foregroundStyle(Color.accentColor))
            .font(.system(size: 12))
            .lineLimit(2)
            .textSelection(.enabled)
    }

    /// Outlook's answer button: a menu with the three ways to answer. The answer given is outlined and filled in
    /// the accent colour around the button (a bordered menu button ignores `tint` and prominent styles on macOS).
    private func answer(_ r: InviteResponse, _ title: String, _ symbol: String) -> some View {
        let chosen = invite.response == r
        return Menu {
            Button("Respond with Comments…") { write(r) }
            Button("Respond without Comments") { store.respond(r, to: message.id) }
            Button("Do Not Send a Response") { store.respond(InviteReply(response: r, send: false), to: message.id) }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 12))
        }
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(chosen ? 0.25 : 0)).padding(-2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: chosen ? 1.5 : 0).padding(-2))
    }

    /// Like Outlook: the answer opens as a message to the organizer, sent when you press Send.
    private func write(_ r: InviteResponse, proposing: Bool = false) {
        openWindow(id: "compose", value: ComposeWindow(store.answerDraft(r, to: message.id, proposing: proposing)))
    }

    private func answered(_ r: InviteResponse) -> String {
        var text = "You answered: \(r.title)"
        if let reply = invite.reply {
            if let s = reply.proposedStart, let e = reply.proposedEnd {
                text += ", proposing \(s.formatted(date: .abbreviated, time: .shortened)) – \(e.formatted(date: .omitted, time: .shortened))"
            }
            if !reply.send { text += " (the organizer wasn't told)" }
        }
        return text + "."
    }

    private func banner(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 5)
            .background(tint.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
    }
}

extension InviteResponse {
    var title: String {
        switch self {
        case .accept: "Accept"
        case .tentative: "Tentative"
        case .decline: "Decline"
        }
    }
}

/// The invite's day: one column of hours with the calendar's entries, overlaps side by side,
/// and the invite's own slot hatched.
struct DayColumn: View {
    let invite: Invite
    let subject: String
    let events: [CalendarEvent]?
    /// The calendar couldn't be read: no spinner, a note instead.
    var unavailable = false

    static let hourHeight: CGFloat = 44
    private let cal = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // An all-day invite's day as read for its calendar (BUG-200), not the organizer's midnight in UTC.
            Text((invite.isAllDay ? invite.allDayDays().0 : invite.start).formatted(.dateTime.weekday(.wide).day().month()))
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
            // An all-day invite is marked in the all-day row, hatched, not as a 24-hour block in the grid.
            if invite.isAllDay {
                Text(subject).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Hatch().stroke(Color.accentColor.opacity(0.5), lineWidth: 1).background(Color.accentColor.opacity(0.08)))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
            ForEach(allDay, id: \.self) { e in
                Text(e.subject).font(.system(size: 11)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18))
            }
            if events == nil {
                if unavailable {
                    Text("Calendar not available").font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding()
                }
            }
            grid
        }
    }

    /// The day's all-day entries, without the all-day invite's own (it has its hatched row).
    private var allDay: [CalendarEvent] {
        (events ?? []).filter { $0.isAllDay && !(invite.isAllDay && invite.isOwnEntry($0, subject: subject)) }
    }

    private var hours: ClosedRange<Int> { DayLayout.hours(for: invite, events: events ?? [], calendar: cal) }

    private func y(_ d: Date) -> CGFloat {
        let c = cal.dateComponents([.hour, .minute], from: d)
        let sameDay = cal.isDate(d, inSameDayAs: invite.start)
        let h = sameDay ? Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60 : (d < invite.start ? 0 : 24)
        return CGFloat(h - Double(hours.lowerBound)) * Self.hourHeight
    }

    private var grid: some View {
        let height = CGFloat(hours.count - 1) * Self.hourHeight
        return GeometryReader { geo in
            let gutter: CGFloat = 30, w = geo.size.width - gutter
            ZStack(alignment: .topLeading) {
                ForEach(Array(hours), id: \.self) { h in
                    let top = CGFloat(h - hours.lowerBound) * Self.hourHeight
                    Text("\(h)").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: top - 6)
                    Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: w, height: 1)
                        .offset(x: gutter, y: top)
                }
                // The invite's slot, hatched, under the entries.
                if !invite.isAllDay {
                    Hatch()
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                        .background(Color.accentColor.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: w, height: max(12, y(invite.end) - y(invite.start)))
                        .offset(x: gutter, y: y(invite.start))
                }
                ForEach(DayLayout.columns(events ?? []), id: \.self) { p in
                    let own = invite.isOwnEntry(p.event, subject: subject)
                    let colW = w / CGFloat(p.of)
                    EventBox(event: p.event, own: own)
                        .frame(width: colW - 2, height: max(14, y(p.event.end) - y(p.event.start) - 1))
                        .offset(x: gutter + CGFloat(p.column) * colW + 1, y: y(p.event.start) + 1)
                }
            }
        }
        .frame(height: height + 8)
        .padding(.top, 8)
        .padding(.trailing, 8)
    }
}

private struct EventBox: View {
    let event: CalendarEvent
    let own: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(stripe).frame(width: 3)
            Text(event.subject)
                .font(.system(size: 11, weight: own ? .semibold : .regular))
                .foregroundStyle(event.busy == .free ? .secondary : .primary)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.accentColor.opacity(own ? 0.10 : 0.20))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var stripe: Color {
        switch event.busy {
        case .busy: .accentColor
        case .tentative: .accentColor.opacity(0.45)
        case .away: .purple
        case .free, .unknown: .secondary.opacity(0.4)
        }
    }
}

/// Diagonal lines, for the invite's own time slot.
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // Lines y = x' - x (45°), clipped to the rectangle.
        var x = -rect.height
        while x < rect.width {
            let x0 = max(x, 0), x1 = min(x + rect.height, rect.width)
            p.move(to: CGPoint(x: rect.minX + x0, y: rect.minY + x0 - x))
            p.addLine(to: CGPoint(x: rect.minX + x1, y: rect.minY + x1 - x))
            x += 8
        }
        return p
    }
}
