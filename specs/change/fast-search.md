# Change spec: fast local search (SQLite FTS5)

Status: ready to implement · Written 2026-11-12 · Scope: local search only (server search is a separate change)

## Goal

Typing in the toolbar search field must never stall the window. Today every keystroke runs a substring scan over all
messages on the main actor: **386 ms per keystroke** in the debug build that `run.sh` makes, and 314 ms in release,
measured on the real 180k-message database. Replace that scan with a SQLite FTS5 query that runs off the main thread.
The behaviour users see stays the same, apart from the deliberate matching changes listed under "Matching semantics".

## Non-goals

- Server-side search (EWS `FindItem` + `QueryString`). That is a later change. Leave room for it but don't build it.
- Downloading message bodies for search. Only 49 of 180k stored messages have a body, so local search effectively
  covers headers and the server preview. That is accepted for now.
- Making the database the source of truth for the list and counts. That is a separate, larger change. This change
  touches only the search path.
- Search UI changes: no scope bar, no tokens, no suggestions.

## Current state (read these first)

- `Sources/MailModel/MailStore.swift`, `visibleMessages` (around line 148). When `searchText` is not empty, it filters
  all `messages` by `[subject, from.name, from.email, body].contains { $0.lowercased().contains(q) }`. Scope:
  - `inSearchScope` keeps only the selected account when an account mailbox is selected, and every account otherwise.
  - Trash and Junk are excluded.
  - Results are sorted by date, newest first.
  - The result is cached per `(revision, ListKey)`.
- `Sources/MailReplica/MessageViewer.swift:27` binds `.searchable(text: $store.searchText)`.
  `MessageListView` shows `ContentUnavailableView.search` when there are no results.
- `Sources/MailModel/MailDatabase.swift`:
  - One SQLite connection, opened with `SQLITE_OPEN_FULLMUTEX`, with WAL and `synchronous=NORMAL`.
  - Every call is serialised on one private `DispatchQueue`.
  - Table `messages(id TEXT PRIMARY KEY, account, mailbox, remote, date, read, flag, from_name, from_email, to_list,
    cc_list, subject, body, …, preview, …)`.
  - The only index is `(account, mailbox)`. There is no schema version.
  - Writes are `INSERT OR REPLACE` / `DELETE` in one transaction (`commit`).
- `Sources/MailReplica/AccountsSettings.swift`, `AppSetup`:
  - `loadMail` opens the DB off the main thread.
  - `saveChanges` writes changes in the background, every 15 s (after each `refresh()`) and on quit.
  - **The DB therefore lags memory by up to about 15 s.**
- Sample data (`MAIL_SAMPLE_DATA=1`, or no Exchange account) has no database. Unit tests build `MailStore` without a
  database. The existing search tests are `MailStoreTests.unreadFilterAndSearch` and `searchSpansAllMailboxesOfScope`.
- `to_list` and `cc_list` are stored as `name␟email␞name␟email` (U+001F and U+001E as separators).

## Measured baseline

From a `VACUUM INTO` copy of the real database: 180,029 messages, 914 folders, macOS SQLite 3.54 with `ENABLE_FTS5`.

| What | Result |
|---|---|
| In-memory substring search (current), per keystroke | 386 ms debug / 314 ms release |
| `LIKE '%meeting%'` over subject, from_name and preview | 79 ms |
| FTS5 `rebuild` over subject, from_name, from_email, to_list and preview | 1.19 s, about +80 MB on disk |
| FTS5 `MATCH 'rechnung*'` (count) | 0.4 ms |
| FTS5 join with `messages`, `ORDER BY date DESC LIMIT 50` | 6 ms |

The benchmark is a throwaway script, not in the repo. Its approach: load the rows into a struct like `Message`, then
time the passes.

## Design

### 1. Schema: FTS5 index kept in sync by triggers

In `MailDatabase.init`, after the existing `CREATE TABLE`s, add an external-content FTS5 table over `messages`:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
  subject, from_name, from_email, to_list, cc_list, preview, body,
  content='messages', content_rowid='rowid',
  tokenize='unicode61 remove_diacritics 2');
