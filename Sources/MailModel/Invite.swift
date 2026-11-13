import Foundation

/// A meeting invite carried by a message (EWS MeetingRequest). Times are absolute; views show local time.
public struct Invite: Hashable, Codable, Sendable {
    public var start: Date
    public var end: Date
    public var location: String
    public var isAllDay: Bool
    public var organizer: Contact?
    public var required: [Contact]
    public var optional: [Contact]
    /// The answer given on this Mac, once there is one.
    public var response: InviteResponse?
    /// How it was given (comment, sent or not, proposed time). Optional for caches written before it existed.
    public var reply: InviteReply?
    /// A cancellation (EWS MeetingCancellation): it can only be removed from the calendar. Nil in older caches.
    public var isCancellation: Bool?

    public init(start: Date, end: Date, location: String = "", isAllDay: Bool = false, organizer: Contact? = nil,
                required: [Contact] = [], optional: [Contact] = [], response: InviteResponse? = nil,
                isCancellation: Bool? = nil) {
        self.isCancellation = isCancellation
        self.start = start; self.end = end; self.location = location; self.isAllDay = isAllDay
        self.organizer = organizer; self.required = required; self.optional = optional; self.response = response
    }

    /// Exchange puts an invite on the calendar as a tentative entry with the same subject and times.
    public func isOwnEntry(_ e: CalendarEvent, subject: String) -> Bool {
        e.start == start && e.end == end && e.subject == subject
    }

    /// Calendar entries that overlap the invite, without free time, all-day entries and the invite's own entry.
    public func conflicts(in events: [CalendarEvent], subject: String) -> [CalendarEvent] {
        events.filter { e in
            !e.isAllDay && e.busy != .free && !isOwnEntry(e, subject: subject) && e.start < end && e.end > start
        }
        .sorted { $0.start < $1.start }
    }
}

public enum InviteResponse: String, Hashable, Codable, Sendable, CaseIterable {
    case accept, tentative, decline
}

/// An answer with Outlook's options: a comment, not telling the organizer, or proposing another time
/// (with Tentative or Decline).
public struct InviteReply: Hashable, Codable, Sendable {
    public var response: InviteResponse
    public var comment: String?
    /// False: only the calendar changes; the organizer gets nothing ("Do Not Send a Response").
    public var send: Bool
    public var proposedStart: Date?
    public var proposedEnd: Date?

    public init(response: InviteResponse, comment: String? = nil, send: Bool = true,
                proposedStart: Date? = nil, proposedEnd: Date? = nil) {
        self.response = response; self.comment = comment; self.send = send
        self.proposedStart = proposedStart; self.proposedEnd = proposedEnd
    }

    public var proposesNewTime: Bool { proposedStart != nil }
}

public enum BusyStatus: String, Hashable, Codable, Sendable {
    case free, tentative, busy, away, unknown
}

/// One calendar entry, for the day column next to an invite.
public struct CalendarEvent: Hashable, Codable, Sendable {
    public var subject: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var busy: BusyStatus
    public init(subject: String, start: Date, end: Date, isAllDay: Bool = false, busy: BusyStatus = .busy) {
        self.subject = subject; self.start = start; self.end = end; self.isAllDay = isAllDay; self.busy = busy
    }
}

/// Places timed events in side-by-side columns where they overlap, like Outlook's day view.
public enum DayLayout {
    public struct Placed: Hashable, Sendable {
        public let event: CalendarEvent
        public let column: Int
        /// Columns in this group of overlapping events; the event's width is 1/of.
        public let of: Int
    }

    /// The time an entry takes in the column at least: the view draws a 0-minute entry (or one that ends before it
    /// starts) as tall as a short one, so it takes that room and nothing starting with it is drawn on top.
    public static let shortest: TimeInterval = 20 * 60

    public static func columns(_ events: [CalendarEvent]) -> [Placed] {
        let timed = events.filter { !$0.isAllDay }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        func end(_ e: CalendarEvent) -> Date { max(e.end, e.start.addingTimeInterval(shortest)) }
        var result: [Placed] = []
        var group: [(CalendarEvent, Int)] = [], columnEnds: [Date] = [], groupEnd = Date.distantPast
        func flush() {
            result += group.map { Placed(event: $0.0, column: $0.1, of: columnEnds.count) }
            group = []; columnEnds = []
        }
        for e in timed {
            if e.start >= groupEnd { flush() }
            let col = columnEnds.firstIndex { $0 <= e.start } ?? columnEnds.count
            if col == columnEnds.count { columnEnds.append(end(e)) } else { columnEnds[col] = end(e) }
            group.append((e, col))
            groupEnd = max(groupEnd, end(e))
        }
        flush()
        return result
    }

    /// The hours the invite's day column shows: 8–18, widened to the invite and the day's timed entries. A time on
    /// an earlier day counts as 0 h, on a later day as 24 h; an all-day invite goes in the all-day row instead.
    public static func hours(for invite: Invite, events: [CalendarEvent], calendar cal: Calendar = .current) -> ClosedRange<Int> {
        let times = (invite.isAllDay ? [] : [invite.start, invite.end]) + events.filter { !$0.isAllDay }.flatMap { [$0.start, $0.end] }
        func hour(_ d: Date, roundingUp: Bool) -> Int {
            guard cal.isDate(d, inSameDayAs: invite.start) else { return d < invite.start ? 0 : 24 }
            let c = cal.dateComponents([.hour, .minute], from: d)
            return (c.hour ?? 0) + (roundingUp && (c.minute ?? 0) > 0 ? 1 : 0)
        }
        let first = times.map { hour($0, roundingUp: false) }.min() ?? 8
        let last = times.map { hour($0, roundingUp: true) }.max() ?? 18
        return min(8, first)...max(18, min(24, last))
    }
}

/// The invite a compose window answers, and the new time when proposing one.
public struct InviteAnswer: Hashable, Codable, Sendable {
    public var messageID: UUID
    public var response: InviteResponse
    public var proposedStart: Date?
    public var proposedEnd: Date?
    public init(messageID: UUID, response: InviteResponse, proposedStart: Date? = nil, proposedEnd: Date? = nil) {
        self.messageID = messageID; self.response = response
        self.proposedStart = proposedStart; self.proposedEnd = proposedEnd
    }
}
