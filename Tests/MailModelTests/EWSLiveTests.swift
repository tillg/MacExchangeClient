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
}