```

Use three triggers (`AFTER INSERT`, `AFTER DELETE`, `AFTER UPDATE` on `messages`) that apply the standard
external-content `INSERT INTO messages_fts(messages_fts, rowid, …) VALUES('delete', old.rowid, …)` / `INSERT` pairs.

Why triggers:
- The index is updated in the same transaction as the row, so it can never drift from the table.
- No change is needed in `commit` or `StoreChanges`.
- **Pitfall (verified 2026-11-12 with macOS sqlite3 3.54):** `commit` currently uses `INSERT OR REPLACE`. SQLite fires
  the DELETE trigger on REPLACE only when `recursive_triggers` is on, which it isn't by default. So the old row's FTS
  entry is never deleted, and the old subject word **still matches**.
  - **Required:** change `commit` to an UPSERT: `INSERT … ON CONFLICT(id) DO UPDATE SET <every column but id> =
    excluded.<column>`. It fires the UPDATE trigger, which deletes the old entry and inserts the new one. Verified: the
    old word gives 0 hits and the new word 1.
  - Test 6 below guards this.

`to_list` and `cc_list` hold U+001F and U+001E separators. `unicode61` treats them as separators, so no
preprocessing is needed. This was verified: the names and both address parts were found, and `muller` found
"Müller".

### 2. Migration for existing databases

- Add `PRAGMA user_version` as the schema version, currently 0 → 1.
- On open with `user_version < 1`: create the FTS table and the triggers, run
  `INSERT INTO messages_fts(messages_fts) VALUES('rebuild')`, then set `user_version = 1`, all in one transaction.
  This takes about 1.2 s at 180k messages.
- It already runs off the main thread, because `loadMail` opens the DB in `Task.detached`. **Do it after the Inbox
  has been read** so the first screen isn't delayed:
  - Split it into a separate `prepareSearch()` call that `loadMail` runs on the DB queue after `messages(notIn:)`.
  - Search falls back to the in-memory path (below) until it finishes.
- Also add the index `CREATE INDEX IF NOT EXISTS messages_date ON messages(date DESC)` for ordering the results. It
  is cheap and also helps the later "DB as truth" change.
- The import path (`importCache`) builds a fresh DB through `init`, so it gets the schema and triggers automatically.
  The rebuild then isn't needed there; set `user_version = 1` directly.

### 3. Query API on `MailDatabase`

```swift
/// IDs of stored messages matching `query`, newest first. Scope and Trash/Junk filtering is the caller's job.
public func search(_ query: String, accounts: Set<UUID>?, limit: Int = 2000) throws -> [Message.ID]
```

- **A second, read-only connection** (`SQLITE_OPEN_READONLY`) on its own serial queue, opened lazily.
  - WAL lets it read while the write connection commits.
  - Without it, a search would queue behind a large background write.
  - Close it in `deinit` with the main one.
- **Query building:** the user's text is never passed to `MATCH` as is.
  - Split on whitespace.
  - Drop empty terms.
  - Turn each term into an FTS5 string with a prefix: `"term"*`, doubling any `"` inside it.
  - Join the terms with spaces, which means AND.
  - Example: `Bob invoice` → `"Bob"* "invoice"*`. User input like `-`, `AND`, `(` or `"` can therefore never raise a
    syntax error.
- SQL:
  `SELECT m.id FROM messages_fts f JOIN messages m ON m.rowid = f.rowid WHERE messages_fts MATCH ?
  [AND m.account IN (…)] ORDER BY m.date DESC LIMIT ?`.
- **No Trash/Junk filtering in SQL.** The DB's mailbox may be up to 15 s stale. The store filters on its current
  in-memory state (see 4).
- The limit is 2000. If it is hit, the store sets `status` to `Showing the newest 2,000 results`. No paging is
  needed in this change.

### 4. `MailStore` integration

- New state:
  - `@ObservationIgnored var searcher: (@Sendable (String, Set<UUID>?) async throws -> [Message.ID])?`.
    `AppSetup` sets it to call `database.search` once `prepareSearch()` has finished.
  - `private(set) var searchHits: (query: String, ids: Set<Message.ID>)?`.
- **`visibleMessages` while searching:**
  - If `searcher == nil` (sample data, tests, DB not ready or failed), keep today's in-memory substring path
    unchanged. The existing tests keep passing as they are, and sample mode keeps working.
  - Otherwise, use `searchHits` for the current query. Make **one** pass over `messages`, keeping messages whose
    `id` is in `hits` and which pass today's checks: `inSearchScope`, not Trash, not Junk. Then sort by date.
    - This uses **current in-memory state**, so a message deleted or moved a second ago disappears from the results
      at once, even though the DB still has it in its old mailbox.
    - Cost: one O(N) pass with a `Set` lookup, about 20–40 ms debug, once per result set, not per keystroke.
      That's acceptable until the list itself moves to the DB.
  - While the hits for the current query haven't arrived yet, keep showing the previous result list. Don't flash an
    empty list or "No Results".
- **Running the query:** add `func searchTextChanged()`, called from `searchText`'s `didSet` (or from the view's
  `.onChange`; pick one).
  - Cancel the running search task and start a new one.
  - It sleeps **150 ms** (debounce), then awaits `searcher(query, scopeAccounts)` off the main actor.
  - On return, it applies the hits only if `searchText` still equals the query (a generation check).
  - Errors: set `status` and fall back to the in-memory path for this query.
- **Staleness:** the DB lacks anything that arrived or changed in the last ≤15 s, such as new mail or a body that was
  just loaded.
  - Accept this, and narrow the window: after each successful background save (`saveChanges` gets a completion
    callback next to `failed`), if `searchText` is not empty, run the current query again silently.
  - Document the lag in the README.
