import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Read-only checks against a real Exchange server. They run only when `EWS_USER` (DOMAIN\user) and
/// `EWS_SERVER` are set and the Keychain holds the password (service `MailReplica-EWS`).
/// They assert on structure only and never print mail content.
struct EWSLiveTests {
    static let env = ProcessInfo.processInfo.environment
    static let account: ExchangeAccount? = {
        guard let user = env["EWS_USER"], let server = env["EWS_SERVER"] else { return nil }
        return ExchangeAccount(email: "", username: user, server: server)
    }()
    static let backend = account?.backend()

    @Test(.enabled(if: EWSLiveTests.backend != nil)) func readsFoldersListsSyncsAndLoadsABody() async throws {
        let b = try #require(Self.backend)
        let folders = try await b.folders()
        let inbox = try #require(folders.first { $0.role == .inbox })
        #expect(folders.contains { $0.role == .sent })
        #expect(folders.contains { $0.role == .trash })

        let newest = try await b.newest(in: inbox, limit: 5)
        #expect(!newest.isEmpty)
        #expect(newest.count <= 5)
        #expect(newest.allSatisfy { $0.remoteID != nil && !$0.bodyLoaded })
        #expect(newest.map(\.date) == newest.map(\.date).sorted(by: >))

        let page = try await b.sync(inbox, token: nil)
        #expect(!page.token.isEmpty)
        #expect(!page.upserts.isEmpty)
        let next = try await b.sync(inbox, token: page.token)
        #expect(!next.token.isEmpty)

        let body = try await b.body(remoteID: try #require(newest[0].remoteID))
        #expect(body.from != nil)
        #expect(body.from?.email.contains("@") == true || body.from?.email.isEmpty == false)
    }

    /// The store's quick check on the real server: Inbox titles within seconds, no history sync.
    @MainActor @Test(.enabled(if: EWSLiveTests.backend != nil)) func quickCheckFillsTheInboxFast() async throws {
        let store = MailStore(accounts: [], messages: [])
        let acct = Account(name: "Exchange", address: "")
        store.add(acct, backend: try #require(Self.backend))
        let start = Date()
        await store.refresh(history: false)
        let took = Date().timeIntervalSince(start)
        print(String(format: "TIMING quick check %.2fs, %d inbox messages", took, store.count(.account(acct.id, .inbox))))
        #expect(store.status == nil)
        #expect(store.count(.account(acct.id, .inbox)) == MailStore.firstScreen)
        #expect(store.progress == nil)
        #expect(took < 5)
    }

    /// The folder tree leaves out the standard folders by ID, so the IDs FindFolder returns must match
    /// GetFolder's. Otherwise the Inbox would show up again as a folder of its own. Prints counts only.
    @Test(.enabled(if: EWSLiveTests.backend != nil)) func folderTreeMatchesTheStandardFolders() async throws {
        let b = try #require(Self.backend)
        let folders = try await b.folders()
        let standard = folders.filter { $0.role.isStandard }, own = folders.filter { !$0.role.isStandard }
        let deep = try await b.client.call("""
            <m:FindFolder Traversal="Deep"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape>\
            <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds></m:FindFolder>
            """)
        let ids = Set(deep.all("FolderId").compactMap { $0.attr("Id") })
        print("FOLDERS standard \(standard.count), own \(own.count), nested \(own.filter { $0.parent != nil }.count), deep \(ids.count)")
        #expect(standard.allSatisfy { ids.contains($0.id) })
        #expect(Set(own.map(\.id)).isDisjoint(with: standard.map(\.id)))
        #expect(own.allSatisfy { !$0.name.isEmpty })
    }

    /// The account's sending limit from MailTips. Prints the limit only.
    @Test(.enabled(if: EWSLiveTests.backend != nil)) func maxMessageSizeFromMailTips() async throws {
        let b = try #require(Self.backend)
        let me = try #require(Self.env["EWS_EMAIL"] ?? ExchangeAccount.saved().first?.email)
        let size = try await b.maxMessageSize(from: me)
        print("MAXSIZE \(size.map(String.init) ?? "none")")
        #expect((size ?? 0) > 1_000_000)
    }

    /// Lists the inbox's newest messages with attachments and fetches each listed attachment's content.
    /// Also counts listed pictures whose content ID the HTML uses (they would show twice). Prints counts only.
    @Test(.enabled(if: EWSLiveTests.backend != nil)) func attachmentsOfRecentMailOpen() async throws {
        let b = try #require(Self.backend)
        let inbox = try #require(try await b.folders().first { $0.role == .inbox })
        let withFiles = try await b.newest(in: inbox, limit: 200).filter(\.hasAttachments).prefix(8)
        var listed = 0, sized = 0, fetched = 0, messages = 0, alsoInHTML = 0
        for m in withFiles {
            let rid = try #require(m.remoteID)
            let doc = try await b.client.call(EWSBackend.bodyRequest(rid))
            let item = try #require(doc.first("Items")?.elementChildren.first)
            let body = EWSBackend.parseBody(item)
            let cids = body.html.map(HTMLPage.contentIDs) ?? []
            for (i, a) in body.attachments.enumerated() {
                listed += 1
                if a.size != nil { sized += 1 }
                if a.contentType == "message/rfc822" { messages += 1 }
                let entry = EWSBackend.listedAttachments(item)[i]
                if a.contentType?.hasPrefix("image/") == true, entry.id != nil,
                   item.child("Attachments")?.elementChildren.contains(where: {
                       $0.child("AttachmentId")?.attr("Id") == entry.id && $0.text("ContentId").map(EWSBackend.contentID).map(cids.contains) == true
                   }) == true { alsoInHTML += 1 }
                if (a.size ?? 0) > 5_000_000 { continue }
                let data = try await b.attachment(remoteID: rid, index: i)
                #expect(!data.isEmpty)
                fetched += 1
            }
        }
        print("ATTACHMENTS messages \(withFiles.count), listed \(listed), sized \(sized), fetched \(fetched), eml \(messages), alsoInHTML \(alsoInHTML)")
        #expect(listed == sized)
    }
}
