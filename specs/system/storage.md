---
title: "Storage"
created: 2026-11-12
edited: 2026-11-13
---

# Storage

What is kept on disk and how. Code: `Sources/MailModel/MailDatabase.swift` (SQLite), `MailCache.swift` (the old JSON
cache), `Sources/MailReplica/AccountsSettings.swift` (`AppSetup`: when it is read and written). When saving runs:
[architecture.md](architecture.md#saving-to-disk).

## What lives where

| Data | Where |
|---|---|
| Exchange mail, sync positions, folder trees, outbox | `~/Library/Application Support/MailReplica/Mail.sqlite` (+ `-wal`, `-shm`) |
| Accounts (email, username, server, id) | UserDefaults key `exchangeAccounts`, JSON |
| Passwords | Keychain generic password, service `MailReplica-EWS`, account = username |
| Settings | UserDefaults (`@AppStorage`): `showConversations`, `remoteImages`, `includeAttachmentsWithReplies`, `showContactPhoto` |
| Opened attachments | `$TMPDIR/Mail Downloads/<message id>/<index>/<file name>`, quarantined |
| Files of drafts kept after a failed send | `files` table of `Mail.sqlite` (sample data: memory only) |
| Inline images, calendar days, MailTips size | Memory only |
| Old cache | `Cache.json` in the same folder, renamed `Cache.json.imported` after import |

The folder is created with mode 0700 and a new database file with 0600. Sample data is never stored. Only messages
of server accounts (accounts with a backend or restored sync state) are written.

## Schema

One connection, `journal_mode=WAL`, `synchronous=NORMAL`.

- **`messages`**: one row per message.

  | Column | Content |
  |---|---|
  | `id` TEXT PK | local UUID |
  | `account`, `mailbox` | UUID string; `MailboxKind.rawValue` (`inbox`, `folder:<id>`, …) |
  | `remote` | `remoteID`, nullable |
  | `date` | REAL, seconds since 2001-01-01 (`timeIntervalSinceReferenceDate`) |
  | `read` | 0/1 |
  | `flag` | `FlagColor` raw value or NULL |
  | `from_name`, `from_email` | sender |
  | `to_list`, `cc_list` | contacts, encoded as below |
  | `subject`, `body` | plain text |
  | `category` | `MailCategory` raw value |
  | `bits` | 1 = VIP, 2 = has attachments, 4 = body loaded |
  | `attachments` | encoded as below |
  | `preview` | `serverPreview` |
  | `invite` | BLOB, `Invite` as JSON |
  | `html` | HTML body |
  | `is_invite`, `html_checked` | 0/1/NULL |
  | `conversation` | Exchange `ConversationId` |

  Indexes: `messages_mailbox(account, mailbox)`, `messages_date(date DESC)`.
- **`sync`**: `(account, mailbox)` PK, `token` (EWS SyncState), `complete` 0/1.
- **`folders`**: `account`, `box`, `name`, `parent`, `position` (the order to restore).
- **`outbox`**: `position` PK, `change` BLOB = `PendingChange` as JSON. Rows that don't decode are skipped on read. Rows
  whose `previous` messages hold attachments as plain names (older builds) decode. `inFlight` (optional, absent in
  older rows) marks a send whose request may have gone out.
- **`files`**: `(message, position)` PK, `data` BLOB: the file content of messages kept only on this Mac (a send or
  draft Exchange refused, kept in Drafts). Read by `meta()`; rows go with their message. Created with
  `CREATE TABLE IF NOT EXISTS`, so older databases get it on open.

### Encodings

- Contacts: `name U+001F email`, joined with `U+001E`. Decoding splits on U+001E, then on the first U+001F; a part
  without U+001F gets an empty email. Names or addresses containing these characters are corrupted.
- Attachments: `name U+001F size U+001F contentType`, joined with U+001E; empty size or type means nil. Older rows
  hold only names.
- Text is bound and read with its byte count, so a NUL character is stored like any other. Rows written before
  this hold the text up to the first NUL and read as they did.

### Search index

`messages_fts`: FTS5, external content (`content='messages'`, `content_rowid='rowid'`), tokenizer
`unicode61 remove_diacritics 2`, columns `subject, from_name, from_email, to_list, cc_list, preview, body`. Three
triggers keep it exact in the same transaction: after insert, after delete, and after update only when one of those
columns changed. U+001E/U+001F are word breaks for the tokenizer. How it is queried: [search.md](search.md).

## Writing

- `write(_:)` (synchronous, used on quit) and `writeInBackground(_:done:failed:)` run `commit` on the serial queue.
- `commit`: one `BEGIN IMMEDIATE` transaction. Messages are upserted with `INSERT … ON CONFLICT(id) DO UPDATE SET`
  every column (not `INSERT OR REPLACE`, which wouldn't fire the delete trigger). Removed IDs are deleted. `sync`,
  `folders` and `outbox`, when present in the batch, are replaced entirely. Any error rolls the batch back.
- What goes in a batch: `MailStore.takeChanges()` — IDs changed or added since the last batch (picked from a snapshot
  off the main thread), removed IDs, and sync/folders/outbox if they changed. Failed batches are re-marked
  (`retry`) and go with the next one.

## Reading

`meta()` (folders, sync states, outbox), `messages(in:)` / `messages(notIn:)` by `(account, mailbox)`, `messages()`,
`count()`. Rows with an invalid UUID are skipped; an undecodable invite becomes nil.

## Migrations

There is no general migration framework. On open:

1. `CREATE TABLE IF NOT EXISTS` for all tables.
2. **Conversations:** if `messages` lacks `conversation` (checked with `pragma_table_info`), the column is added and
   every sync state is reset (`token = NULL, complete = 0`), so every folder syncs from scratch and existing messages
   learn their conversation. Merging keeps local IDs, bodies and flag colours. Mail a folder's complete re-sync
   doesn't list is removed ([architecture.md](architecture.md#reading-from-the-server)).
3. **Search index:** `PRAGMA user_version` is the search schema version (now 1). A new database gets the index and
   version 1 at once. An older one (version 0) gets it in `prepareSearch()`, called after all mail is in memory: one
   transaction creating table, triggers and date index, `rebuild`, then `user_version = 1`. On failure it rolls back
   and the status says "Couldn't build the search index"; memory search stays.

## Import from `Cache.json`

Runs when `Mail.sqlite` doesn't exist (`MailDatabase.importCache`); the sidebar shows "Updating Mail Storage…".

1. No `Cache.json`: nothing to import; a new empty database is created by the normal path.
2. Decode the cache off the main thread. If it can't be decoded, it is renamed to `Cache.json.unreadable`
   (`.unreadable-2`, … if taken; never deleted), an empty database is created and returned, and the status says the
   old cache couldn't be read and names the kept file. Mail is then downloaded again from the server.
   Caches from builds whose attachments were plain names decode (see `Attachment` in [domain-model.md](domain-model.md)).
3. `store.restore(cache)`: messages (skipping known `remoteID`s), sync tokens, outbox, complete folders, folder trees.
   Then `forgetSyncPositions()`: the cache predates conversations, so, as for an older database, every folder syncs
   once more from the start and the imported mail learns its conversation.
4. Write everything into `Mail.sqlite.importing` (old leftovers removed first) and check the row count.
5. Refuse if `Mail.sqlite` exists meanwhile; else move the temp file into place and reopen it.
6. Rename `Cache.json` to `Cache.json.imported`. Interrupted before that, the next launch imports again.

`MailCache` (one JSON file with, per account, messages, sync tokens by mailbox, outbox, complete folders and folders)
is still written by `MailStore.cache()` only for tests and tools; the app no longer saves it.
