---
title: 'An invite answered here shows "Please respond" again once Exchange has moved it to Deleted Items'
priority: P3
area: Invite
status: open
found: 2026-11-13
---
## Summary
After Accept/Tentative/Decline (sent), the store puts the invite in Trash with the answer, and sends no move because Exchange moves the meeting request itself. Exchange gives the moved item a new ID: the next Inbox sync deletes the old ID (the local answered copy goes), the Trash sync brings the new ID as a fresh summary, and its body has no answer. ⚠️ Recalled, not checked live: that a sent answer makes Exchange move the request to Deleted Items under a new ID (the store's own comment and README assume the move). The invite in Trash then says "Please respond" and offers Accept/Decline again, as if never answered.

## Repro
Harness (`FlowServer`, `FX`, `store(_:)`, `complete(_:_:)`, `serverMessage`, `waitFor`): top of `specs/bugs/probes/Probe_EWSFlowTests.swift` in the copy (`// file:// fixture (FIFO)`: a named pipe at a `file://` URL serves the scripted responses in order to the real EWSClient; no network, no fake class). The full harness is quoted in R3-EWSFlow-01.

```swift
    /// Accept an invite: it moves to Trash here at once, as README says Exchange will do. Exchange then moves it
    /// to Deleted Items under a new ID: the Inbox sync deletes the old ID, the Trash sync brings the new one. The
    /// answer given here is gone: the invite in Trash says "Please respond" again and offers Accept/Decline.
    // file:// fixture
    @Test func probeAnsweredInviteKeepsItsAnswerAfterExchangeMovesIt() async throws {
        let server = FlowServer([
            FX.resp("CreateItem", FX.ok("CreateItem")),               // AcceptItem
            FX.sync(FX.delete("M"), token: "T1", last: true),         // Inbox
            FX.sync(FX.create(FX.summary("M2", subject: "Sync", read: true, kind: "MeetingRequest")), token: "T1", last: true),  // Trash
            FX.getItem(meetingRequest("M2")),                        // body of the invite in Trash
        ])
        defer { server.stop() }
        let s = store(server)
        complete(s, .inbox); complete(s, .trash)
        let inv = Invite(start: Date(timeIntervalSince1970: 1_795_428_000), end: Date(timeIntervalSince1970: 1_795_431_600),
                         organizer: Contact(name: "Org", email: "org@work.com"), isCancellation: false)
        s.merge([serverMessage("M", subject: "Sync", body: "Let's meet", loaded: true, invite: inv)], account: acct.id, mailbox: .inbox)
        let id = try #require(s.messages.first?.id)
        s.respond(.accept, to: id)
        try await waitFor { s.outbox.isEmpty }
        #expect(s.messages.first?.invite?.response == .accept)
        s.selectedMailbox = .account(acct.id, .trash)
        await s.refresh(history: false)
        let m = try #require(s.messages.first { $0.mailbox == .trash })
        await s.loadBody(m.id)
        let after = try #require(s.message(m.id))
        #expect(after.invite?.response == .accept,
                "invite in Trash: rid \(after.remoteID ?? ""), response \(String(describing: after.invite?.response)), requests \(server.served), status \(String(describing: s.status))")
    }

    func meetingRequest(_ id: String, subject: String = "Sync", start: String = "2026-11-23T10:00:00Z",
                        end: String = "2026-11-23T11:00:00Z", kind: String = "MeetingRequest", extra: String = "") -> String {
        "<t:\(kind)><t:ItemId Id=\"\(id)\" ChangeKey=\"CK\"/><t:Subject>\(subject)</t:Subject>"
            + "<t:Body BodyType=\"Text\">Let's meet</t:Body><t:Attachments/>"
            + "<t:From><t:Mailbox><t:Name>Org</t:Name><t:EmailAddress>org@work.com</t:EmailAddress></t:Mailbox></t:From>"
            + "<t:ToRecipients><t:Mailbox><t:Name>Me</t:Name><t:EmailAddress>me@work.com</t:EmailAddress></t:Mailbox></t:ToRecipients>"
            + "<t:TextBody BodyType=\"Text\">Let's meet</t:TextBody>\(extra)"
            + "<t:Start>\(start)</t:Start><t:End>\(end)</t:End><t:Location>Room 1</t:Location><t:IsAllDayEvent>false</t:IsAllDayEvent>"
            + "<t:Organizer><t:Mailbox><t:Name>Org</t:Name><t:EmailAddress>org@work.com</t:EmailAddress></t:Mailbox></t:Organizer>"
            + "</t:\(kind)>"
    }
```

## Expected vs actual
Expected: the invite in Trash still shows the answer (Accepted).
Actual:
```
Expectation failed: after.invite?.response == .accept
  invite in Trash: rid M2, response nil, requests 4, status nil
```
(Control `controlAnswerWithoutSendingMovesToTrash`: with Do Not Send, the store moves the invite itself, renames it to the new ID, and the answer survives.)

## Why expected
README ✅ invites: "an answered invite moves to Trash right away, as Exchange will do" and "\"Please respond\" until you have answered". The store's own comment (`MailStore.swift:926-927`): "no move request: the server moves it itself" — i.e. it expects the server's move, which always comes with a new ID.

## Likely cause
`MailStore.answer` (`Sources/MailModel/MailStore.swift:928-942`) keeps the answer only in the local message under the old remote ID; `merge` (:585-596) removes it when the Inbox reports that ID deleted, and the Trash copy is a new message. `EWSBackend.bodyRequest`/`parseInvite` (`Sources/EWS/EWSBackend.swift:73-82, 200-209`) don't read the server's answer (e.g. `calendar:MyResponseType`), so loading the body can't restore it.
