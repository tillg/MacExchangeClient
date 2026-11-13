---
title: "EWS backend"
created: 2026-11-12
edited: 2026-11-13
---

# EWS backend

How the app talks to on-prem Exchange. Code: `Sources/EWS/EWSBackend.swift` (requests and parsing),
`EWSClient.swift` (HTTP, auth, XML), `ExchangeAccount.swift` (account, URL, Keychain). The store side (when each call
is made, retries, undo): [architecture.md](architecture.md). Types: [domain-model.md](domain-model.md).

## Account and URL

- `ExchangeAccount`: `id`, `email`, `username` (`DOMAIN\user`), `server`; saved as JSON in UserDefaults
  (`exchangeAccounts`). Its `Account` is named after the email (trimmed; "Exchange" if blank), with the email as address.
- `ewsURL`: `server` trimmed of blanks and line breaks; a leading `https://` or `http://` (any case), trailing `/`
  and a trailing `/EWS/Exchange.asmx` (any case) are dropped, then it becomes `https://<rest>/EWS/Exchange.asmx`
  (`http` is upgraded, never used). A rest whose path ends in `.asmx` is used as given; a path prefix in front of
  the standard path is kept. Nil when the rest is empty, starts with `/` or contains blanks.
- `backend()`: nil without a valid URL or without a Keychain password for `username` (service `MailReplica-EWS`).
- Sign In (Settings ▸ Accounts) calls `folders()` with the typed or stored password before saving anything.

## Transport (`EWSClient.call`)

- POST, `text/xml; charset=utf-8`, 60 s timeout, ephemeral `URLSession`. SOAP 1.1 envelope with
  `RequestServerVersion Exchange2013_SP1`; the operation goes into `soap:Body` as a string.
- Authentication per request: Negotiate is rejected (so the server falls back to NTLM, as Kerberos fails off the
  domain); Basic and NTLM get the credential once; a second challenge cancels and the call throws
  `AuthenticationError`. HTTP 401 also throws it. The store then pauses the account.
- Responses: every numeric character reference (decimal or hex) whose value isn't an XML 1.0 `Char` (C0 controls
  except tab/LF/CR, surrogates `D800`–`DFFF`, `FFFE`, `FFFF`, past `10FFFF`) becomes `&#xFFFD;` before parsing.
  A body that isn't an Exchange answer throws `ServerBusy` (nothing was refused): unparsable ("Unreadable EWS
  response (N bytes, HTTP s)") or without any `ResponseCode` (an empty SOAP body, a proxy's well-formed error page:
  "The server's answer holds no Exchange result"), strict or not. A SOAP `Fault` `ErrorServerBusy` (throttling)
  throws `ServerBusy` with its `BackOffMilliseconds` as `retryAfter`; any other `Fault` throws its
  `ResponseCode`/`faultstring`. With `strict` (the default), the first `ResponseCode` other than
  `NoError` throws with its `MessageText`.
- XML access ignores namespaces. `text(name)`/`first(name)` search all descendants, `child(name)` direct children.
- Request text is escaped with `xmlEscape` (`&`, `<`, `>`, `"`). Characters XML 1.0 forbids (U+0000–U+0008, U+000B,
  U+000C, U+000E–U+001F, U+FFFE, U+FFFF) are left out there, so pasted text can't make a request malformed.
- Nothing logs requests, responses or passwords; `EWS_DEBUG=1` logs only the auth method and failure count.

## Read operations

