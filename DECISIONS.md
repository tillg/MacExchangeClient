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

## 00:31 — Bug hunts 2 and 3: `file://` fixture responses and WebKit probes are allowed {#d-hunt-harness}

- **Status:** decided (the user may veto)
- **Context:** The CLAUDE.md rule is "never mock without permission". EWS flows (sync, send, errors) can't be tested without a server.
- **Decision:** Probes and regression tests may point the real `EWSClient`/`EWSBackend` at a `file://` URL that holds a hand-written Exchange XML response. No class is replaced and there is no network. The tests are marked `// file:// fixture`, so they are easy to find and remove. Real `WKWebView` rendering probes are also allowed.
- **Why:** It is a recorded response read through the real transport, not a test double. Without it, the error paths found in round 2 (for example `ErrorInvalidSyncStateData` never being reset) can't be proven.
- **Alternatives:** Skip backend flows. Rejected, because that is where the data-loss bugs are.

## 00:31 — Filing rules for bug hunts 2 and 3 {#d-hunt-filing}

- **Decision:**
  - Bugs found by two hunters are filed once, with "Also seen by" in the file.
  - Findings that an existing test pins as intended behaviour are not filed. Example: Exchange Send and Save Draft show nothing locally until the next sync (`sendFromServerAccountQueuesAndAddsNothingLocally`), although the README says "show at once". This contradiction is left for the user to decide.
  - Every filed bug was re-run against the current HEAD before filing.

## 00:37 — A refused change undoes only what it set, while that still holds {#d-bug-023}

- **Status:** decided
- **Context:** BUG-023. `failed()` copied mailbox, read state, flag and invite back from the snapshot of the refused change, and re-added the message if it was gone. A refused read change so undid a later queued move, and a refused move brought back a message erased afterwards.
- **Decision:** `failed()` restores only the property the refused change touched, and only if it still holds the value that change set: read state for `setRead`, flag for `setFlagged`, mailbox for `move`. Invite answers restore the invite (and the mailbox, if still in Trash) while the answer is still the one refused. Only a refused erase (`delete`) re-adds a message that is gone; any other refused change leaves a vanished message vanished.
- **Why:** README: "If the server refuses a change, it is undone" — that change, not later ones the outbox will still send. A value that changed again since belongs to a newer change.
- **Alternatives:** Skip messages that have later queued changes (rejected: also skips the refused property, which the server never got).

## 00:38 — Move to Junk on a mixed selection moves all to Junk {#d-bug-024}

