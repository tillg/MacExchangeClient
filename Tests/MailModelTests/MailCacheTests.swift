import Foundation
import Testing
@testable import MailModel

/// The on-disk cache, with synthetic messages in a temporary folder.
@MainActor
struct MailCacheTests {
    let work = Account(name: "Work", address: "me@work.com")
    let home = Account(name: "iCloud", address: "me@icloud.com")

    func remote(_ rid: String) -> Message {
        Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "S \(rid)",
                body: "", date: Date(timeIntervalSince1970: 1_000), remoteID: rid, serverPreview: "P", bodyLoaded: false)
    }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MailCacheTests-\(UUID())/cache.json")
    }

    /// Written by the version before folders of the user's own existed: the format must still load.
    @Test func cacheFromBeforeFoldersStillLoads() throws {
        let json = #"{"accounts":["00000000-0000-0000-0000-000000000001",{"complete":["inbox"],"messages":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":[],"body":"","bodyLoaded":false,"category":"primary","cc":[],"date":-978307200,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":false,"id":"00000000-0000-0000-0000-000000000002","isRead":true,"isVIP":false,"mailbox":"archive","remoteID":"R1","subject":"S","to":[]}],"outbox":[{"account":"00000000-0000-0000-0000-000000000001","change":{"move":{"_0":["R1"],"to":"archive"}},"id":"00000000-0000-0000-0000-000000000003","previous":[{"accountID":"00000000-0000-0000-0000-000000000001","attachments":[],"body":"","bodyLoaded":false,"category":"primary","cc":[],"date":-978307200,"from":{"email":"ann@x.com","name":"Ann"},"hasAttachments":false,"id":"00000000-0000-0000-0000-000000000002","isRead":true,"isVIP":false,"mailbox":"archive","remoteID":"R1","subject":"S","to":[]}]}],"syncTokens":["inbox","T1"]}]}"#
        let c = try JSONDecoder().decode(MailCache.self, from: Data(json.utf8))
        let state = try #require(c.accounts[UUID(uuidString: "00000000-0000-0000-0000-000000000001")!])
        #expect(state.syncTokens == [.inbox: "T1"])
        #expect(state.complete == [.inbox])
        #expect(state.messages.map(\.mailbox) == [.archive])
        #expect(state.outbox.map(\.change) == [.move(["R1"], to: .archive)])
        #expect(state.folders == nil)
    }

    @Test func serverMailTokensAndOutboxSurviveARestart() throws {
        let s = MailStore(accounts: [work, home], messages: [
            Message(accountID: home.id, from: Contact(name: "B", email: "b@x.com"), to: [], subject: "Local", body: "x", date: .now),
        ])
        s.apply(SyncResult(upserts: [remote("A"), remote("B")], deletedRemoteIDs: [], token: "in1", more: false),
                account: work.id, mailbox: .inbox)
        s.apply(SyncResult(upserts: [], deletedRemoteIDs: [], token: "sent1", more: false), account: work.id, mailbox: .sent)
        let a = s.messages.first { $0.remoteID == "A" }!
        s.setBody(MessageBody(text: "Full", attachments: ["f.pdf"]), for: a.id)
        s.setFlag(.orange, for: [a.id])

        let url = tempURL()
        try s.cache().save(to: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fresh = MailStore(accounts: [work], messages: [])
        fresh.restore(try #require(MailCache.load(from: url)))
        #expect(fresh.messages.count == 2)
        let a2 = try #require(fresh.message(a.id))
        #expect(a2.body == "Full" && a2.bodyLoaded && a2.attachments == ["f.pdf"])
        #expect(a2.flag == .orange)
        #expect(fresh.syncToken(work.id, .inbox) == "in1")
        #expect(fresh.syncToken(work.id, .sent) == "sent1")
        #expect(fresh.isComplete(work.id, .inbox))
        #expect(fresh.outbox.map(\.change) == [.setFlagged(["A"], true)])
        #expect(fresh.outbox.map(\.id) == s.outbox.map(\.id))
    }

    @Test func cacheSkipsLocalAccountsAndUnknownAccountsAreIgnored() throws {
        let s = MailStore(accounts: [work, home], messages: [
            Message(accountID: home.id, from: Contact(name: "B", email: "b@x.com"), to: [], subject: "Local", body: "x", date: .now),
        ])
        s.apply(SyncResult(upserts: [remote("A")], deletedRemoteIDs: [], token: "t", more: false), account: work.id, mailbox: .inbox)
        let c = s.cache()
        #expect(Set(c.accounts.keys) == [work.id])

        let other = MailStore(accounts: [home], messages: [])
        other.restore(c)
        #expect(other.messages.isEmpty)
        #expect(other.syncToken(work.id, .inbox) == nil)
    }

    @Test func cacheFileIsPrivate() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try MailCache(accounts: [:]).save(to: url)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(MailCache.load(from: url.deletingLastPathComponent().appendingPathComponent("missing.json")) == nil)
    }

    @Test func cacheWithoutHTMLFieldsStillLoads() throws {
        let m = Message(accountID: work.id, from: Contact(name: "Ann", email: "ann@x.com"), to: [], subject: "S",
                        body: "Old", date: Date(timeIntervalSince1970: 1_000), remoteID: "A")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        json["html"] = nil; json["htmlChecked"] = nil
        let old = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.body == "Old" && old.html == nil)
        #expect(old.needsBody)
    }
}
