import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_LeadTests {
    let work = Account(name: "Work", address: "me@work.com")

    func inviteStore() -> (MailStore, Message.ID) {
        var m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Org", email: "org@x.com"),
                        to: [Contact(name: "Me", email: work.address)], subject: "Sync", body: "",
                        date: Date(timeIntervalSince1970: 1_000_000))
        m.remoteID = "M"; m.bodyLoaded = false
        m.invite = Invite(start: Date(timeIntervalSince1970: 2_000_000), end: Date(timeIntervalSince1970: 2_001_800))
        let s = MailStore(accounts: [work], messages: [])
        s.apply(SyncResult(upserts: [m], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        return (s, s.messages.first { $0.remoteID == "M" }!.id)
    }

    @Test func probe_proposalWithStartButNoEndIsRefused() {
        let (s, id) = inviteStore()
        s.respond(InviteReply(response: .tentative, proposedStart: Date(timeIntervalSince1970: 2_100_000)), to: id)
        #expect(s.outbox.isEmpty, "queued: \(s.outbox.map(\.change))")
    }

    @Test func probe_proposalWithEndButNoStartIsRefused() {
        let (s, id) = inviteStore()
        s.respond(InviteReply(response: .tentative, proposedEnd: Date(timeIntervalSince1970: 2_100_000)), to: id)
        #expect(s.outbox.isEmpty, "queued: \(s.outbox.map(\.change))")
    }

    @Test func probe_replyAllSkipsRecipientsWithoutAddress() {
        let m = Message(accountID: work.id, mailbox: .inbox, from: Contact(name: "Ann", email: "ann@x.com"),
                        to: [Contact(name: "Me", email: work.address), Contact(name: "Undisclosed recipients", email: "")],
                        subject: "Hi", body: "b", date: Date(timeIntervalSince1970: 1_000_000))
        let s = MailStore(accounts: [work], messages: [m])
        let d = s.draft(.replyAll, to: m.id)
        #expect(d.to == "ann@x.com", "to: \(d.to.debugDescription)")
    }
}

@MainActor
struct Probe_LeadAttachTests {
    @Test func probe_symlinkToFolderAttachesAsZip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LeadLink-\(UUID())")
        let folder = dir.appendingPathComponent("Photos"), link = dir.appendingPathComponent("Photos alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let s = MailStore(accounts: [Account(name: "W", address: "me@w.com")], messages: [])
        let files = s.files([link])
        #expect(files.count == 1 && files.first?.contentType == "application/zip", "files: \(files.map(\.name)) status: \(s.status ?? "nil")")
    }
}
