---
title: "Decisions"
created: 2026-11-12
edited: 2026-11-12
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
