---
title: 'A mail with <meta http-equiv="refresh" content="0;url=about:blank"> (or a link to about:blank) replaces its own body with an empty page'
priority: P3
area: HTMLPage
status: open
found: 2026-11-13
---
## Summary
The navigation delegate allows every navigation whose URL is exactly `about:blank`. A mail's meta refresh to `about:blank` therefore navigates the body's web view away: the message text disappears and the user sees an empty body (only the attachments). A clicked `<a href="about:blank">` does the same.

## Repro
Real app, documented snapshot hook (sample data, nothing read or written on disk):
```sh
printf '%s' '<p style="font-size:20px">Your invoice 4711 is attached. Total due: 120,00 EUR by 30 Nov.</p><p>Kind regards, Billing</p><meta http-equiv="refresh" content="0;url=about:blank">' > refresh.html
printf '%s' '<p style="font-size:20px">Your invoice 4711 is attached. Total due: 120,00 EUR by 30 Nov.</p><p>Kind regards, Billing</p>' > control.html
./run.sh build
MAIL_SAMPLE_DATA=1 MAIL_SNAPSHOT=$PWD/tmp/refresh.png MAIL_SNAPSHOT_HTML=refresh.html .build/debug/MailReplica
MAIL_SAMPLE_DATA=1 MAIL_SNAPSHOT=$PWD/tmp/control.png MAIL_SNAPSHOT_HTML=control.html .build/debug/MailReplica
```
## Expected vs actual
control.png: the invoice text and "Kind regards, Billing" are shown above the attachment. refresh.png: the body area is empty; only the attachment (Q4-Roadmap.pdf) is shown. Screenshots: r3snap/refresh.png, r3snap/control.png.
## Why expected
rendering.md: "every other navigation is cancelled" – the intent is that mail can't navigate its own view (meta refresh is listed as cancelled in the code comment). README: the message is "shown as the sender laid it out".
## Likely cause
`Sources/MailReplica/HTMLBodyView.swift:76`: `about:blank` is allowed for any navigation, not only the initial `loadHTMLString` load. Allow it only for that first load (e.g. `navigationType == .other` and no navigation done yet / track the WKNavigation returned by `loadHTMLString`), or check `action.targetFrame?.isMainFrame` plus a flag.

## Verification note
This one is proven by the app itself, not by a unit test. `MAIL_SNAPSHOT_HTML` was used with sample data: the snapshot with the meta refresh shows an empty body, while the control shows the message.
