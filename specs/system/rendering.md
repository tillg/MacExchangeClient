---
title: "Rendering"
created: 2026-11-12
edited: 2026-11-13
---

# Rendering

How message text is shown, and how the text of sent mail is built. Code: `Sources/MailModel/HTMLPage.swift`,
`Sources/MailModel/Models.swift` (`Message.preview`, `hasRemoteContent`, `Draft.html`),
`Sources/MailReplica/HTMLBodyView.swift`, `MessageDetailView.swift`. Where bodies and images come from:
[ews.md](ews.md).

## Which body is shown (`MessageContent`)

1. When a message is shown, its task loads the body (if `needsBody`), then its inline images, then marks it loaded,
   then fetches the calendar day for an invite.
2. Until then the view waits, with an empty area and a spinner after 0.4 s, if the body is needed, or if the HTML
   refers to `cid:` images and none are in memory yet. So the formatted body appears once, together with its pictures.
3. Body loaded and `html` set: the HTML page below, with the remote content banner if needed.
4. Otherwise plain text: the body if loaded, else `preview`, at 13 pt, selectable.
5. Attachments follow the body; on an HTML message they sit on a white background in light appearance.

## The HTML page (`HTMLPage.document`)

- The message's HTML is wrapped, not parsed: a `Content-Security-Policy` meta tag first, `color-scheme: light`, a
  style block (white background, `14px Helvetica`, margins 18/20/22 px, word breaking), then
  `<div id="mail-replica-body">` around the HTML.
- CSP without remote content: `default-src 'none'; style-src 'unsafe-inline'; img-src data:`. With remote content:
  `default-src 'none'; style-src * 'unsafe-inline'; img-src * data:; font-src * data:`. No scripts, frames or fetches in either case.
- Without remote content, every `<link` tag start of the mail (any case) is renamed `<x-blocked-link`
  (`HTMLPage.withoutLinks`): WebKit opens connections for resource hints (`preconnect`, …) regardless of the CSP.
- `img[src^="cid:"]` is hidden (only exact lowercase `cid:`). Without remote content, every image whose `src` doesn't
  start with `data:` is `visibility: hidden` (keeps its space, as Mail does).
- The web view (`MailWebView`): content JavaScript off, non-persistent data store, light appearance. It reloads only
  when the HTML, the remote decision or the set of inline image IDs changes. Its height is measured by an app script
  (bottom of the body div plus the body's bottom margin) after load and on width changes; vertical scrolling goes to
  the surrounding scroll view, horizontal stays in the page.
- Navigation: `about:blank` is allowed; every other navigation is cancelled. A clicked link opens in the default
  app only for `http`, `https` and `mailto` (`HTMLPage.opensLink`).

## Remote content

- `Message.hasRemoteContent`: the HTML matches (case-insensitive) `src=`, `background=` or `poster=` followed by
  `http(s):`; a `srcset=` value with an `http(s):` candidate anywhere in it; `href=` followed by `http(s):` inside a
  `<link …>` tag (not `<a href>`); `url(` followed by `http(s):`, optionally quoted with `"`, `'` or an entity
  (`&quot;`, `&apos;`, `&#34;`, `&#39;`, `&#x22;`, `&#x27;`); or the text `@import` anywhere.
- Allowed when the user clicked Load Remote Content for this message (kept until the view goes away), or when
  `RemoteImages.loadsAutomatically(from:account:)` says so for the Privacy setting:
  - Always: yes. Ask before downloading: no.
  - My organisation (default): the sender address starts with `/o=` (Exchange X.500), or its domain (after the last
    `@`, lowercased) equals the account address's domain or ends with `.` + that domain.
- If the message has remote content and it isn't allowed: the banner "This message contains remote content." with
  Load Remote Content above the page. When it is allowed, the less strict CSP is used.

## Inline images (`cid:`)

- `HTMLPage.contentIDs(in:)` finds references with the regex `cid:([^"'\s)>]+)` (case-insensitive, anywhere in the
  text). Each ID: `&lt;`/`&gt;` decoded, percent-decoded, then `<` and `>` trimmed.
- `MailStore.loadInlineImages` asks the backend for those IDs once per message and keeps them in memory only, for
  the messages of the conversation on screen.
- `document(_:allowRemote:inline:)` replaces each reference with a known image by
  `data:<type>;base64,<data>`. `<type>` is `HTMLPage.safeType(contentType)`: parameters after `;` dropped, trimmed,
  lowercased, and kept only if it is `token/token` (`a-z 0-9 ! # $ & ^ _ . + -`), else `application/octet-stream`. Unknown references stay `cid:` and
  are hidden by the style above.

## List preview

`Message.preview`: the server preview while the body isn't loaded; otherwise the body split into lines (any newline),
lines starting with `>` dropped, joined with spaces and trimmed of spaces. It is computed on every access, but only
over the first 10,000 characters of the body, and returns at most 500 characters. The row shows two lines of it.

## HTML of sent mail

Sent mail is plain text (`Draft.text`) unless a JPEG, PNG or GIF is placed in the text (`placedPictures`). Then
`Draft.html(contentID:)` builds the body:

- `<html><head>` with a UTF-8 meta, `<body style="overflow-wrap: break-word; -webkit-nbsp-mode: space;
  line-break: after-white-space;">`.
- `body` is split on every line ending (`isNewline`: `\r\n`, `\n`, `\r`, U+2028, …); each line becomes `<div>…</div>`, an empty line `<div><br></div>`, lines joined by
  `\n`. Text is escaped (`&`, `<`, `>`, `"`). Between marks, a space that follows a space or starts the
  line becomes `&nbsp;` (so runs alternate ` &nbsp;`), and a tab becomes
  `<span class="Apple-tab-span" style="white-space:pre">⇥</span>`, as Mail writes them.
- At a file mark with a content ID: `<img src="cid:<id>" alt="<escaped file name>">`; marks of other files are left
  out (those files go as ordinary attachments).

## Other text

- Avatars show `Contact.initials`; there are no contact photos.
- List and header dates are formatted in local time ([functional.md](functional.md#message-list)).
- Invites show times in local time; the day column spans 8–18 h, widened to fit the invite and the day's events.
