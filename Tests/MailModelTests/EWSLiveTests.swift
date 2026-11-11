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
}