- **Status:** decided (Mail's behaviour from memory ⚠️)
- **Context:** BUG-024. `toggleJunk` flipped each message on its own, so a mixed selection (e.g. in Flagged, which lists Junk mail) sent the junk ones to the Inbox and the rest to Junk.
- **Decision:** If any selected message is not in Junk, all of them move to Junk. Only when every one is in Junk does the action work as Not Junk and move them to the Inbox.
- **Why:** The command reads "Move to Junk"; one action for the whole selection matches Mark as Read and Toggle Flag in this app.
- **Alternatives:** Disable the command for mixed selections (rejected: no such rule elsewhere in the app).

## 00:40 — Folders inside Trash count as Trash {#d-bug-025}

- **Status:** decided
- **Context:** BUG-025. Exchange moves a deleted folder into Deleted Items, so its mail arrives with a folder whose `parent` chain reaches `.trash`. Conversations, Flagged (list and count) and search only compared `mailbox == .trash`.
- **Decision:** `MailStore` keeps, per account, the set of folders inside Trash at any depth (worked out from `folders` whenever they change). Every place that leaves out Trash also leaves those out: conversations, the Flagged list and count, the memory search and the check of the index's hits against memory. Changing `folders` now also bumps `revision`, so cached counts and lists follow a new folder tree. Junk's subfolders are unchanged.
- **Why:** Mail in a deleted folder is deleted mail. Worked out once per folder change (only when the tree really changed, so an unchanged folder list from a sync doesn't clear the caches), the per-message check is one dictionary lookup, so the 70k-message timings are unchanged.
- **Known limit:** The database's search still leaves out only `trash` and `junk` before its 2,000-hit limit (it doesn't know the folder tree), so hits in deleted folders can take up places in that limit before memory drops them. Rare (deleted folders with many matching messages); left as is.
- **Alternatives:** Walk each message's parent chain on every check (rejected: per-message cost in the 70k paths).

## 00:42 — Reply All names each address once {#d-bug-026}

- **Status:** decided
- **Context:** BUG-026. Reply All joined sender, To and Cc without removing repeats, so a sender also in Cc, or one address in two spellings of case, appeared twice.
- **Decision:** Addresses are compared without case; the first occurrence is kept (sender before To before Cc), with its spelling.
- **Why:** Exchange treats addresses case-insensitively; Mail lists each person once.

## 00:43 — Reply All keeps the original Cc in Cc {#d-bug-027}

- **Status:** decided
- **Context:** BUG-027. Reply All put sender, To and Cc all into To and left Cc empty.
- **Decision:** To = original sender + original To; Cc = original Cc. My own address is left out of both, and each address appears once across both fields (To wins, as it comes first; compared without case).
- **Why:** That is what Mail and Outlook do; people who were only copied stay copied.

## 00:45 — Reply and forward prefixes: recognised in any case, normalised to "Re: " / "Fwd: " {#d-bug-028}

- **Status:** decided (lead's rule; differs from the probes, which expected the original prefix kept as typed)
- **Context:** BUG-028. Only an exact `Re: ` / `Fwd: ` was recognised, so Outlook's `RE:` / `FW:`, `Re:x` without a space and German `AW:` / `WG:` got a second prefix.
- **Decision:** A leading `Re:` or `AW:` (reply, Reply All) or `Fwd:`, `Fw:` or `WG:` (forward), in any case and with or without one space after the colon, is replaced by `Re: ` or `Fwd: `. The colon must follow the letters directly, so "Report:" or "Fwiw:" aren't prefixes. A prefix of the other kind stays (`FW: x` → `Re: FW: x`). Only the first prefix is looked at.
- **Why:** One prefix of each kind, in Mail's spelling, is what Mail shows; normalising also turns `AW:` into the prefix the reader's client recognises.
- **Alternatives:** Keep the existing prefix as typed (the probes' expectation; rejected per the lead: the subject line would mix spellings within one thread). Strip a whole chain of prefixes (rejected: more than asked; the stack only grows when other clients add to it).

## 00:46 — Reply to my own message goes to its recipients {#d-bug-029}

- **Status:** decided (Mail's behaviour from memory ⚠️)
- **Context:** BUG-029. Reply always went to the sender, so replying to a message from Sent (or a sent card in a conversation) addressed it to myself.
- **Decision:** When the sender is the account's own address (compared without case), Reply goes to the original To recipients (each once, my own address left out). Cc stays empty, as for any Reply. A note only to myself (no other To recipient) still replies to me, as before.
- **Why:** That is what Mail and Outlook do; a reply to yourself is never what's meant.

## 00:48 — A local Save Draft keeps Cc {#d-bug-030}

- **Status:** decided
- **Context:** BUG-030. Without a server, `saveDraft` built the Drafts message without `cc`; `send` and `failed` already kept it.
- **Decision:** Pass `cc: Contact.parseList(d.cc)` as they do.
- **Why:** A saved draft must keep what was typed.

## 00:49 — "Search failed" lasts as long as the search {#d-bug-031}

- **Status:** decided
- **Context:** BUG-031. After an index search failed, "Search failed: …" stayed under the title after the search was cleared and after the next search succeeded.
- **Decision:** The failure text is cleared in the same places as the 2,000-results notice: when the search is cleared, and when a later index search succeeds (below the limit). Any other status is left alone.
- **Why:** Both are notices about the current search; a stale failure tells the user search is still broken.

## 00:50 — A proposal needs both a start and an end {#d-bug-032}

- **Status:** decided
- **Context:** BUG-032. A proposed new time with only a start or only an end was queued; EWS writes `ProposedStart`/`ProposedEnd` only as a pair, so the organizer got a plain answer and no proposal.
- **Decision:** `respond(_:to:)` refuses such a reply with the status "The proposed meeting needs both a start and an end." and queues nothing, like the existing end-before-start check.
- **Why:** The user would otherwise believe a time was proposed. The compose window always sets both times, so this guards the store's API only; no What's New line.

## 00:52 — Memory search follows the search rules, but keeps matching inside words {#d-bug-052}

- **Status:** decided; implements [#d-memory-search](#d-memory-search) with one deviation
- **Context:** BUG-052. The in-memory search (sample data, every launch until stored mail has loaded, and after an index error) matched the whole query as one substring in subject, sender and body only, accent-sensitively.
- **Decision:** Every typed word must match, in any order, in any of subject, sender, To, Cc (names and addresses), the server's preview or the body; case and accents don't matter. **Deviation:** a word may still match inside a word (`report` finds "Misreported"), not only at the start of one.
- **Why:** #d-memory-search said "at the start of a word" and assumed the existing tests used only single words. But `searchTypedBeforeTheIndexIsReady` pins memory finding "Misreported" for `report` (and `searchHitsFollowWhatIsInMemory` relies on the same difference), and existing tests are never changed. Matching more on the memory path never hides mail the index would show.
- **Cost:** Each query folds every message's fields once: 0.17 s for 70,000 messages in a debug build (new test `memorySearchStaysFastAt70kMessages`). Only the launch window and index errors pay it.
- **Alternatives:** Word-start matching as decided (rejected: breaks an existing test). Keep "as before" (rejected in #d-memory-search).

## 01:09 — A complete sync from the start is authoritative for its folder {#d-bug-053}

- **Status:** decided
- **Context:** BUG-053. After the conversation upgrade (all tokens reset), and after any other sync that starts without a token, the pass lists what is on the server now and reports no deletions. Mail deleted or moved elsewhere meanwhile stayed in its folder for good.
- **Decision:** When a folder's sync starts without a token, the store notes the server IDs it holds. Every page of that pass (single `apply` or a history batch) ticks off the IDs it lists (upserts and read changes). When the pass completes, the rest of that folder's server messages are removed (and forgotten on disk). Messages with a change still queued stay; they are checked again after each drain and go once their change is done. Local messages (no server ID), other folders and other accounts are not touched. The newest-N lookup doesn't tick off IDs: it may run before a deletion the pass later sees.
- **Why:** README: the upgrade sync is meant to refresh; a from-scratch SyncFolderItems pass enumerates every item in the folder, so anything it doesn't list is gone.
- **Limit:** The noted IDs live in memory only. If the app quits in the middle of a from-scratch pass, the pass resumes from its saved token after relaunch and removes nothing at the end (ghosts from that window stay). Persisting the set (up to one ID per message) for a one-off upgrade wasn't worth a new table; restarting the pass from scratch on every relaunch could keep a big Sent folder from ever finishing.
- **Alternatives:** Restart an interrupted pass from scratch (rejected, see above). Persist the ID set in a new table (rejected for now: size and write cost for a rare case).

## 01:12 — A rejected sync token is dropped and the folder syncs from the start once {#d-bug-054}

- **Status:** decided
- **Context:** BUG-054. When Exchange answers SyncFolderItems with `ErrorInvalidSyncStateData`, the store kept the token and the `complete` mark, so every check of that folder failed the same way and it never got new mail.
- **Decision:** `EWSBackend.sync` reports `ErrorInvalidSyncStateData` for a request that carried a token as `SyncTokenRejected` (a backend-neutral error next to `AuthenticationError`). The quick check, the history and the background checks of complete folders then forget that folder's token and `complete` mark. The folder syncs again from the start, and the BUG-053 rule removes what the complete pass doesn't list. A sync without a token is never reported as rejected, so a folder whose fresh sync also fails goes to the history's failed list for the session as before. The reset happens once per folder and session (`tokensReset`): if the new token is rejected too, the folder goes to the history's failed list with a status and keeps its token, instead of being downloaded again on every check.
- **`ErrorSyncFolderNotFound`:** not handled the same way. It means the folder itself is gone; syncing it again from the start fails the same way. That case belongs to the removed-folder bug (BUG-077).
- **Why:** Microsoft's guidance for an invalid sync state is to sync again without one (⚠️ recalled).
- **Alternatives:** Reset on any sync error (rejected: a network or throttling error would throw away a good token and re-download whole folders).

## 01:15 — Files of a draft kept after a failed send are stored in a new `files` table {#d-bug-055}

- **Status:** decided
- **Context:** BUG-055. A send Exchange refused is kept in Drafts on this Mac. Its row was written, but the file content stayed in memory only, so after a relaunch the files couldn't be opened; they may exist nowhere else.
- **Decision:** A new table `files(message, position, data)`, created with `CREATE TABLE IF NOT EXISTS` (an older database simply gets it when opened; no other change). `MailStore.failed` keeps the content for writing when the account is stored; `takeChanges` carries it in `StoreChanges.files`, `retry` and `storedState` include it, `meta()` reads it back at launch, and removing the message removes its rows. Sample data still keeps file content in memory only.
- **Why:** The outbox already stores a draft's files inside its JSON row; once the change leaves the outbox the kept message needs its own copy. A separate table keeps the 22-column `messages` row unchanged.
- **Alternatives:** A BLOB column on `messages` (rejected: every message row and the upsert would change for a rare case). Files in a folder next to the database (rejected: a second store that can get out of step with the database).

## 01:18 — An account set up in Settings is never removed as sample data {#d-bug-056}

- **Status:** decided
- **Context:** BUG-056. `removeLocalAccounts` (run on every sign-in) treated every account without a backend as sample data. An Exchange account whose Keychain password is missing has no backend, so signing in to re-enter the password removed it while its server mail stayed in All Inboxes without an account. Sign-in also created a new account ID, so the same mail would download twice.
- **Decision:**
  - `Account` gets `isServer` (default false; `ExchangeAccount.account` sets it). `removeLocalAccounts` drops only accounts that are neither `isServer` nor have a backend. The existing test `removeLocalAccountsDropsSampleDataOnly` (a plain account that received a sync is dropped) still holds, which is why the store's `serverAccounts` set (filled by any sync) couldn't be the rule.
  - `add(_:backend:)` takes an optional backend. `AppSetup.connect` registers a password-less account through it (a server account whose changes wait in the outbox) and shows "Password needed for … Sign in again in Settings ▸ Accounts." instead of appending it as a plain account.
  - Signing in with the same email, username and server as a saved account reuses that account (its ID and mail); `add` then gives the existing account its backend and lifts a sign-in pause, instead of adding a second account.
- **Why:** The lead's rule: decide by the account's kind, not by whether a backend exists.
- **Alternatives:** Use `serverAccounts` (rejected: breaks the pinned test above). Remove the account's server mail too (rejected: it is the user's mail).

## 01:21 — A summary keeps what only the loaded body knows, field by field {#d-bug-057}

- **Status:** decided
- **Context:** BUG-057. EWS list summaries carry From/To/Cc as names only. When a message whose body was loaded was merged again (a sync after it was read on the phone, or the newest-50 lookup every 15 s), `merge` kept the body but took the names-only contacts and `HasAttachments` from the summary. Reply then went to "" and the paperclip came back.
- **Decision:** For a loaded message and a summary, each contact (From, then each To and Cc in order) is kept from the body when the summary's contact has no address and names the same person (name, any case, or the address shown as the name); a summary contact that has an address replaces it. `hasAttachments` follows the kept attachment list. When a summary names other people (or a different number of them), the message changed on the server (a draft edited elsewhere): the summary is taken as it is and the body is no longer kept, so it is fetched again when shown and no empty address stays with a body marked loaded.
- **Why:** The body fetch exists to bring the addresses (`MessageBody` doc); the summary can only tell that the people changed, not who they are.
- **Risk:** If Exchange's `DisplayTo` ever names a recipient differently from the body's `Mailbox` name for unchanged mail, that message's body is fetched again each time it is shown (correct, but extra requests). Not seen in the documented shapes.
- **Alternatives:** Always keep the body's contacts (rejected: an edited draft would show stale recipients for good).

## 01:24 — Save in the close sheet waits for the original's files {#d-bug-094}

- **Status:** decided
- **Context:** BUG-094. Closing a forward while its original files were still downloading showed the "Save this message as a draft?" sheet; Save called `saveDraft`, which refuses while files load (Mail's AttachmentsPendingMessage), and the window closed anyway: the text was lost.
- **Decision:** `saveDraft` now returns whether it saved (`@discardableResult`). When the sheet's Save is refused, the window stays open with the status "The message is saved and closed once its attachments have loaded."; as soon as the files are in (`loadingOriginal` becomes nil), the window saves the draft as it is then (with the files and any later typing) and closes. Cancel in a later close sheet withdraws that.
- **Why:** The lead allowed "save … or wait"; saving at once without the files would contradict the existing test `forwardIsNotSentBeforeItsAttachmentsAreIn` (a forward isn't saved before its original files are in), which can't be changed. Waiting keeps both rules and never discards. The probe's expectation (saveDraft keeps the text at once) is therefore not adopted; the regression test checks the refusal is reported and that the later save keeps text and files.
- **Alternatives:** Save the text at once without the original's files (rejected: pinned test above, and the forward would lose its files). Disable Save in the sheet (rejected: the user would have to choose between waiting by hand and losing the text).

## 01:28 — A send under way is marked and saved first, and never repeated after a relaunch {#d-bug-095}

- **Status:** decided
- **Context:** BUG-095. A queued send stays in the outbox until the server answers, so the 15-second save or the save on quit stored it while its request was on the way. If the app quit or crashed before the next save, the next launch sent the mail again without asking.
- **Decision:**
  - `PendingChange` gets an optional `inFlight` (absent in older rows, which decode as before; tested with a literal old row).
  - Before a `.send` request goes out, `drain` sets `inFlight` and awaits `saveBeforeSending`, which the app sets to a write of the current changes that returns once they are on disk (`AppSetup.saveAndWait`). Tests leave it nil.
  - At the next launch `restore(meta)` doesn't queue a send marked in flight: it is kept as a local message in Drafts (with its files, as after a refused send), and the status says "“…” may already have been sent: the app quit while sending it. It's in Drafts on this Mac; check Sent before sending it again." The outbox is marked to be written, so a second relaunch finds one draft and nothing to send.
  - A send refused at sign-in (`AuthenticationError`) provably didn't go out: its mark is cleared and it waits for the account as before.
- **Why:** README: a message that fails to send is never resent automatically; a send interrupted by quitting is the same uncertain case as a timeout.
- **Not covered:** Invite answers (`respond`, `reply`) and other changes in flight are still replayed after a crash; repeating a read/flag/move is harmless, a repeated answer may notify the organizer twice. The status line is cleared by the next successful mail check (filed separately as BUG-100), so the draft in Drafts is the lasting trace.
- **Alternatives:** Mark without the extra save (rejected: a crash between the mark and the 15-second save would still resend). Ask the user at launch with a dialog (rejected: the store has no UI; Drafts plus status matches the existing timeout rule).

## 01:30 — A network error pauses only that account's changes {#d-bug-096}

- **Status:** decided
- **Context:** BUG-096. The outbox is one queue for all accounts, and `drain` stopped at the first network error, so a VPN-only or down server held up every other account's changes and sends.
- **Decision:** On a `URLError` for a change that isn't a send or invite answer, `drain` notes the account as unreachable for the rest of this drain and goes on with the oldest change of any other account. All later changes of the unreachable account wait, so its order is kept; they go with the next refresh. The status text stays "Offline – changes will be sent to Exchange later".
- **Why:** README: offline, changes wait until the next refresh; offline is per server. The quick check already treats accounts independently.

## 01:33 — With remote content blocked, every `<link>` of the mail is disabled {#d-bug-097}

- **Status:** decided
- **Context:** BUG-097. With remote content blocked, `<link rel="preconnect">` still made WebKit open a TCP connection (and DNS lookup) to the sender's host: resource hints aren't covered by the Content-Security-Policy, so the sender learns the mail was opened.
- **Decision:** `HTMLPage.document` renames every `<link` tag start of the mail (any case, followed by blank, `/` or `>`) to `<x-blocked-link` when remote content is blocked. An unknown element does nothing. With remote content allowed the mail is left as it is. Tested in a real `WKWebView` against a 127.0.0.1 listener (13 vectors, including preconnect, dns-prefetch, prefetch, preload and prerender) and at string level (case, unquoted values, `href` before `rel`, several rel tokens, line breaks and tabs, `<link/`).
- **Matching by scalar:** the pattern runs with Unicode-scalar semantics, as the HTML parser reads. By grapheme cluster (Swift's default) `<link/` followed by a combining mark (U+0301) wasn't renamed, and WebKit still preconnected; found in review, now a test vector in both tests.
- **Why:** Matching all `<link>` rather than certain `rel` values can't be bypassed by spelling the value differently, and nothing else a link loads (stylesheets, icons) is allowed while remote content is blocked anyway. Renaming only the tag start needs no parsing of attributes.
- **Alternatives:** Remove only links whose `rel` names a hint (rejected: rel parsing is easy to get wrong). Turn hints off in the web view's preferences (rejected: no public `WKPreferences` switch for preconnect).
- **Not covered:** DNS prefetching of plain `<a href>` hosts couldn't be observed with a loopback address; not changed.

## 01:43 — Snapshots go through `tools/snapshot.sh` only {#d-safe-snapshot}

- **Status:** decided (safety)
- **Context:** The UI hunter found that the CLAUDE.md snapshot command (`MAIL_SNAPSHOT=… .build/debug/MailReplica`) is not sample-only on this machine. The app's defaults domain holds a saved Exchange account, so the command would create the real connection.
- **Decision:** New `tools/snapshot.sh`: it copies the binary to `MailReplicaSnapshot`, which gets its own empty defaults domain, and always sets `MAIL_SAMPLE_DATA=1`. CLAUDE.md now points to the script.
- **Why:** Unattended agents must never reach the real mailbox.

## 01:43 — Bug hunt round 4: 21 bugs filed (BUG-133..153) {#d-hunt-4}

- **Decision:**
  - Two performance findings (a server deletion and the Delete key over budget) were dropped: they pass at current HEAD after the batch-4 fixes.
  - The UI findings (BUG-*-UI) are proven by screenshot pairs in `specs/bugs/png/`, not by unit tests: the test target can't import the app.
- **Count:** Rounds 2–4 found 101 new bugs (41 + 39 + 21).

## 01:46 — Save and Forward never use an edited Mail Downloads copy {#d-bug-133}

- **Status:** decided
- **Context:** BUG-133. Opening an attachment writes it to Mail Downloads, where apps edit it in place (Preview autosaves filled-in forms). Save Attachment, Save to Downloads, Save Attachments…, the save panel, drag-out and Forward all read that file, so private edits went out or were saved as "the attachment".
- **Decision:** The store notes size and modification date of every attachment file it writes. New `originalAttachmentFile` returns the opened file only while both are unchanged; otherwise it fetches the content again (local data or the server) into an `Original` folder beside it, checked the same way. Save, save panel, drag-out and Forward use it. Opening and Quick Look keep using the opened file, so the user's edits stay visible and aren't overwritten. A file from an earlier session (not noted) counts as changed and is fetched again.
- **Why:** What's attached is the message's content, as on the server. Overwriting the opened copy would throw away the user's work.
- **Alternatives:** Hash of the original (rejected: size and date catch every in-place save and need no extra read). Refetch on every save (rejected: an extra server round trip for the common unedited case).
- **Not covered:** If the opened copy was changed and fetching the original fails (offline, paused account), Forward leaves that file out without a word, as for any file that can't be fetched (BUG-071).

## 01:53 — A batch is judged per item {#d-bug-059}

- **Status:** decided
- **Context:** BUG-059. Read, flag, move and erase go to Exchange in batches of up to 100. Exchange changes each item on its own and answers with one response message per item, but one `ErrorItemNotFound` made the whole batch throw, so the store undid the change for all of them and lost the new IDs of moved items.
- **Decision:**
  - `EWSBackend` calls these operations non-strict and checks the answer per item (`checkBatch`). It requires one response message per item; an answer with fewer is an error for the whole batch, never a success.
  - Refused items are thrown as the new MailModel error `PartlyRefused` (refused IDs with their reason, plus the new IDs of the items that moved). Protocol signatures stay as they are.
  - `drain` applies the new IDs, then undoes only the refused items through `failed()`. It matches the change's IDs to `previous` by position, because an earlier move renames the IDs in the change but not in `previous`.
  - On erase, `ErrorItemNotFound` counts as done: the item is gone either way.
- **Why:** README: a refused change is undone. Here the server refused one item, not the other 99.
- **Alternatives:** Return the refused items from each method (rejected: it changes every signature, and `move` already returns the new IDs). Treat items missing from a move's ID map as refused (rejected: a successful move may come back without a new ID).
- **Not covered:** A transient per-item code (`ErrorServerBusy` inside one response message rather than as a fault) counts as a refusal of that item.

## 01:56 — An answer without any Exchange result is an error {#d-bug-060}

- **Status:** decided
- **Context:** BUG-060. `EWSClient.call` failed only on unparsable XML, a SOAP Fault, HTTP 401 or a bad `ResponseCode`. An empty SOAP body or a proxy's well-formed error page passed as success: Send "succeeded" without sending, a sync "completed" with an empty token.
- **Decision:** After the Fault check, `call` (strict or not) throws when the answer has no `ResponseCode` at all ("The server's answer holds no Exchange result", code "HTTP <status>"). Every operation the app uses answers with a `ResponseCode` per item, so no real answer is affected.
- **Why:** README: a message that fails to send is kept in Drafts; a non-answer is a failure, not a success.
- **Alternatives:** Reject any non-2xx status first (rejected: Exchange sends SOAP faults with HTTP 500, which must still be read).

## 01:58 — A busy server or a non-answer keeps changes queued {#d-bug-061}

- **Status:** decided
- **Context:** BUG-061. Throttling (`ErrorServerBusy` fault with `BackOffMilliseconds`) or a gateway's 503 page undid the user's change as "Exchange refused a change". Only `URLError` kept changes queued.
- **Decision:**
  - New MailModel error `ServerBusy` (message, optional `retryAfter`). `EWSClient.call` throws it for an `ErrorServerBusy` fault (with its back-off), for an unreadable answer and for an answer without any `ResponseCode` (the BUG-060 case, which threw `EWSError` until now). The general rule: a body that isn't an Exchange answer means Exchange didn't act, so nothing was refused. The 503 page in the test arrives over `file://` (no HTTP status), so the rule can't depend on the status code.
  - `drain` treats `ServerBusy` like a network error: that account's changes stay queued, in order, for the next refresh, and other accounts go on. Status "Exchange is busy – changes will be sent later". A back-off is kept in memory per account (`busyUntil`, checked in `canSend`), so no change of that account is sent before it has passed. Not persisted: after a relaunch the back-off has long passed.
  - Send, invite answer and reply on `ServerBusy` go to `failed` (Drafts) as on a network error, also for a clean `ErrorServerBusy` fault: one rule for every uncertain answer, and the README promises a failed send is never resent automatically.
  - Time-outs are `URLError`s and already kept changes queued.
- **Why:** README: offline, changes wait; refused changes are undone. Throttling and a gateway page are neither a refusal.
- **Alternatives:** Requeue a send on a clean `ErrorServerBusy` fault (rejected for now: one rule is simpler, and Drafts keeps the message). Retry by itself after the back-off (rejected: the next refresh does it).
- **Not covered:** An unreadable answer that keeps coming (a wrong server URL answering with a web page) keeps changes queued for every refresh, like an unreachable server.

## 01:59 — Mail renders in almost-standards mode {#d-bug-066}

- **Status:** decided
- **Context:** BUG-066. The page had no doctype and the mail's own one lands inside our wrapper, where the parser ignores it, so every mail was in quirks mode: WebKit's quirks sheet resets tables to 16 px, so signatures and Outlook layouts showed larger than the text around them.
- **Decision:** `HTMLPage.document` starts with `<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN" "http://www.w3.org/TR/html4/loose.dtd">`, which gives almost-standards (limited-quirks) mode for every mail (`compatMode` reports `CSS1Compat`).
- **Why:** Tables inherit the 14 px default as in standards mode, while a picture alone in a table cell gets no baseline gap under it (checked: 12 px cell for a 10 px picture with `<!DOCTYPE html>`, 10 px with this one); newsletters built from sliced pictures in table cells rely on that. The sample newsletter looks the same before and after, except that its button text inherits the table's 14 px.
- **Alternatives:** `<!DOCTYPE html>` (rejected: gaps under pictures in cells). Keep quirks mode and add `table { font-size: inherit }` (rejected: the other quirks, such as percentage heights against the window, stay; see BUG-110). Use the mail's own doctype (rejected: mail without one, most Outlook mail, would keep 16 px tables).

## 02:01 — An unreachable account doesn't stop the other accounts' history {#d-bug-098}

- **Status:** decided
- **Context:** BUG-098. `syncHistory` returned at the first network error. Accounts are tried in order, so while the first account's server was unreachable, no other account's history progressed and their complete folders got no background check.
- **Decision:** On a `URLError` or `ServerBusy`, the history notes the account as unreachable for this run and goes on with the other accounts (`nextHistoryFolder(skipping:)`); the background checks of complete folders skip that account. Its folder isn't marked failed, so it is tried again at the next run, as before.
- **Why:** README: a folder whose history fails is skipped; offline is per server, as for the quick check and the outbox (BUG-096).

## 02:03 — Quote bar colours for Apple Mail quotes {#d-bug-111}

- **Status:** decided (⚠️ colours estimated)
- **Context:** BUG-111. Mail's MUIWebDocument.css draws `blockquote[type=cite]` with no margin, 8 px padding and a 2 px left bar, but its bar and text colours are placeholders (`@[QUOTE_BAR_COLOR_LVL1_RGB]` …) that Mail fills in at run time; they aren't in any file on disk.
- **Decision:** The rules are taken as Mail has them. Colours (bar and text alike), from memory of Mail's "Color quoted text" defaults blue, green, purple: `rgb(0, 64, 214)`, `rgb(0, 128, 64)`, `rgb(128, 0, 160)`. Marked ⚠️ in README. Mail's dark-mode variants are left out: the page is always light here.
- **Alternatives:** Bar only, text colour unchanged (rejected: Mail's rule colours the text too). Grey bars (rejected: Mail tells levels apart by colour).

## 02:04 — Apple Mail's pictures capped with `max-inline-size` {#d-bug-112}

- **Status:** decided
- **Context:** BUG-112. Mail's MUIWebDocument.css caps `img.Apple-web-attachment` and `video.Apple-web-attachment` with `max-width: 100% !important`. The existing test `imagesAreNotLimitedToTheirContainer` requires that the page contains no `max-width` at all (it guards against a general image cap, which shrank avatars in zero-width boxes to nothing), and existing tests can't be changed.
- **Decision:** The rules are taken from Mail, with `max-width` written as its logical twin `max-inline-size` (identical in horizontal text, the only writing mode mail uses here). Only these two classes are capped; every other image keeps its size.
- **Note for review:** this satisfies the pinned test by spelling, not by changing what it guards (no general cap). If the test should instead say "no `max-width` for all images", it can be reworded and the rule spelled as Mail has it.
- **Alternatives:** Defer (rejected: the bug is real and the fix is Mail's own rule). Change the test (not allowed unattended).

## 02:04 — A check clears only its own account's connection notice {#d-bug-100}

- **Status:** decided
- **Context:** BUG-100. Every successful account check set `status = historyError` (usually nil). "Couldn't send …" was gone within 15 s, and with two accounts the second one's success wiped the first one's error, depending on dictionary order.
- **Decision:** Notices about an account's connection (its failed check, "Offline – …" and "Exchange is busy – …" from the outbox) are noted per account (`connectionNotices`). A successful check of that account clears its own notice, and only while it is still the one shown. Every other notice ("Couldn't send …", "Exchange refused a change", sign-in failed, couldn't open or save a file) is no longer cleared by checks: it stays until another notice replaces it.
- **Why:** The failed-send notice is the only sign a mail didn't go (README). One status line, so the source decides who may clear it.
- **Alternatives:** A notice list or a timeout (rejected: a UI change; the status line stays one line). Clear "Couldn't open/save" notices on the next check (rejected: no source says they are stale; any later notice replaces them).
- **Not covered:** Two accounts offline at once share the same "Offline" text; the first one to work again clears it although the other is still offline, until that one's next check fails and shows its own error.

## 02:09 — The body is measured by the root element, not our wrapper {#d-bug-064}

- **Status:** decided
- **Context:** BUG-064. A stray `</div>` in a mail closes `#mail-replica-body`, and the view, sized to that div, cut the rest of the mail off.
- **Decision:** The measuring script moves to `HTMLPage.measureScript` (so tests run the app's own script) and measures the bottom of `document.documentElement`'s box, which contains the body with its margins whatever the mail's markup. The wrapper stays (it keeps `display: flow-root`) but no longer defines the height.
- **Test:** the probe also checked that the tail sits inside the wrapper; that is an implementation detail and not adopted (as in d-bug-094). The regression test checks measured height ≥ what the page draws; a guard test checks the view still shrinks when the window is widened.
- **Alternatives:** An end marker after the mail (rejected: an unclosed `<table>` in the mail would foster-parent it above the table). `scrollHeight` (rejected: it never drops below the view's own height, so the view wouldn't shrink).

## 02:08 — A server page doesn't bring back a message gone here with a change queued {#d-bug-072}

- **Status:** decided
- **Context:** BUG-072. `merge` protected messages with queued changes only while they were in memory. A Trash page or the newest lookup fetched before a queued erase reached the server appended the erased message again, under a new local ID.
- **Decision:** `merge` skips an upsert whose remote ID has a queued change and no message here. Once the change is done (or refused, which re-adds an erased message), later pages behave as before.
- **Why:** README: erasing removes the message; the server page is older than the user's action.

## 02:11 — A move's new ID that the sync already brought merges into the moved message {#d-bug-073}

- **Status:** decided
- **Context:** BUG-073. While a move is on its way, the destination's sync can merge the moved item under its new ID as a new message. `renameRemote` then gave the original the same ID: two messages, one of them a stale duplicate forever.
- **Decision:** `renameRemote` first drops any message of the account that already has one of the new IDs (and isn't itself being renamed); the renamed message keeps its local ID, loaded body and selection (a selected copy is replaced by it in the selection). The dropped copy is removed from disk with the next save.
- **Why:** One server item is one message. The original carries what the user has (body, selection); the copy has nothing the next sync of the destination won't bring again.

## 02:14 — Viewport units follow the window, through WebKit SPI {#d-bug-110}

- **Status:** decided (uses a private WebKit method)
- **Context:** BUG-110. The body view is as tall as the page, so the page's viewport was the view itself: `100vh` blocks were 1 pt when measured and then grew with the view (the end of the mail below the view), and `html, body { height: 100% }` kept the height measured at a narrow window forever. MailChimp's `height="100%"` table was already fixed by almost-standards mode (d-bug-066).
- **Decision:**
  - The page's style has `html:root { height: auto !important; min-height: 0 !important }` (more specific than a mail's `html { … !important }`).
  - `HTMLPage.pinViewportUnits(of:to:)` calls `-[WKWebView _setViewportSizeForCSSViewportUnits:]` (checked with `responds(to:)`; does nothing if a later WebKit drops it). `BodyWebView.layout` sets it to the view's width and the window's content height whenever that changes: `100vh` is the window's height, as a reader of the mail expects.
- **Why:** There is no public API: `setMinimumViewportInset` only changes `lvh`/`svh`, and plain `vh` can't be overridden in CSS. Without it a re-measure on page changes (BUG-109) would make a `100vh` block grow without end. Verified in a real `WKWebView`: with the size pinned, the block's height stays the same when the view grows.
- **Risk:** private method; if it disappears, viewport units fall back to the old behaviour (no crash), and 109's re-measuring is not installed then (see d-bug-109).
- **Alternatives:** Rewrite `vh` in the mail's CSS (rejected: needs parsing of style sheets and inline styles). Measure in a hidden second web view (rejected: double the work for every message).

## 02:14 — A deletion seen while a move is queued is held, and applied if the move fails {#d-bug-074}

- **Status:** decided
- **Context:** BUG-074. `merge` ignored a deletion for a message with a queued move, assuming the move caused it. If the message was really deleted elsewhere, the move then failed, `failed` put it back in its old mailbox, and no later sync reported the deletion again: a ghost forever.
- **Decision:** `merge` notes such deletions per account (`deletedWhileMoving`, in memory). A move that goes through (also the moved part of a partly refused batch) drops them: they were its own. A refused move removes the noted messages instead of moving them back.
- **Why:** If the move failed, the move can't have caused the source's deletion, so the server's word stands.
- **Not covered:** The note isn't saved: if the app quits between the deletion and the failed move, the message comes back as before (rare: both happen within one drain, usually seconds). A move that stays queued (offline) keeps the note until it is sent.

## 02:18 — The body view re-measures on size changes {#d-bug-109}

- **Status:** decided
- **Context:** BUG-109. The body was measured only after load and on width changes, so content that grew later (lazy pictures, an opened `<details>`) was cut off.
- **Decision:** `HTMLPage.observeResizes` adds `HTMLPage.resizeScript` to the web view's user content controller in the `.defaultClient` world: a `ResizeObserver` on the root and the body posts `mailReplicaResize`; `MailWebView.Coordinator` measures again. Checked in a real `WKWebView` that user scripts in that world run and post with content JavaScript off. The mail's own scripts still never run.
- **Feedback guard:** it is installed only when `HTMLPage.pinViewportUnits` works (d-bug-110), and the measurement doesn't depend on the view's height (d-bug-064, 108), so a re-measure can't grow the view again; a test checks that a `100vh` mail stops re-measuring.
- **Alternatives:** Re-measure on a timer (rejected: work for every open message and a delay). KVO on the web view's content size (rejected: no public property on macOS).

## 02:24 — In the history, only a back-off sets an account aside {#d-bug-098-followup}

- **Status:** decided (review follow-up to d-bug-061 and d-bug-098)
- **Context:** With 061, an unreadable or result-less answer is `ServerBusy`; with 098, `ServerBusy` in the history set the whole account aside. A folder whose page is unreadable every time would then never be marked failed, come first on every run, and stall the account's other folders without a status, against the README ("A folder whose history fails is skipped, and the error stays under the window title").
- **Decision:** The history sets an account aside only for a `URLError` or a `ServerBusy` with a back-off (throttling). A `ServerBusy` without one (a page that isn't an Exchange answer) counts as that folder's failure: skipped for the session, with a status. The outbox keeps treating every `ServerBusy` as "not refused, wait".
- **Why:** Throttling is per account and passes; a broken page for one folder is that folder's problem.
## 02:27 — Body padding and placed content in the height {#d-bug-108}

- **Status:** decided
- **Context:** BUG-108. Body padding and `position: absolute` content were outside the measured box. The padding case was already fixed by measuring the root box (d-bug-064).
- **Decision:** `HTMLPage.measureScript` takes the larger of the root box's bottom and the body's top plus its `scrollHeight` and bottom margin (plus `scrollY`). Both terms are independent of the view's own height, so the view still shrinks when the window widens.
- **Not covered:** absolutely placed content with no positioned ancestor (its containing block is the window, not the body), so the body's `scrollHeight` doesn't count it: seen in a scratch run as 84 pt measured for 316 pt drawn. `documentElement.scrollHeight` would count it but never drops below the view's height. Making the body `position: relative` would count it but shift such content by the body's margins, which Mail doesn't do.

## 02:34 — Inline files that aren't pictures are listed, after the others {#d-bug-063}

- **Status:** decided
- **Context:** BUG-063. `listedAttachments` dropped everything with `IsInline` true. Only pictures are ever placed in the body (`inlineAttachmentIDs`), so an inline PDF (Apple Mail sends files inline) was neither listed nor shown. The existing tests pin that an inline picture in a text mail stays unlisted.
- **Decision:** An inline attachment that isn't a picture (`image/` type, or generic type with an image or unknown extension) is listed. Such files come after the non-inline ones, not in server order.
- **Why:** Attachments are fetched by position (`attachment(remoteID:index:)`) against the list stored with the body; appending keeps every stored position valid, inserting would open the wrong file for bodies loaded before.
- **Not covered:** an inline picture the body doesn't reference (a text mail with an inline photo) stays unlisted, as the pinned tests require.

## 02:35 — A queued change protects only the property it changes {#d-bug-075}

- **Status:** decided
- **Context:** BUG-075. While any change of a message was queued, `merge` kept its read state, flag and mailbox together and skipped the server's read changes for it: a queued read dropped a flag set on the phone, a queued flag or move dropped a read change.
- **Decision:** `merge` keeps per message only what its queued changes set: read state for `setRead`, flag for `setFlagged`, mailbox for a move or an invite answer, everything for an erase. The server's word stands for the rest. A page still doesn't bring back a message gone here with any change queued (d-bug-072).
- **Why:** Exchange keeps the properties separately and the outbox writes them separately (README); the guard exists so the server doesn't undo the user's change, which only needs that one property.

## 02:40 — A folder removed on the server takes its mail with it; the selection goes to the Inbox {#d-bug-077}

- **Status:** decided
- **Context:** BUG-077. `setRemoteFolders` replaced the tree only; the mail, sync position and selection of a folder deleted on the server stayed (in Flagged, search and on disk; a blank title when it was selected).
- **Decision:** A folder of the account's tree (restored from disk or read earlier) that the new folder list doesn't have is gone: its messages are removed (memory and disk), its sync token, completion and history notes are dropped, and if it was the selected mailbox, the account's Inbox is selected. When the list arrives while launch is still loading, the folder's stored mail loaded afterwards is left out and removed from disk.
- **Why:** README syncs "your own mail folders"; a folder that doesn't exist on the server has no mail. Folders moved into Deleted Items keep their ID and stay (BUG-025).
- **Alternatives:** Select All Inboxes (rejected: the Inbox of the same account is closer to where the user was). Keep the mail until the user acts (rejected: it can't be reached in the sidebar).