- Clearing the search field drops `searchHits` and cancels the task.

### 5. Matching semantics (deliberate changes, document them in the README)

| Before | After |
|---|---|
| Substring anywhere (`eting` matches "meeting") | Word prefix (`meet` matches "meeting"; `eting` doesn't) |
| Fields: subject, sender name and address, body | Also To, Cc and the server preview |
| Multiple words: one substring including the spaces | Every word must match (AND), in any field |
| Case-insensitive | Case- and diacritic-insensitive (`muller` matches "Müller") |

Mail.app and Outlook also match word prefixes, so this is closer to the original. Email addresses tokenise on `@` and
`.`, so `gartner` finds `till.gartner@…`.

## Tests (write first, see that each fails, then implement)

`Tests/MailModelTests/MailDatabaseTests.swift`, against a temp-file DB as the existing tests do:

1. A stored message is found by a subject word, a sender name, a sender address part, a To address, a preview word
   and a body word.
2. Prefix: `rech` finds "Rechnung". A mid-word fragment does not.
3. Diacritics and case: `muller` finds "Müller".
4. Several words are ANDed across fields: `bob invoice` finds `from: Bob, subject: Invoice` but not
   `from: Bob, subject: Lunch`.
5. Hostile input such as `"`, `-x`, `AND (`, `*` and a lone `"` returns results or an empty list, never throws.
6. **Write-back keeps the index exact:**
   - Writing a message, then writing it again with a new subject, finds it by the new word and **not** by the old
     one. This catches the `INSERT OR REPLACE` trigger pitfall.
   - A removed message is no longer found.
7. Results are ordered newest first, and `limit` is respected.
8. `accounts` scope returns only that account's messages.
9. **Migration:** a DB created without FTS, with `user_version` 0 and rows inserted, is opened. After
   `prepareSearch()`, existing rows are searchable and `user_version == 1`. Opening it again doesn't rebuild.
10. The read connection can search while a write transaction is open on the write connection, without
    `SQLITE_BUSY`.

`Tests/MailModelTests/MailStoreTests.swift`:

11. The existing search tests still pass unchanged (the in-memory path with no searcher).
12. With a fake `searcher` that returns fixed IDs:
    - A hit that is now in Trash, or in another account while an account mailbox is selected, is not shown.
    - A hit unknown in memory is ignored.
    - The order is by date.
13. A stale reply is ignored: query "a" is slow and query "ab" fast, so only "ab"'s hits are applied. Drive this with
    controllable continuations, not sleeps.
14. While hits for a new query are pending, `visibleMessages` returns the previous results, not an empty list.

The fake searcher in 12–14 is a test double for the injected closure, not a mock of `MailDatabase`. If you consider
it a mock, ask the user first: their rule is "never mock without permission". The alternative is a real temp DB in
these tests too.

Run the tests as `CLAUDE.md` says: two separate top-level Bash calls, then check the test count.

## Acceptance

- All tests above pass. No existing test was changed to make it pass.
- On the real database (use a `VACUUM INTO` copy for any measurement, never the live file), measured in the
  debug build:
  - Typing a word into search keeps the window responsive: no main-thread block over 50 ms per keystroke.
  - Results appear within 250 ms of the last keystroke for common words (150 ms of that is the debounce).
  - Measure by logging timings around the search task and the `visibleMessages` pass. Report the numbers.
- The first launch after the update shows the Inbox no later than before. The FTS rebuild happens afterwards, and
  search works through the fallback meanwhile.
- Delete a message that is in the results: it disappears from them at once.
- Visual check with the `MAIL_SNAPSHOT` hook is not needed, because nothing changes visually. If you add a
  "Showing the newest 2,000 results" status, read a snapshot to verify it.
- README: update the **Search** bullet (around line 35) and the storage paragraph (around line 77) with word-prefix
  matching, the extra fields, the lag of up to 15 s for newly arrived mail, and the 2,000-result cap.

## Risks and notes

- **DB size:** about +80 MB at 180k messages with previews. If bodies are later downloaded in bulk, the index grows
  with them. Consider `detail=column` or leaving out `body` then.
- **Write cost:** triggers add FTS work to every write. History sync writes in batches every 15 s, so measure one
  large history save before and after. Expect it to stay well under a second off the main thread. If not, keep FTS
  maintenance out of the triggers and do it in `commit`.
- **Server search later:** with fewer than N local hits, or explicitly ("Search on Exchange"), query EWS
  `FindItem` + `QueryString` per folder.
  - It is AQS, Shallow only, and returns at most 250 results per query.
  - It searches bodies through the server index.
  - Results can't be merged by ID from the DB alone. Match on `remoteID`.
  - Out of scope here. The `searcher` closure is the seam where it plugs in.
