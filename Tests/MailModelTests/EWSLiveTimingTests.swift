import Foundation
import Testing
@testable import EWS
@testable import MailModel

/// Read-only timings against the real server, to size batches. Prints counts and seconds only, never mail
/// content. Runs only with `EWS_TIMING=1` in addition to the settings of `EWSLiveTests`.
struct EWSLiveTimingTests {
    static let backend = ProcessInfo.processInfo.environment["EWS_TIMING"] == "1" ? EWSLiveTests.backend : nil

    func time<T>(_ label: String, _ f: () async throws -> T) async throws -> T {
        let start = Date()
        let r = try await f()
        print(String(format: "TIMING %-34@ %6.2fs", label as NSString, Date().timeIntervalSince(start)))
        return r
    }

    @Test(.enabled(if: EWSLiveTimingTests.backend != nil)) func measure() async throws {
        let b = try #require(Self.backend)
        let folders = try await time("folders()") { try await b.folders() }
        for f in folders {
            let doc = try await b.client.call("""
                <m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\
                <t:FieldURI FieldURI="folder:TotalCount"/><t:FieldURI FieldURI="folder:UnreadCount"/>\
                </t:AdditionalProperties></m:FolderShape><m:FolderIds><t:FolderId Id="\(xmlEscape(f.id))"/></m:FolderIds></m:GetFolder>
                """)
            print("COUNT \(f.role.rawValue): total=\(doc.text("TotalCount") ?? "?") unread=\(doc.text("UnreadCount") ?? "?")")
        }
        let inbox = try #require(folders.first { $0.role == .inbox })
        _ = try await time("newest 1 (warm connection)") { try await b.newest(in: inbox, limit: 1) }
        _ = try await time("newest 50") { try await b.newest(in: inbox, limit: 50) }
        let top = try await time("newest 200") { try await b.newest(in: inbox, limit: 200) }
        let page = try await time("sync from scratch, 1 page (512)") { try await b.sync(inbox, token: nil) }
        print("PAGE upserts=\(page.upserts.count) more=\(page.more)")
        var token = page.token
        var pages = 1
        let full = Date()
        var more = page.more
        while more && pages < 5 {
            let r = try await b.sync(inbox, token: token)
            token = r.token; more = r.more; pages += 1
        }
        print(String(format: "TIMING %d sync pages total              %6.2fs (more=%@)", pages, Date().timeIntervalSince(full), more ? "true" : "false"))
        _ = try await time("delta check, token from page 1") { try await b.sync(inbox, token: page.token) }
        let ids = top.prefix(10).compactMap(\.remoteID)
        _ = try await time("body x1") { try await b.body(remoteID: ids[0]) }
        _ = try await time("body x10 sequential") { for id in ids { _ = try await b.body(remoteID: id) } }
    }
}
