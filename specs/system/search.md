---
title: "Search"
created: 2026-11-12
edited: 2026-11-12
---

# Search

The toolbar search field (`.searchable` in `Sources/MailReplica/MessageViewer.swift`) binds to
`MailStore.searchText`. Search is local only; nothing asks the server. There are two paths: a scan of memory and a
query of the SQLite FTS5 index. Design history: [../change/fast-search.md](../change/fast-search.md). Index schema:
[storage.md](storage.md#search-index).

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

- Fields: `subject`, `from.name`, `from.email`, `body` (each lowercased).
- Match: the whole typed text, spaces included, as one substring (`contains`). Not To, Cc or the server preview; no
  splitting into words, no accent folding. A message whose body isn't loaded is found only by header fields.
- Scope: see below. Results newest first. Runs on the main actor on every recomputation of the list.

## Index path

1. `searchTextChanged()` (from `searchText.didSet`, and when the selected mailbox moves to another search scope)
   cancels the running search task, waits 150 ms (`searchDebounce`), then `runSearch`.
2. `runSearch` calls `searcher(query, scope)` on a detached task, then filters the hits against a snapshot of
   `messages` (`hitList`, in 8 parallel chunks). The answer is dropped if the task was cancelled, or the text or
   scope changed meanwhile.
3. On success: `searchHits = (query, ids)`; the list is cached for the current revision. If the index returned
   2,000 IDs, `status` becomes "Showing the newest 2,000 results"; otherwise that notice is cleared.
4. On error: `fallbackQuery = query` (memory answers this query) and `status` is "Search failed: …".
5. After every successful background save, `searchAgain()` runs the current query again without debounce, so mail
   written in the last ≤15 s becomes findable.
6. Clearing the field cancels the task, drops the hits and the fallback, and clears the 2,000 notice (not a "Search
   failed" notice).

What the list shows meanwhile: the latest answer's results (the previous query's while the next is on its way).
Before the first answer of a search — no hits yet — the list shows the selected mailbox's normal content.

### Query and matching (`MailDatabase.search`, `matchExpression`)

- The text (already lowercased by the store) is split on whitespace; words without any letter or digit are dropped.
  No word left: no results.
- Each word becomes an FTS5 string with prefix star: `"word"*`, with `"` doubled. Words are joined by spaces: all
  must match (AND), each in any indexed field. User input is never FTS syntax.
- Tokenizer `unicode61 remove_diacritics 2`: case- and accent-insensitive (`muller` finds "Müller"); punctuation
  splits words, so `gartner` finds `till.gartner@…`; matching is by word prefix (`meet` finds "meeting", `eting`
  doesn't).
- Indexed columns: `subject`, `from_name`, `from_email`, `to_list`, `cc_list`, `preview` (server preview), `body`
  (plain text, only when loaded). The HTML body isn't indexed.
- SQL: join `messages_fts` with `messages`, optional `account IN (…)`, `ORDER BY date DESC LIMIT 2000`.
- Reads use a separate read-only connection on its own queue, so a background write doesn't block a search.

### Staleness

The database lags memory by up to one save interval (15 s). Hits are matched against memory: a message deleted
or moved since is shown where it is now, or not at all if gone. Mail that arrived or changed (subject, body loaded)
since the last save is missing or matched by its old text until the save after it.

## Scope (both paths)

- An account mailbox is selected: only that account. A smart mailbox: all accounts. The mailbox itself doesn't
  limit the search.
- Messages whose `mailbox` is exactly `.trash` or `.junk` are left out (memory: in the filter; index: in `hitList`,
  after the SQL limit). User folders below Trash or Junk are searched.
- The unread filter is ignored while searching.
- Results are sorted by date, newest first.

## Limits

- At most 2,000 IDs from the index, taken before the Trash/Junk and account-in-memory filters, so fewer may show.
- No paging, no server search, no search of HTML-only text, no search tokens, scopes or suggestions.
- No results: `ContentUnavailableView.search` ("No Results for …") in the list.
