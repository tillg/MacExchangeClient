import Foundation
import Network
import Testing
import WebKit
@testable import EWS
@testable import MailModel

// Round-5 hunter D: rendering, compose and invites at model level. Every test here fails until its bug
// (specs/bugs/drafts/R5D-NN-*.md) is fixed.

@MainActor
struct Probe_R5D_Compose {
    let work = Account(name: "Work", address: "me@work.com")

    func msg(subject: String = "Hi", from: Contact = Contact(name: "Ann", email: "ann@x.com"), to: [Contact]? = nil,
             body: String = "Body", attachments: [MailModel.Attachment] = []) -> Message {
        Message(accountID: work.id, from: from, to: to ?? [Contact(name: "Me", email: work.address)],
                subject: subject, body: body, date: Date(timeIntervalSince1970: 1_000_000), attachments: attachments)
    }

    func store(_ m: [Message]) -> MailStore { MailStore(accounts: [work], messages: m) }

    /// R5D-02: Reply All to a note only to myself goes to me, as Reply does (d-bug-029 follow-up), not to nobody.
    @Test func replyAllToNoteToSelfGoesToMe() {
        let me = Contact(name: "Me", email: "me@work.com")
        let m = msg(from: me, to: [me])
        let s = store([m])
        #expect(s.draft(.reply, to: m.id).to == "me@work.com")
        let to = s.draft(.replyAll, to: m.id).to
        #expect(to == "me@work.com", "Reply All To is \(to.debugDescription)")
    }

    /// R5D-11: RFC 5322 §3.4 group syntax and a trailing comment are parsed to the real addresses.
    @Test func recipientGroupAndCommentSyntax() {
        let group = Contact.parseList("Team: a@x.com, b@y.com;").map(\.email)
        #expect(group == ["a@x.com", "b@y.com"], "\(group)")
        let comment = Contact.parseList("a@x.com (Ann Smith)").map(\.email)
        #expect(comment == ["a@x.com"], "\(comment)")
    }

    /// R5D-12: a placed picture's Content-ID is a msg-id (`id-left "@" id-right`, RFC 2045 §7 / RFC 5322 §3.6.4).
    @Test func placedPictureContentIDIsAMsgID() {
        var d = Draft(accountID: work.id, body: String(Draft.fileMark))
        d.attachments = [DraftAttachment(name: "p.png", contentType: "image/png", data: Data([1]))]
        let ids = EWSBackend.contentIDs(d)
        #expect(!ids.isEmpty && ids.values.allSatisfy { $0.contains("@") }, "\(ids)")
    }
}

@MainActor
struct Probe_R5D_Attachments {
    /// R5D-10: an attachment named ".invoice.pdf" is not saved as a hidden file.
    @Test func savedAttachmentIsNotHidden() async throws {
        let m = Message(accountID: UUID(), from: Contact(name: "a", email: "a@x"), to: [], subject: "s", body: "",
                        date: .now, attachments: [MailModel.Attachment(name: ".invoice.pdf", size: 1)])
        let s = MailStore(accounts: [], messages: [m])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        s.downloadsFolder = tmp.appendingPathComponent("dl")
        s.setAttachmentData([Data([1])], for: m.id)
        let saved = try #require(await s.saveAttachment(0, of: m.id, to: tmp.appendingPathComponent("Downloads")))
        let hidden = try saved.resourceValues(forKeys: [.isHiddenKey]).isHidden
        #expect(hidden == false, "saved as \(saved.lastPathComponent), hidden in the Finder")
    }
}

@MainActor
struct Probe_R5D_RemoteContent {
    func html(_ h: String) -> Message {
        var m = Message(accountID: UUID(), from: Contact(name: "a", email: "a@x"), to: [], subject: "", body: "", date: .now)
        m.html = h
        return m
    }

}

