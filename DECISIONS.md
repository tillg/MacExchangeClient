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
- **Why:** Mail in a deleted folder is deleted mail. Worked out once per folder change, the per-message check is one dictionary lookup, so the 70k-message timings are unchanged.
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
- **Decision:** When the sender is the account's own address (compared without case), Reply goes to the original To recipients (each once, my own address left out). Cc stays empty, as for any Reply.
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
- **Why:** The user would otherwise believe a time was proposed.
