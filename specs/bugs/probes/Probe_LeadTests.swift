import Foundation
import Testing
@testable import MailModel

@MainActor
struct Probe_LeadTests {
    let work = Account(name: "Work", address: "me@work.com")

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
