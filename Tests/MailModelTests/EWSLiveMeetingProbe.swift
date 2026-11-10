import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Read-only probe of a real meeting invite: prints element names, response codes and attendee status
/// values only, never names, addresses or text. Runs only with `EWS_PROBE=1` plus the `EWSLiveTests` settings.
struct EWSLiveMeetingProbe {
    static let backend = ProcessInfo.processInfo.environment["EWS_PROBE"] == "1" ? EWSLiveTests.backend : nil

    static let props = ["calendar:Start", "calendar:End", "calendar:Location", "calendar:IsAllDayEvent",
                        "calendar:Organizer", "calendar:RequiredAttendees", "calendar:OptionalAttendees",
                        "calendar:MyResponseType", "calendar:ConflictingMeetingCount", "meetingRequest:MeetingRequestType"]

    func getItem(_ id: String, _ b: EWSBackend) async throws -> XMLDocument {
        try await b.client.call("""
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
            \(Self.props.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined())</t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds><t:ItemId Id="\(xmlEscape(id))"/></m:ItemIds></m:GetItem>
            """, strict: false)
    }

    @Test(.enabled(if: EWSLiveMeetingProbe.backend != nil)) func probe() async throws {
        let b = try #require(Self.backend)
        let inbox = try #require(try await b.folders().first { $0.role == .inbox })
        let list = try await b.client.call("""
            <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>\
            <m:IndexedPageItemView MaxEntriesReturned="300" Offset="0" BasePoint="Beginning"/>\
            <m:ParentFolderIds><t:FolderId Id="\(xmlEscape(inbox.id))"/></m:ParentFolderIds></m:FindItem>
            """)
        let items = list.first("Items")?.elementChildren ?? []
        print("PROBE item kinds in newest 300:", Dictionary(grouping: items, by: { $0.localName ?? "" }).mapValues(\.count))
        guard let invite = items.first(where: { $0.localName == "MeetingRequest" }),
              let id = invite.child("ItemId")?.attr("Id") else { print("PROBE no meeting request found"); return }

        let doc = try await getItem(id, b)
        print("PROBE invite response:", doc.all("ResponseCode").map { $0.stringValue ?? "" })
        let item = try #require(doc.first("Items")?.elementChildren.first)
        print("PROBE invite fields:", item.elementChildren.compactMap(\.localName))
        for group in ["RequiredAttendees", "OptionalAttendees"] {
            let att = item.child(group)?.children("Attendee") ?? []
            print("PROBE \(group): \(att.count), statuses:", Set(att.compactMap { $0.text("ResponseType") }).sorted())
        }
        print("PROBE MyResponseType:", item.text("MyResponseType") ?? "-", "conflicts:", item.text("ConflictingMeetingCount") ?? "-")

        // The same calendar fields asked of a plain message: does the server refuse?
        if let plain = items.first(where: { $0.localName == "Message" }), let pid = plain.child("ItemId")?.attr("Id") {
            let p = try await getItem(pid, b)
            print("PROBE plain message with calendar fields:", p.all("ResponseCode").map { $0.stringValue ?? "" })
        }

        // One day of the calendar around the invite.
        let start = item.text("Start") ?? ISO8601DateFormatter().string(from: .now)
        let day = String(start.prefix(10))
        let cal = try await b.client.call("""
            <m:FindItem Traversal="Shallow"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
            <t:FieldURI FieldURI="calendar:Start"/><t:FieldURI FieldURI="calendar:End"/><t:FieldURI FieldURI="item:Subject"/>\
            <t:FieldURI FieldURI="calendar:IsAllDayEvent"/><t:FieldURI FieldURI="calendar:LegacyFreeBusyStatus"/>\
            </t:AdditionalProperties></m:ItemShape>\
            <m:CalendarView StartDate="\(day)T00:00:00Z" EndDate="\(day)T23:59:59Z"/>\
            <m:ParentFolderIds><t:DistinguishedFolderId Id="calendar"/></m:ParentFolderIds></m:FindItem>
            """, strict: false)
        let events = cal.first("Items")?.elementChildren ?? []
        print("PROBE calendar day: \(cal.all("ResponseCode").map { $0.stringValue ?? "" }), events: \(events.count),",
              "fields:", Set(events.flatMap { $0.elementChildren.compactMap(\.localName) }).sorted(),
              "busy:", Set(events.compactMap { $0.text("LegacyFreeBusyStatus") }).sorted())
    }
}
