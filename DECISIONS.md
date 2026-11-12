---
title: "Decisions"
created: 2026-11-12
edited: 2026-11-13
---

# 2026-11-12 23:16 — Unattended bug-fix run {#run-2026-11-12-2316}

- **Started by:** user, unattended
- **Task, as given:** > commit & push what we have incl all the bug reports. Then fix the bugs that u know how to fix w/o guidance, starting with the high prio ones. After every fix: test, commit & push, update the system description in specs/system, then commit & push & delete the bug report. Continue until all solvable bugs are done. Then test until the next 100 bugs and proceed the same way. Take decisions as good as u can and document them in DECISIONS.md.

## 23:16 — `.pilcrow` is ignored, not committed {#d-pilcrow}

- **Status:** confirmed
- **Context:** "commit what we have" found an untracked `.pilcrow`, which holds an editor's per-file scroll and selection state.
- **Decision:** Add it to `.gitignore`.
- **Why:** It is personal editor state, not project content.

## 23:16 — `specs/system` is created, in the format of the user's other repos {#d-specs-system}

- **Status:** confirmed
- **Context:** The task says to update `specs/system`, but it didn't exist. The user's other repos (e.g. `agents2`) use one Markdown file per topic, with `title/created/edited` frontmatter.
- **Decision:** Write a baseline from code and README first, with one file per area. Each fix then updates the file for its area.
- **Why:** The task asks to "update" it, so a baseline is needed first.

## 23:16 — Process: two commits per bug, stable bug ids {#d-process}

