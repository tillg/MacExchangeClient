---
title: "Domain model"
created: 2026-11-12
edited: 2026-11-13
---

# Domain model

The value types in `Sources/MailModel/Models.swift`, `Invite.swift` and `MailBackend.swift`. All are `Sendable`
structs or enums; most are `Codable`, because the outbox and the old `Cache.json` store them as JSON. How they are
stored: [storage.md](storage.md). How EWS fills them: [ews.md](ews.md).

## Account and mailboxes

- **`Account`**: `id` (UUID), `name` (for EWS accounts the email address, trimmed; "Exchange" if blank), `address` (the email), `isServer` (true for
  accounts set up in Settings, false for sample data). The Exchange settings
  (`username`, `server`) are in `ExchangeAccount` (`Sources/EWS/ExchangeAccount.swift`), persisted in UserDefaults.
- **`MailboxKind`**: a string wrapper, so stored values stay readable as kinds are added. Standard kinds, in sidebar
  order: `inbox`, `drafts`, `sent`, `junk`, `trash`, `archive`. A user folder is `folder:<server folder ID>`;
  `isStandard` tells them apart. Title and SF Symbol exist for the standard ones; a folder's name comes from
  `MailStore.name(of:in:)`, its symbol is `folder`.
- **`Folder`**: a user folder in an account's tree: `box`, `name`, `parent` (a `MailboxKind`, standard or folder; nil
  at the top). Built from `RemoteFolder`s (`role`, server `id`, `totalCount`, `name`, `parent`).
- **`SmartMailbox`**: `allInboxes`, `vip`, `flagged`, `unread`. **`MailboxRef`**: `.smart(SmartMailbox)` or
  `.account(UUID, MailboxKind)` — what the sidebar selects.
- **`FlagColor`**: red, orange, yellow, green, blue, purple, gray. Exchange only knows flagged/not flagged.
- **`MailCategory`** (primary, transactions, updates, promotions): still stored, no longer shown.

## Contact

`Contact(name, email)`. EWS list summaries carry display names only (`email` empty) until the body loads.

- `initials`: the first letters of the first two parts of `name` split on any whitespace (space, tab, no-break
  space), each uppercased and cut to one letter (ß → S, ﬀ → F), so at most two.
- `parseList(_:)` parses what the user types in To/Cc:
  1. Split on `,` and `;`, except inside double quotes (where `\"` and `\\` are escapes) or inside `<>`.
     If a quote or `<` is never closed (or a `<` opens inside `<>`), the split ignores quotes and `<>` instead,
     so no recipient after it is swallowed.
  2. Trim blanks and line breaks from each part; skip empty parts.
  3. A part with no `@`, `<` or `"`, followed by a part with `<`, is joined to it with ", ": Outlook's unquoted
     `Doe, John <john@x.com>` is one recipient named "Doe, John".
  4. If the part has `<` before `>` (the last of each): the name is the text before `<`, trimmed, with surrounding
     double quotes removed and escapes resolved (if empty, the address); the address is the text between them,
     trimmed of blanks and line breaks.
  5. Otherwise name and address are both the whole part.

## Message

