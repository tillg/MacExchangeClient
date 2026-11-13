---
title: "Search"
created: 2026-11-12
edited: 2026-11-13
---

# Search

The toolbar search field (`.searchable` in `Sources/MailReplica/MessageViewer.swift`) binds to
`MailStore.searchText`. Search is local only; nothing asks the server. There are two paths: a scan of memory and a
query of the SQLite FTS5 index. Index schema: [storage.md](storage.md#search-index).

## Which path runs

`MailStore.visibleMessages` decides per call, with `typed` = `searchText` trimmed of spaces and lowercased:

- `typed` empty: no search; the mailbox list.
- **Memory path** when `searcher == nil` — sample data, unit tests, the database not opened, its index not built
  yet (an older database is indexed by `prepareSearch()` after all mail has loaded), or loading failed — or when the
  index failed for exactly this query (`fallbackQuery == typed`).
- **Index path** otherwise. `AppSetup.enableSearch` sets `searcher` to call `MailDatabase.search` once the database
  is ready. When `searcher` is set while text is typed, the current query is sent to the index at once and memory
  keeps answering until that answer is in.

## Memory path

- Fields: `subject`, `from.name`, `from.email`, every To and Cc name and address, `serverPreview`, `body`, joined
  with line breaks and folded (case and diacritics) once per message.
- Match: the typed text is split at whitespace; every word (folded the same way) must occur in that text, in any
  order and any field. Unlike the index, a word also matches inside a word (`report` finds "Misreported"), see
  DECISIONS.md#d-bug-052. A message whose body isn't loaded is found by its headers and server preview.
- Scope: see below. Results newest first. Runs on the main actor on every recomputation of the list.

## Index path

1. `searchTextChanged()` (from `searchText.didSet`, and when the selected mailbox moves to another search scope)
   cancels the running search task, waits 150 ms (`searchDebounce`), then `runSearch`.
2. `runSearch` calls `searcher(query, scope)` on a detached task, then filters the hits against a snapshot of
   `messages` (`hitList`, in 8 parallel chunks). The answer is dropped if the task was cancelled, or the text or
   scope changed meanwhile.
3. On success: `searchHits = (query, ids)`; the list is cached for the current revision. If the index returned
   2,000 IDs, `status` becomes "Showing the newest 2,000 results"; otherwise that notice, or a "Search failed"
   notice, is cleared.
4. On error: `fallbackQuery = query` (memory answers this query), `searchHits` is cleared and `status` is "Search failed: …".
5. After every successful background save, `searchAgain()` runs the current query again without debounce, so mail
   written in the last ≤15 s becomes findable.
6. Clearing the field cancels the task, drops the hits and the fallback, and clears the 2,000 notice or a "Search
   failed" notice. Any other status stays.

What the list shows meanwhile: the latest answer's results (the previous query's while the next is on its way,
filtered by the scope that answer was asked for, so selecting another account's mailbox keeps them until the new
account's answer arrives), also when that answer came from memory (`memoryQuery`, the query of the memory scan last shown). Before the first
answer of a search — no hits, no memory results — the list shows the selected mailbox's normal content, and
`awaitingSearchResults` is true.

### Query and matching (`MailDatabase.search`, `matchExpression`)

- The text (already lowercased by the store), with NUL characters as spaces, is split on whitespace; words without any letter or digit are dropped.
  No word left: no results.
- Each word becomes an FTS5 string with prefix star: `"word"*`, with `"` doubled. Words are joined by spaces: all
  must match (AND), each in any indexed field. User input is never FTS syntax.
- A word with a Han, hiragana or katakana character (`isCJK`) isn't sent to the index (the tokenizer can't split
  scripts written without spaces): it must occur anywhere in one of the indexed columns (`LIKE '%word%'`, `%`, `_`
  and `\` escaped). Without other words the query scans `messages` newest first (about 0.4 s for 180,000 synthetic
  rows with 3 KB bodies and no hit); with other words it narrows the index's hits.
- A word with a Greek vowel becomes an OR group (`greekVariants`): the word without tonos (ΐ, ΰ as ι, υ), and the
  same with the tonos on each vowel in turn, since the tokenizer keeps Greek accents and a Greek word has at most
  one. So `καλημερα` finds "Καλημέρα" and `ελληνικά` finds "ΕΛΛΗΝΙΚΑ". Dialytika (ϊ, ϋ) in the text are not matched
  by a word typed without them.
- Tokenizer `unicode61 remove_diacritics 2`: case- and accent-insensitive (`muller` finds "Müller"); punctuation
  splits words, so `gartner` finds `till.gartner@…`; matching is by word prefix (`meet` finds "meeting", `eting`
  doesn't).
- Indexed columns: `subject`, `from_name`, `from_email`, `to_list`, `cc_list`, `preview` (server preview), `body`
  (plain text, only when loaded). The HTML body isn't indexed.
- SQL: join `messages_fts` with `messages`, `mailbox NOT IN ('trash', 'junk')`, optional `account IN (…)`,
  `ORDER BY date DESC LIMIT 2000`. Trash and Junk go before the limit, so their hits can't crowd out real ones.
- Reads use a separate read-only connection on its own queue, so a background write doesn't block a search.

### Staleness

The database lags memory by up to one save interval (15 s). Hits are matched against memory: a message deleted
or moved since is shown where it is now, or not at all if gone. Mail that arrived or changed (subject, body loaded)
since the last save is missing or matched by its old text until the save after it. A message taken out of Trash or
Junk since the last save isn't found by the index until that save.

## Scope (both paths)

- An account mailbox is selected: only that account. A smart mailbox: all accounts. The mailbox itself doesn't
  limit the search.
- Messages in `.trash`, in a folder inside Trash (any depth, from the account's folder tree) or in `.junk` are left
  out (memory: in the filter; index: `trash` and `junk` in SQL before the limit, then all three again in `hitList`
  against memory). The SQL doesn't know the folder tree, so hits in folders inside Trash count toward the 2,000 limit
  before `hitList` drops them. User folders below Junk are searched.
- The unread filter is ignored while searching.
- Results are sorted by date, newest first.

## Limits

- At most 2,000 IDs from the index, Trash and Junk already left out; the in-memory re-check (moved since the last
  save, account) can show a few fewer.
- No paging, no server search, no search of HTML-only text, no search tokens, scopes or suggestions.
- Server search, when it comes, plugs in at the `searcher` closure: EWS `FindItem` + `QueryString` (AQS) per folder,
  Shallow only, at most 250 results per query, searches bodies through the server index; its results match local
  messages by `remoteID`, not by local ID.
- No results: `ContentUnavailableView.search` ("No Results for …") in the list; not while `awaitingSearchResults`
  (an empty list then shows nothing).