/// Real WKWebView, configured as MailWebView, with a listener on 127.0.0.1 standing in for the sender's server.
@MainActor
@Suite(.serialized)
struct Probe_R5D_Render {
    static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    func show(_ page: String) async -> (WKWebView, NavigationDelegate) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 1), configuration: config)
        let delegate = NavigationDelegate()
        v.navigationDelegate = delegate
        delegate.navigation.willLoad()
        v.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(30)
        try? await Task.sleep(for: .milliseconds(200))
        while v.isLoading && Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return (v, delegate)
    }

    /// Shows `vector` with remote content allowed; returns whether the sender's server was contacted, and
    /// whether `hasRemoteContent` (which decides on the banner) sees it.
    func loadsAndIsDetected(_ vector: String) async throws -> (loaded: Bool, detected: Bool) {
        let server = try LoopbackListener()
        let mail = "<p>Hello</p>" + vector.replacingOccurrences(of: "BASE", with: "http://127.0.0.1:\(server.port)")
            .replacingOccurrences(of: "PORT", with: "\(server.port)")
        let shown = await show(HTMLPage.document(mail, allowRemote: true))
        try? await Task.sleep(for: .milliseconds(1500))
        var m = Message(accountID: UUID(), from: Contact(name: "a", email: "a@x"), to: [], subject: "", body: "", date: .now)
        m.html = mail
        withExtendedLifetime(shown) {}
        return (server.connections > 0, m.hasRemoteContent)
    }

    /// R5D-07: a video counts as remote content (banner), but Load Remote Content never loads it: the policy has
    /// no media-src.
    @Test func videoLoadsOnceRemoteContentIsAllowed() async throws {
        let r = try await loadsAndIsDetected(#"<video src="BASE/video.mp4" preload=auto></video>"#)
        #expect(!r.detected || r.loaded, "counted as remote content (banner), but still blocked after Load Remote Content")
    }

    /// R5D-13: with remote content blocked, a picture whose web source wins (`<picture><source srcset>`) or an
    /// `<input type=image>` must not be drawn as WebKit's outlined broken-image box: Mail shows nothing but keeps the space.
    @Test func blockedPicturesAreNotBrokenBoxes() async throws {
        let mail = #"<picture><source srcset="https://t.example/a.png"><img id=p alt="Logo" width=50 height=50 src="data:image/png;base64,\#(Self.png)"></picture>"#
            + #"<input id=i type=image alt="Buy now" width=50 height=50 src="https://t.example/b.png">"#
        let shown = await show(HTMLPage.document(mail, allowRemote: false))
        try? await Task.sleep(for: .milliseconds(500))
        let js = "['p','i'].map(id => { const e = document.getElementById(id); return id + ':' + getComputedStyle(e).visibility + ':' + (e.naturalWidth ?? '-') + ':' + (e.currentSrc || e.src) }).join(' | ')"
        let r = (try? await shown.0.evaluateJavaScript(js)) as? String ?? "nil"
        #expect(!r.contains("p:visible:0"), "broken <picture> drawn: \(r)")
        #expect(!r.contains("i:visible"), "broken <input type=image> drawn: \(r)")
    }
}

/// An EWS endpoint on 127.0.0.1 that records each request and answers every one with `answer`.
final class R5DRecordingServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _bodies: [String] = []
    var bodies: [String] { lock.withLock { _bodies } }
    private(set) var port: UInt16 = 0
    var url: URL { URL(string: "http://127.0.0.1:\(port)/EWS/Exchange.asmx")! }

    init(answer: String) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { s in if case .ready = s { ready.signal() } }
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            c.start(queue: .global())
            var buffer = Data()
            func read() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                    if let data { buffer += data }
                    let text = String(decoding: buffer, as: UTF8.self)
                    if text.contains("Envelope>") && text.hasSuffix(">") || done {
                        self.lock.withLock { self._bodies.append(text) }
                        let body = Array(answer.utf8)
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                        c.send(content: Data(head.utf8) + Data(body), completion: .contentProcessed { _ in c.cancel() })
                    } else { read() }
                }
            }
            read()
        }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    deinit { listener.cancel() }
}

@MainActor
@Suite(.serialized)
struct Probe_R5D_Invites {
    let acct = Account(name: "Exchange", address: "me@work.com")
}
