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

- The message's HTML is wrapped, not parsed: the HTML 4.01 Transitional doctype with its URL (`HTMLPage.doctype`, almost-standards
  mode: tables inherit the 14 px, a picture alone in a table cell gets no gap under it; the mail's own doctype lands
  inside the page and is ignored), a `Content-Security-Policy` meta tag, `color-scheme: light`, a
  style block (`14px Helvetica`, margins 18/20/22 px, word breaking; no background or text colour, as in Mail's
  MUIWebDocument.css, so the mail's `<body bgcolor text>` apply, and otherwise the light colour scheme gives a white
  page with black text), then
  `<div id="mail-replica-body">` around the HTML.
- CSP without remote content: `default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:` (fonts
  embedded in the mail load). With remote content:
  `default-src 'none'; style-src * 'unsafe-inline'; img-src * data:; font-src * data:`. No scripts, frames or fetches in either case.
- Without remote content, every `<link` tag start of the mail (any case, matched by Unicode scalar) is renamed `<x-blocked-link`
  (`HTMLPage.withoutLinks`): WebKit opens connections for resource hints (`preconnect`, …) regardless of the CSP.
  Leading whitespace in quoted `src`/`srcset` values is removed (`HTMLPage.withEmbeddedSourcesTrimmed`), so the
  rule below sees a `data:` picture as one.
- From MUIWebDocument.css: `* { -webkit-user-modify: initial !important }` (a mail with `contenteditable` can't be
  edited); `ul.Apple-dash-list` without bullets, each item with an en dash before it; nested `<ol>` numbered
  decimal → lower-alpha → lower-roman, repeating, dashes from the 10th level. The `<ol>` rules have zero specificity
  (`:where`) and skip an `<ol type>`, so the mail's own list styles win.
- Apple Mail quotes, `blockquote[type=cite]`, as in Mail's MUIWebDocument.css: no margin, 8 px left padding, a 2 px solid
  bar on the left; bar and text in `HTMLPage.quoteColours` (levels 1–3, deeper levels keep level 3).
- `img.Apple-web-attachment` (pictures placed by Apple Mail) gets `vertical-align: top` and at most the page width, as in
  MUIWebDocument.css; so does `video.Apple-web-attachment`. Other images keep their size.
- `img[src^="cid:" i]` is hidden (any case). Without remote content, every image whose `src` doesn't
  start with `data:` is `visibility: hidden` (keeps its space, as Mail does), except an image whose `srcset` starts
  with `data:` and an image in a `<picture>` with a `<source srcset="data:…">`.
- The web view (`MailWebView`): content JavaScript off, non-persistent data store, light appearance. It reloads only
  when the HTML, the remote decision or the set of inline image IDs changes. Its height is measured by an app script
  (`HTMLPage.measureScript`: the bottom of the root element's box, which holds the body with its margins, so markup
  that closes our wrapper early can't cut the mail off; plus `scrollY`, so a page scrolled at load, e.g. to an
  `autofocus` field, is measured from its top; at least the body's top plus its `scrollHeight` and bottom margin,
  which counts `position: absolute` content inside a positioned element (absolute content with no positioned
  ancestor isn't counted). Before measuring, the script sets every element of the mail whose computed `position` is
  `fixed` to `position: static !important`: the view is as tall as the page and never scrolls, so a fixed bar would
  cover the lines under it for good. None of these terms depends on the view's own height, so the view shrinks again when
  the window widens). The page's style forces `html:root { height: auto; min-height: 0 }` (`!important`), so mail
  that makes the root as tall as the view can't keep it from shrinking; percentage heights such as MailChimp's
  `height="100%"` table resolve to auto in almost-standards mode. Viewport units (`vh`, `vw`, …) resolve against the
  window's content size and the view's width (`HTMLPage.pinViewportUnits`, set in `BodyWebView.layout`), not
  against the view, which grows to the page's height after load, on width changes, and whenever the root or the body changes size after load (lazy pictures, an
  opened `<details>`): `HTMLPage.resizeScript`, a `ResizeObserver` in the app's own script world (it runs with content
  JavaScript off), posts `mailReplicaResize`, and the coordinator measures again. It is installed only when viewport
  units can be pinned, so re-measuring can't feed a `100vh` block; vertical scrolling goes to
  the surrounding scroll view, horizontal stays in the page.
- Navigation (`BodyNavigation`): `about:blank` is allowed only for the app's own load, from `willLoad()` (called before
  each `loadHTMLString`) until that load commits; a meta refresh or link to `about:blank` afterwards is cancelled, like
  every other navigation. A clicked link opens in the default
  app only for `http`, `https` and `mailto` (`HTMLPage.opensLink`).

## Remote content

- `Message.hasRemoteContent`: the HTML matches (case-insensitive) `src=`, `background=` or `poster=` followed by
  `http(s):`; a `srcset=` value with an `http(s):` candidate anywhere in it; `href=` followed by `http(s):` inside a
  `<link …>` tag (not `<a href>`); `url(` followed by `http(s):`, optionally quoted with `"`, `'` or an entity
  (`&quot;`, `&apos;`, `&#34;`, `&#39;`, `&#x22;`, `&#x27;`); or `@import` followed by `http(s):`, optionally
  quoted the same way. Text that only mentions `@import` doesn't count.
- Allowed when the user clicked Load Remote Content for this message (kept until the view goes away), or when
  `RemoteImages.loadsAutomatically(from:account:)` says so for the Privacy setting:
  - Always: yes. Ask before downloading: no.
  - My organisation (default): the sender address starts with `/o=` and has no `@` (Exchange X.500; `/o=…@domain` is an
    internet address and is judged by its domain), or its domain (after the last
    `@`, lowercased) equals the account address's domain or ends with `.` + that domain.
- If the message has remote content and it isn't allowed: the banner "This message contains remote content." with
  Load Remote Content above the page. When it is allowed, the less strict CSP is used.

## Inline images (`cid:`)

- `HTMLPage.contentIDs(in:)` finds references with the regex `(?<![\w+.-])cid:((?:(?!/>)[^"'\s)<>])+)`
  (case-insensitive; not inside a word such as `acid:rain`; an unquoted value ends before `/>`). Each ID: character
  references decoded (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, numeric), percent-decoded, then `<` and `>` trimmed.
- `MailStore.loadInlineImages` asks the backend for those IDs once per message and keeps them in memory only, for
  the messages of the conversation on screen.
- `document(_:allowRemote:inline:)` replaces each reference with a known image by
  `data:<type>;base64,<data>` (followed by a space when `/>` comes next, so the tag still closes). `<type>` is `HTMLPage.safeType(contentType)`: parameters after `;` dropped, trimmed,
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