| `MailBackend` call | EWS request |
|---|---|
| `folders()` | `GetFolder` (not strict) for `inbox`, `drafts`, `sentitems`, `junkemail`, `deleteditems`, `outbox` with `TotalCount`; then `FindFolder Deep` from `msgfolderroot`, pages of 1000 by `IndexedPagingOffset` until `IncludesLastItemInRange` (an offset that doesn't advance stops) |
| `newest(in:limit:)` | `FindItem Shallow`, `IndexedPageItemView` offset 0, sorted by `DateTimeReceived` descending |
| `sync(_:token:)` | `SyncFolderItems`, `MaxChangesReturned` 512, with `SyncState` when there is a token |
| `body(remoteID:)` | `GetItem`, `BodyType Best`, `item:Body`, `item:TextBody`, attachments, From/To/Cc, ReplyTo, invite fields |
| `inlineImages` | `GetItem` attachments; then `GetAttachment` (not strict) for image attachments whose `ContentId` is wanted |
| `attachment(remoteID:index:)` | `GetItem` attachments (IDs looked up each time; moves change them), then `GetAttachment` with `IncludeMimeContent` |
| `events(from:to:)` | `FindItem` with `CalendarView` on the `calendar` folder |
| `maxMessageSize(from:)` | `GetMailTips` for the own address, `MaxMessageSize` |

Summary fields for `newest` and `sync`: `Subject`, `DateTimeReceived`, `IsRead`, `From`, `HasAttachments`, `Flag`,
`Preview`, `DisplayTo`, `DisplayCc`, `ConversationId`.

## Write operations

| Call | EWS request |
|---|---|
| `setRead` | `UpdateItem` `SetItemField message:IsRead`, `SaveOnly`, `AlwaysOverwrite` (no change key), `SuppressReadReceipts` |
| `setFlagged` | The same with `item:Flag` / `FlagStatus` `Flagged` or `NotFlagged` |
| `move` | `MoveItem` with `ReturnNewItemIds`; new IDs are paired with old ones by response order |
| `delete` | `DeleteItem DeleteType="SoftDelete"` (into Recoverable Items) |

- `setRead`, `setFlagged`, `move` and `delete` are judged per item (`checkBatch`, not strict): one response message
  per item, in request order, is required, else the batch fails as a whole. Items with a code other than `NoError`
  are thrown as `PartlyRefused` (refused IDs with "MessageText (code)", and the new IDs of the items that moved).
  For `delete`, `ErrorItemNotFound` counts as erased.
| `send` without files | `CreateItem SendAndSaveCopy`, saved to `sentitems` |
| `saveDraft` without files | `CreateItem SaveOnly` into `drafts` |
| with files | `CreateItem SaveOnly` into `drafts` → `CreateAttachment` (all files in one call) → for send, `SendItem` with the root item's last change key, saving to `sentitems`. A failed step deletes the half-made draft item; if that delete fails too, it throws `LeftOnServer` (item ID + the first error) and the store queues `.delete([id])` for that account and sets the account aside for the rest of the drain (the queued change keeps the item out of Drafts syncs until erased), then handles the first error as usual |
| `respond` | `CreateItem` with `AcceptItem` / `TentativelyAcceptItem` / `DeclineItem`: optional text `Body` (comment), `ReferenceItemId`, `ProposedStart`/`ProposedEnd`; `SendAndSaveCopy`, or `SaveOnly` for "Do Not Send a Response" |
| `removeFromCalendar` | `CreateItem SaveOnly` with `RemoveItem` / `ReferenceItemId` |

- Message body: `BodyType="Text"` with `Draft.text`, or `BodyType="HTML"` with `Draft.html` when pictures are
  placed in the text ([rendering.md](rendering.md#html-of-sent-mail)). Recipients: `Contact.parseList` of To and Cc,
  each as `Mailbox` with `Name` and `EmailAddress`; empty lists are left out. No `In-Reply-To`/`References`.
- Files: `FileAttachment` with `Name`, `ContentType` (default `application/octet-stream`), base64 `Content`;
  placed pictures also get `ContentId` (a fresh UUID) and `IsInline` true.

## Parsing rules

- **Dates:** `EWSBackend.isoDate` reads `xs:dateTime`: blanks trimmed, fractional seconds of any length, and a
  time without `Z` or `±hh:mm` read as UTC (EWS's default without a `TimeZoneContext`). A message date that still
  doesn't parse becomes `distantPast`; an invite without parsable Start/End is nil; such calendar events are dropped. Requests format dates with a default `ISO8601DateFormatter` too (UTC, `Z`).
- **Summary** (`message(_:)`): needs `ItemId`. Sender from `From` (`Name`, else the address). To/Cc from
  `DisplayTo`/`DisplayCc` split on `;`, as names with empty addresses. `FlagStatus Flagged` → red flag. `isInvite`
  when the element is `MeetingRequest` or `MeetingCancellation`. `bodyLoaded` false, `serverPreview` = `Preview`.
- **Sync** (`parseSync`): `Create`/`Update` → upsert of the first child element; `Delete` → removed ID;
  `ReadFlagChange` → read state; `more` when `IncludesLastItemInRange` is "false"; token from `SyncState`.
  `ErrorInvalidSyncStateData` for a request that carried a token is thrown as `SyncTokenRejected` (any other error,
  and that code without a token, as `EWSError`).
- **Body** (`parseBody`): `html` = `Body` when `BodyType="HTML"`. `text` = `TextBody` if present (an empty or blank one only without an HTML body), else a
  rough plain text of the HTML (`plainText`, one linear pass: drop comments and head/style/script, an unclosed one
  to the end; line breaks for `br` (with attributes too) and closing p/div/tr/li/h1–h6, a space for closing td/th,
  strip other tags; decode `&#n;`, `&#xh;` and named references (Latin-1 and common punctuation, no-break space as
  a space; unknown ones stay); trim lines, drop empty ones), else the body. From/To/Cc from the full `Mailbox`es.
- **Attachments** (`listedAttachments`): every child of `Attachments` with a non-blank `Name` and `IsInline` not
  "true", then (in server order) the rest that aren't inline pictures: unnamed ones, and those with `IsInline` "true"
  that aren't pictures (a `FileAttachment` whose `ContentType` starts `image/`, or is
  generic and the `Name`'s extension is an image or unknown): only pictures are placed in the body, so any other
  inline file would be invisible. They come last so positions in bodies stored before stay valid. A missing or blank
  name becomes "Attachment" plus the extension of its `ContentType` (`UTType`), if any;
  `ItemAttachment` gets `.eml` appended and type `message/rfc822`; size from `Size`. A `ReferenceAttachment` (cloud
  file) gets `.webloc` appended, no size or type; its content is a `.webloc` plist whose `URL` is `AttachLongPathName`,
  only for http/https links (else no content). Content: the first
  element under `m:Attachments` only: a `FileAttachment`'s own `Content`, or the `MimeContent` directly under an
  `ItemAttachment`'s item (never a nested attachment's), base64-decoded.
- **Inline images** (`inlineAttachmentIDs`): `FileAttachment`s with `ContentType` starting `image/`, or generic
  (`application/octet-stream`, missing or empty), and a `ContentId` (trimmed of `<`, `>`, space) in the wanted set,
  inline or not; keyed by that ID. A generic type is replaced by the one for the `Name`'s extension (`UTType`), else
  stays `application/octet-stream`.
- **Invite** (`parseInvite`): built for a `MeetingRequest` or `MeetingCancellation` (as `message()`'s `isInvite`) with
  `Start` and `End`: location, all-day,
  organizer, required and optional `Attendee/Mailbox`; `isCancellation` when the element is `MeetingCancellation`.
- **Events:** `LegacyFreeBusyStatus` Free/Tentative/Busy → same; OOF and WorkingElsewhere → away; else unknown.
- **Folders:**
  - Standard folders: each successful `GetFolderResponseMessage`, paired with the requested IDs in order. If the
    Inbox's (first) answer is an error, `folders()` throws it as `EWSError`: the check shows it, and since no list is
    kept, the next check asks again.
  - Archive: the top-level `FindFolder` result named "archive" or "archiv" (any case). A nested one (in a project folder, or a deleted one in Deleted Items) is an ordinary folder; with no top-level one the account has no Archive.
  - User folders (`folderTree`): `Folder` elements only (calendar, contacts, tasks and search folders are other
    tags). Kept if it and every ancestor has class `IPF.Note` or none, isn't hidden (`0x10F4`) and isn't the
    Outbox. Standard folders keep their role. A parent outside the result means top level. A folder ID listed
    twice (overlapping pages) counts once, the first one.