- **Decision:** Each bug gets two commits:
  1. the fix with its regression test (and the What's New line), pushed;
  2. the `specs/system` update together with deleting the bug file and its index row, pushed.
- Bug ids stay stable. New bugs are numbered from BUG-052 on.
- Probes move from `specs/bugs/probes` into `Tests/MailModelTests` as regular tests when their bug is fixed.
- **Hard limits:**
  - Existing tests are never changed to make a fix pass. If a fix needs that, the bug is deferred (`status: deferred` plus a note here).
  - The app is built after each fix, but never launched against a real account. Mail and the `EWS_*` live tests stay untouched.
  - No mocks and no branches.

## 23:16 — Memory-search design question: follow the README rules {#d-memory-search}

- **Status:** decided (reversible)
- **Context:** `specs/bugs/design-question-memory-search-fallback.md`. The README says search matches every word, accent-insensitively, in subject, sender, To, Cc, preview and body. It also says the launch fallback searches memory "as before". The fast-search spec said to keep the memory path unchanged.
- **Decision:** Make the in-memory path follow the same matching rules as the index:
  - every word must match, at the start of a word;
  - case and accents don't matter;
  - the fields searched are subject, sender, To, Cc, preview and body.
  
  This is filed as BUG-052.
- **Why:** Users can't tell which path they are on. Search giving different results in the first seconds after launch looks broken. The existing in-memory search tests use single words, so they keep passing.
- **Alternatives:** Keep "as before". That was rejected, because it keeps two behaviours.

## 23:28 — Old attachment names decode as attachments without size {#d-bug-001}

- **Status:** decided
- **Context:** BUG-001. Builds up to b75308d wrote `attachments` as plain names (`["a.pdf"]`). Since 94d679c `Attachment` is a struct with a synthesized decoder, so an old `Cache.json` failed to import on every launch and old outbox rows were dropped.
- **Decision:** `Attachment.init(from:)` also accepts a bare string and reads it as the name (size and type nil). Encoding is unchanged (always the object form).
- **Why:** Old data must keep reading; a message with an attachment without size already gets its body fetched again (`needsBody`), which fills in size and type.
- **Alternatives:** A one-off migration of the stored JSON. Rejected: more code, and the decoder fix covers Cache.json, outbox rows and anything else that kept the old form.

## 23:35 — A message that leaves the list never stays selected {#d-bug-002}

- **Status:** decided
- **Context:** BUG-002. A selected message hidden by the unread filter or a search, or deleted by swipe or context menu, stayed selected after Delete; a second ⌘⌫ erased it from Trash unseen.
- **Decision:** After a delete or move (Delete, Archive, Junk, Move, drop, swipe, context menu), selected messages that are no longer in the visible list are taken out of the selection. If that was the whole selection, the message that followed it in the list is selected (the normal rule); if the selection wasn't in the list at all, nothing is selected. Deleting part of a multi-selection keeps the rest. A selected message that stays in the list (e.g. archiving a flagged one while viewing Flagged) stays selected. Marking read/unread and flagging don't trigger this, so opening a message can't cascade down the list.
- **Why:** Erasing must require the user to have seen the message in Trash, as in Mail.
- **Alternatives:** Clearing the selection in the view layer. Rejected: swipe and context menu call the store directly, and the store is where the tests live.

## 23:37 — Search leaves out Trash and Junk in SQL, before the limit {#d-bug-003}

- **Status:** decided; deviates from `specs/change/fast-search.md` §3 ("No Trash/Junk filtering in SQL")
- **Context:** BUG-003. `LIMIT 2000` was applied before Trash/Junk were dropped in memory, so newer hits in Trash or Junk could fill the cap: the list was empty while the status said "Showing the newest 2,000 results".
- **Decision:** `MailDatabase.search` filters `mailbox NOT IN ('trash', 'junk')` in the query, before the limit. `MailStore.hitList` still re-checks against memory.
- **Why:** The spec's reason for not filtering in SQL was that the database's mailbox can lag memory by up to 15 s. The cost of filtering is small: a message taken out of Trash in the last seconds is found once its move is saved (the next search after the save). The cost of not filtering is losing real results for good.
- **Alternatives:** Fetch more than 2,000 and cut after filtering. Rejected: no bound works for every mailbox, and the notice still lies.

## 23:41 — Characters XML forbids are dropped from EWS requests {#d-bug-004}

- **Status:** decided
- **Context:** BUG-004. U+000B/U+000C and other C0 controls (common in text pasted from Word or PDFs) went into the SOAP body as-is, so Send, Save Draft and invite answers failed with malformed XML.
- **Decision:** `xmlEscape`, the one function every piece of user text in a request goes through, leaves out U+0000–U+0008, U+000B, U+000C, U+000E–U+001F, U+FFFE and U+FFFF. Tab, LF and CR stay. Surrogates can't occur in a Swift `String`.
- **Why:** They are invisible and have no meaning in a mail; XML 1.0 can't carry them even as references. Dropping (rather than U+FFFD) avoids stray replacement boxes in the sent mail.
- **Alternatives:** Replace with a space or U+FFFD. Rejected: a Word line break (U+000B) as a space would be closer, but adds a rule for one character; the lead asked for dropping.

## 23:44 — Recipient lists: quotes, semicolons, blanks, and unquoted "Last, First" {#d-bug-005}

- **Status:** decided; closes BUG-005, BUG-015 and BUG-016 with one parser change
- **Context:** `Contact.parseList` split on every comma, kept the quotes around names, ignored semicolons (Outlook's separator) and trimmed only blanks, not line breaks or blanks inside `<>`.
- **Decision:** One scan splits on `,` and `;` outside double quotes and `<>` (backslash escapes inside quotes respected); pieces and addresses are trimmed of blanks and line breaks; surrounding quotes are removed from names. Also: a piece with no `@`, `<` or quote followed by a piece with `<…>` is joined to it, so Outlook's unquoted `Doe, John <john@x.com>` stays one recipient named "Doe, John".
- **Why:** These are the formats users paste from Outlook/Exchange; each wrong split sends a bogus address to Exchange. A bare word without `@` can't be delivered anyway, so joining it to the following named address loses nothing real.
- **Alternatives:** Only quoted names (strict RFC 5322). Rejected: Outlook's copy format is unquoted, and the BUG-005 report lists that case from the request side.

## 23:47 — The opened message stays in the unread-filtered list while selected {#d-bug-006}

- **Status:** decided (Mail's behaviour, from memory ⚠️)
- **Context:** BUG-006. Opening a message marks it read, so with the unread filter (⌘L) or in the Unread smart mailbox its row vanished at once.
- **Decision:** `MailStore` remembers the messages that were unread when `markSelectionRead` opened them. In `visibleMessages` they are judged as unread while they stay selected. They leave when the selection moves on, the filter is toggled, or another mailbox is selected. Only the read state is waived: a deleted or moved opened message leaves the list as before. Sidebar counts, Mark All as Read and drops use the real read state.
- **Why:** Lets the user read through unread mail with the filter on, and keeps next/previous anchored, as in Mail.
- **Alternatives:** Keep every selected read message visible. Rejected: a message that was already read when the filter was turned on would show under the filter, and a hidden selection could reappear.

## 23:49 — Own address compared without case in Reply All {#d-bug-007}

- **Status:** decided
- **Context:** BUG-007. Reply All dropped the account's own address only on an exact match, so `Me@Work.COM` stayed in To.
- **Decision:** Compare lowercased, as `addsNewRecipient` already does.
- **Why:** Exchange treats addresses case-insensitively; Mail never puts your own address in a Reply All.

## 23:51 — Reply quoting splits on any line ending {#d-bug-008}

- **Status:** decided
- **Context:** BUG-008. Quoting split the body on `"\n"`; in Swift `"\r\n"` is one `Character`, so a CRLF body (Exchange's) got `> ` only on its first line.
- **Decision:** Split on every newline character (`\r\n`, `\n`, `\r`, and the other Unicode line separators); the quoted lines are joined with `\n`.
- **Why:** The compose window and the sent text use `\n`; mixing in `\r` would only cause the same problem elsewhere.

## 00:01 — An unreadable Cache.json is set aside, the database starts empty {#d-bug-009}

- **Status:** decided
- **Context:** BUG-009. Without `Mail.sqlite`, a `Cache.json` that couldn't be decoded made `importCache` throw on every launch, so the database was never created and nothing was ever saved again.
- **Decision:** `importCache` renames the file to `Cache.json.unreadable` (`.unreadable-2`, … if that exists), creates an empty database, returns it and sets a status line naming the kept file. Mail is downloaded again from the server.
- **Why:** Everything in the cache except local-only state (flag colours, unsent changes) is on the server; refusing to create the database protected nothing. The user's file is never deleted, so it can still be recovered by hand.
- **Alternatives:** Delete the file (rejected: never delete user data); keep throwing and ask the user (rejected: no UI for it, and the app is unusable meanwhile).
- **Note:** The clock passed midnight during this run, so What's New lines from here on go to a new day, 2026-11-13, as CLAUDE.md asks ("today's day").

## 00:03 — EWS dates: any fraction, and no zone means UTC {#d-bug-010}

- **Status:** decided (assumption: zone-less values are UTC ⚠️, not seen on the live server)
- **Context:** BUG-010. One `ISO8601DateFormatter` read every EWS date and rejected valid `xs:dateTime` values with fractional seconds or without a zone: the message got year 1, invites and calendar events were dropped.
- **Decision:** `EWSBackend.isoDate` trims blanks, reads a fraction of any length (added to the whole seconds), and reads a time without `Z` or `±hh:mm` as UTC.
- **Why:** EWS sends UTC unless the request sets a `TimeZoneContext`, which this client never does; so a zone-less value is most likely UTC. A wrong zone would shift a time by hours; dropping the item or showing year 1 is worse.
- **Alternatives:** Read zone-less times in the Mac's zone (rejected: the server, not the Mac, decides the zone, and it is UTC by default).

## 00:06 — Every character reference XML forbids becomes U+FFFD {#d-bug-011}

- **Status:** decided
- **Context:** BUG-011. `EWSClient.sanitize` only replaced references to C0 controls; `&#xFFFE;`, `&#xFFFF;` and surrogate references (hex or decimal) still failed the whole page.
- **Decision:** `sanitize` now finds every numeric character reference and checks its value against XML 1.0's `Char` production. References to anything outside it (C0 controls but tab/LF/CR, surrogates, U+FFFE, U+FFFF, values past U+10FFFF or too large to read) become `&#xFFFD;`. Valid references stay as they are.
- **Why:** Checking the number is complete by construction; extending the regex range by range would miss the next case (e.g. `&#x110000;`).
- **Alternatives:** Add the ranges to the regex (rejected: hard to read, and decimal surrogate ranges need a long alternation).

## 00:08 — The server field is normalised; http:// is upgraded to https {#d-bug-012}

- **Status:** decided
- **Context:** BUG-012. `ewsURL` trimmed only spaces and treated anything not starting with `https://` as a bare host, so `http://…`, `host/EWS/Exchange.asmx`, `host/` or a pasted trailing newline gave a wrong URL, and a blank field passed the "Invalid server" check.
- **Decision:** `ExchangeAccount.ewsURL` trims blanks and line breaks, drops `https://` or `http://` (any case), trailing `/` and a trailing `/EWS/Exchange.asmx` (any case), then builds `https://<rest>/EWS/Exchange.asmx`. A rest that is empty, starts with `/` or contains blanks gives nil. A rest whose path ends in `.asmx` (a non-standard endpoint) is used as given, as full https URLs were before. A path in front of the standard one (a proxy prefix) is kept.
- **Why:** `http://` is upgraded rather than honoured: EWS with Basic/NTLM over plain http would expose the password, and Exchange serves EWS over https. Users paste the URL from Outlook or IT mails in all these forms.
- **Alternatives:** Honour `http://` (rejected: clear-text credentials); refuse it with an error (rejected: the user can't do anything better than https anyway); strip every path and keep only the host (rejected: breaks servers behind a path prefix).

## 00:10 — Attachment content: only the returned attachment itself {#d-bug-013}

- **Status:** decided
- **Context:** BUG-013. `parseAttachmentContent` took the first `FileAttachment` anywhere in the response, so an attached message carrying files could be opened as one of its files instead of its `.eml`.
- **Decision:** Read the first element under `m:Attachments`. A `FileAttachment` gives its own `Content`; an `ItemAttachment` gives the `MimeContent` that is a direct child of its item. Nested attachments are never read.
- **Why:** The request asks for exactly one attachment; anything deeper belongs to that attachment's content.

## 00:12 — Inline pictures with a generic type are fetched; explicit non-image types still aren't {#d-bug-014}

- **Status:** decided; narrower than the lead's "whatever its content type"
- **Context:** BUG-014. `inlineAttachmentIDs` took only `image/*` attachments, so pictures sent as `application/octet-stream` and referenced by `cid:` never loaded. The lead suggested fetching any referenced attachment whatever its type, but the existing test `inlineImagesAreTheReferencedImageAttachments` pins that a referenced `text/x-sh` attachment is *not* fetched, and existing tests are never changed.
- **Decision:** A referenced attachment is fetched when its type is `image/*`, `application/octet-stream`, or missing/empty. For the generic ones, `parseInlineImages` takes the type from the file name's extension (`UTType`), falling back to `application/octet-stream`.
- **Why:** Covers the reported case (and attachments without a type) while keeping explicit non-image parts, which the HTML can't show as a picture anyway, out of the page. The type from the name lets WebKit decode the picture with a correct `data:` type.
- **Alternatives:** Any type (rejected: contradicts an existing test; a mislabelled `text/html` part has no business inside an `<img>` data URI either).

## 00:15 — The list preview looks at the first 10,000 characters only {#d-bug-017}

- **Status:** decided
- **Context:** BUG-017. `Message.preview` split, filtered and joined the whole body on every read; the list reads it on every render, so a 1 MB body cost 80–300 ms per row.
- **Decision:** `preview` works on `body.prefix(10_000)` and returns at most 500 characters; the rules (lines starting with `>` left out, lines joined with a space) are unchanged. Measured 0.5 ms for the 1 MB body in a debug build; the test allows 50 ms.
- **Why:** The row shows two lines. A bounded prefix is simpler than a cache in a value type (`Message` is a `Hashable` struct compared and stored everywhere; a cached field would have to be kept out of equality and Codable).
- **Alternatives:** Cache the preview (rejected: see above). Trade-off accepted: a mail whose first 10,000 characters are all quoted lines shows an empty preview.

## 00:17 — Remote content detection: srcset, <link href>, poster, entity-quoted url() {#d-bug-018}

- **Status:** decided
- **Context:** BUG-018. `hasRemoteContent` missed `srcset`, `<link href>`, `poster` and `url(&quot;…&quot;)`, so the CSP silently blocked those resources and the Load Remote Content banner never appeared.
- **Decision:** The regex also matches `poster=` like `src=`; any `https?:` candidate inside a `srcset` value; `href` only inside a `<link …>` tag (an `<a href>` loads nothing); and `url(` followed by `"`, `'` or their entity forms (`&quot;`, `&apos;`, `&#34;`, `&#39;`, `&#x22;`, `&#x27;`).
- **Why:** These are what the CSP blocks; a false positive only shows a banner, a false negative hides content without telling.

## 00:19 — Inline image content types are validated, not escaped {#d-bug-019}

- **Status:** decided
- **Context:** BUG-019. `HTMLPage.document` put the attachment's `ContentType` (sender-controlled) unescaped into `src="data:…"`, so a `"` in it could inject attributes or markup into the message page.
- **Decision:** `HTMLPage.safeType` drops parameters after `;`, trims and lowercases, and accepts only `token/token` (RFC 6838 name characters `a-z 0-9 ! # $ & ^ _ . + -`). Anything else becomes `application/octet-stream`.
- **Why:** A whitelist is safer than escaping: an escaped `&quot;` would still produce a nonsense type and a broken picture, while a valid type is all a `data:` URI needs. WebKit should decode `<img>` data by its bytes, so the fallback type likely still shows real pictures (⚠️ from memory, not checked in the app).
- **Alternatives:** HTML-escape the type (rejected: keeps garbage in the URI; whitelisting covers it).

## 00:22 — Over-long attachment names are shortened to 255 bytes {#d-bug-020}

- **Status:** decided
- **Context:** BUG-020. `Attachment.fileName` didn't limit length, so names over 255 UTF-8 bytes (easy with umlauts or CJK) couldn't be written: open, Quick Look, save and forward failed.
- **Decision:** `fileName` keeps the extension (if it is at most 32 bytes) and cuts the rest at a whole character so the whole name is at most 255 UTF-8 bytes. `MailStore.freeURL` shortens the same way when it adds " 2", " 3", … The name shown in the message is unchanged.
- **Why:** 255 bytes is APFS's limit per name; checked here: a name of 127 × "ä" (254 bytes composed) writes, 128 fails, so counting the name's own UTF-8 bytes is safe. Cutting by `Character` keeps valid UTF-8 and never splits an accent from its letter. Keeping the extension keeps the file's type for Quick Look and the Finder.
- **Alternatives:** A short hash-based name (rejected: users recognise the start of the name).

## 00:24 — Draft HTML splits on every line ending {#d-bug-021}

- **Status:** decided
- **Context:** BUG-021. `Draft.html` split on `"\n"`; `"\r\n"` is one `Character` in Swift, so quoted Exchange text (CRLF) became one `<div>` when a picture was placed.
- **Decision:** Split on every newline character (`isNewline`: `\r\n`, `\n`, `\r`, U+2028 and the others), one `<div>` per line, as BUG-008 did for quoting.
- **Why:** Same root cause and rule as BUG-008; the plain-text path already kept these breaks.

## 00:26 — Draft HTML keeps runs of spaces with &nbsp; and tabs in a pre span {#d-bug-022}

- **Status:** decided (Mail's markup from memory ⚠️)
- **Context:** BUG-022. `Draft.html` wrote spaces and tabs as they were; HTML collapses them, so indentation and aligned columns were lost whenever a picture made the mail go out as HTML.
- **Decision:** Within each piece of text, a space that follows a space, or starts a line, becomes `&nbsp;`, so plain spaces and `&nbsp;` alternate (`a␣␣␣b` → `a &nbsp; b`); single spaces between words stay plain. A tab becomes `<span class="Apple-tab-span" style="white-space:pre">⇥</span>`, as Mail writes it. The alternation restarts after a picture mark (the existing test `picturesInTheTextGoOutInline` pins `and  bye` where a file mark was left out).
- **Why:** `&nbsp;` alternation is what Mail (and most clients) send and every client renders, including Outlook's Word engine, which ignores some CSS; `white-space: pre-wrap` on the body would also be simpler but isn't reliably honoured there. Alternating instead of all-`&nbsp;` keeps long runs breakable at line ends.
- **Alternatives:** `white-space: pre-wrap` on `<body>` (rejected: less compatible, as the lead noted); expand tabs to spaces (rejected: tab stops lose alignment in proportional fonts either way, and Mail keeps the tab).