| Field | Meaning |
|---|---|
| `id` | Local UUID, kept across syncs (merged by `remoteID`) |
| `accountID`, `mailbox` | Where it is; set by the store, not by the backend |
| `from`, `to`, `cc` | Contacts; summaries have names only |
| `subject`, `body`, `date` | `body` is plain text (empty until loaded); `date` is the received time |
| `isRead`, `flag`, `isVIP`, `category` | State; VIP comes only from sample data |
| `attachments`, `hasAttachments` | `hasAttachments` is known from the summary; the list arrives with the body |
| `remoteID` | The server item ID; nil for local (sample or locally sent) messages |
| `serverPreview` | The server's preview, shown until the body is loaded |
| `bodyLoaded`, `htmlChecked` | Body fetched; fetched by a version that asks for HTML (nil in old data) |
| `isInvite`, `invite` | Known to be a meeting item from the summary; invite details from the body |
| `html` | The HTML body if the sender sent one |
| `conversationID` | Exchange `ConversationId`, for [conversations](functional.md#message-view-and-conversations) |

- `needsBody`: not loaded, or a server message whose body was loaded before HTML was asked for, whose attachments
  lack a size, or whose invite has no `isCancellation` yet. Such bodies are fetched again when shown.
- `preview` and `hasRemoteContent`: [rendering.md](rendering.md).

## Attachment

`Attachment(name, size?, contentType?)`: metadata only; content is fetched when opened, by position in the list.
`fileName` replaces `/` with `:`, removes NUL and bidi controls (U+200E/F, U+061C, U+202A–202E, U+2066–2069) and turns other control characters into a blank (BUG-193); an empty, `.` or `..` name becomes "Attachment". A name over
255 UTF-8 bytes is cut at a whole character to fit, keeping its extension (when at most 32 bytes); saving under a free
name ("name 2.pdf") shortens the same way (`Attachment.fileName(_:ending:)`). An attached
message (EWS `ItemAttachment`) is listed as `<name>.eml` with type `message/rfc822`.
Decoding also accepts a bare string as the name (size and type nil), the form builds up to b75308d wrote into
`Cache.json` and outbox rows; encoding always writes the object.

## Draft

A message being written (`Draft`, `Codable`). A compose window is opened with a `ComposeWindow` (the draft plus a
new `id` per request), so equal drafts (two New Messages, two replies to one message) still open separate windows.

- `accountID`, `to`, `cc` (free text, parsed with `Contact.parseList` when sent), `subject`, `body`.
- `attachments: [DraftAttachment]` (`name`, `contentType`, `data`, `fromOriginal`). Stored as an optional so older
  drafts decode.
- **File marks:** `body` holds U+FFFC (`Draft.fileMark`) where a file is placed; the k-th mark is `attachments[k]`.
  Files beyond the marks were added without a place. `text` is `body` without marks — what is sent as plain text.
  Marks are counted by Unicode scalar (`text`, `placedPictures`, `html`, `excludeOriginalAttachments`, the compose
  text view's load), as a combining character after a mark joins it into one `Character`.
- `placedPictures`: indices of attachments that have a mark and are `image/jpeg`, `image/jpg`, `image/png` or
  `image/gif` (case-insensitive); only these go inline.
- `original`: the message replied to or forwarded, when it has attachments. `loadingOriginal`: set while its files
  still have to be added. `inviteAnswer`: makes Send answer an invite instead of sending mail.
- `hasChanges(since:)` compares account, To, Cc, subject, `body` without the marks of the original's files (so
  moving a placed file is a change) and the non-original files.
- `excludeOriginalAttachments()` removes original files and their marks.
- `estimatedSize`: UTF-8 bytes of text (the body's bytes minus 3 per mark, found with `memchr`; no copy of the
  body) and subject plus, per file, base64 size + a line break per 76 chars + 300.
- `html(contentID:)`: [rendering.md](rendering.md#html-of-sent-mail).
- `IncludeAttachments`: never, ask, whenAddingRecipients, always. `ReplyKind`: reply, replyAll, forward.

## Invite

- **`Invite`**: `start`, `end` (absolute), `location`, `isAllDay`, `organizer`, `required`, `optional`, the local
  `response` and `reply`, `isCancellation` (nil in older data).
- `isOwnEntry` matches a calendar event with identical start, end and subject; `conflicts(in:subject:)` returns
  timed, non-free events (not the own entry) that overlap, sorted by start.
- **`InviteResponse`**: accept, tentative, decline. **`InviteReply`**: response, `comment`, `send` (false = "Do Not
  Send a Response"), `proposedStart`/`proposedEnd`. **`InviteAnswer`**: the compose window's link to the invite.
- **`CalendarEvent`** (subject, start, end, isAllDay, `BusyStatus`) and **`DayLayout.columns`**, which puts
  overlapping timed events into side-by-side columns. An event takes at least `DayLayout.shortest` (20 min) there,
  so a 0-minute (or end-before-start) entry never shares a column with one starting at the same time.
  **`DayLayout.hours(for:events:calendar:)`**: 8–18, widened to the invite (unless all-day) and the timed events;
  a time on an earlier day counts as 0 h, on a later day as 24 h; capped at 24.

## Server changes

- **`ServerChange`** (`Codable`): `setRead(ids, Bool)`, `setFlagged(ids, Bool)`, `move(ids, to: MailboxKind)`,
  `delete(ids)`, `send(Draft)`, `saveDraft(Draft)`, `respond(id, InviteResponse)` (older form, still decoded),
  `reply(id, InviteReply)`, `removeFromCalendar(id)`. IDs are `remoteID`s. `renamed(_:)` swaps IDs after a move.
- **`PendingChange`**: `id`, `account`, `change`, and `previous` — the messages as they were, to undo a refused
  change (for read, flag and move changes without body, HTML, attachment list and preview; erases and invite
  answers keep whole messages). The ordered list of these is the store's `outbox` ([architecture.md](architecture.md#writing-to-the-server-the-outbox)).
- **`SyncResult`**: `upserts`, `deletedRemoteIDs`, `readChanges`, `token`, `more`. **`MessageBody`**: text,
  attachments, from/to/cc, invite, html. **`AuthenticationError`**: "Sign-in failed"; pauses the account.
