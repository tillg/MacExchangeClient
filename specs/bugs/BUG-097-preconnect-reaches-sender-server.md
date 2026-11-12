---
title: '<link rel="preconnect"> in a blocked mail opens a connection to the sender''s server, so opening the mail is reported although remote content is blocked'
priority: P2
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
With remote content blocked (the default for outside senders), a mail containing `<link rel="preconnect" href="https://tracker.example/…">` still makes WebKit open a TCP connection (and DNS lookup) to that host when the message is shown. The CSP doesn't cover preconnect, so the sender learns the mail was opened, when and from which IP – exactly what the Load Remote Content banner promises to prevent.

## Repro
Harness: `RPage` (real WKWebView configured exactly like `MailWebView`: content JS off, non-persistent store, aqua; loads at the view width and 1 pt height as HTMLBodyView starts; `measure()` runs the app's measuring script verbatim; `settleLikeTheApp()` measures and sets the frame to that height) and `LoopbackRecorder` (127.0.0.1-only NWListener) — both at the top of COPY/specs/bugs/probes/Probe_RenderTests.swift. Run the WebKit suite alone: `--filter Probe_RenderTests`.
```swift
@Test(arguments: leakVectors)   // 12 vectors: preconnect, dns-prefetch, prefetch, preload, icon, stylesheet, @import, img, video, iframe, a, form
func blockedVectorReachesNothing(_ vector: String) async throws {
    let rec = try LoopbackRecorder()
    let mail = "<p>Hello</p>" + vector.replacingOccurrences(of: "BASE", with: "http://127.0.0.1:\(rec.port)")
    _ = await RPage(HTMLPage.document(mail, allowRemote: false))
    try? await Task.sleep(for: .milliseconds(1200))
    #expect(rec.connections == 0, "\(vector): connections \(rec.connections), requests \(rec.requests)")
}
```
## Expected vs actual
Only the preconnect vector fails (all 11 others make no connection):
```
Test blockedVectorReachesNothing(_:) recorded an issue with 1 argument vector → "<link rel="preconnect" href="BASE/preconnect">"
  <link rel="preconnect" href="BASE/preconnect">: connections 1, requests []
```
(The connection is opened but no HTTP request follows – a real tracker only needs the TCP/TLS handshake and the DNS query for a per-recipient host name.) `<link rel="dns-prefetch">` could not be observed with a loopback IP; it likely leaks the DNS lookup the same way.
## Why expected
README: "Other mail shows Load Remote Content first, so opening it doesn't tell the sender." rendering.md: "No scripts, frames or fetches in either case."
## Likely cause
`Sources/MailModel/HTMLPage.swift:15-17`: the protection relies only on the CSP; WebKit doesn't apply CSP to `preconnect`/`dns-prefetch` resource hints. Strip `<link rel=preconnect|dns-prefetch|…>` from the mail, or disable those hints in the web view's preferences, when remote content isn't allowed (`HTMLBodyView.swift` config).
