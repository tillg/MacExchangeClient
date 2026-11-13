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
  (`exchangeAccounts`). Its `Account` is named "Exchange" with the email as address.
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
  except tab/LF/CR, surrogates `D800`–`DFFF`, `FFFE`, `FFFF`, past `10FFFF`) becomes `&#xFFFD;` before parsing. An unparsable body throws "Unreadable EWS response (N bytes)". A SOAP `Fault`
  throws its `ResponseCode`/`faultstring`. An answer without any `ResponseCode` (an empty SOAP body, a proxy's
  well-formed error page) throws "The server's answer holds no Exchange result", strict or not. With `strict` (the default), the first `ResponseCode` other than
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
| `body(remoteID:)` | `GetItem`, `BodyType Best`, `item:Body`, `item:TextBody`, attachments, From/To/Cc, invite fields |
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
| with files | `CreateItem SaveOnly` into `drafts` → `CreateAttachment` (all files in one call) → for send, `SendItem` with the root item's last change key, saving to `sentitems`. A failed step deletes the half-made draft item |
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
- **Body** (`parseBody`): `html` = `Body` when `BodyType="HTML"`. `text` = `TextBody` if present (even empty), else a
  rough plain text of the HTML (`plainText`: drop head/style/script, line breaks for `br` and closing block tags,
  strip tags, decode six entities, trim lines, drop empty ones), else the body. From/To/Cc from the full `Mailbox`es.
- **Attachments** (`listedAttachments`): every child of `Attachments` with a `Name` and `IsInline` not "true";
  `ItemAttachment` gets `.eml` appended and type `message/rfc822`; size from `Size`. Content: the first
  element under `m:Attachments` only: a `FileAttachment`'s own `Content`, or the `MimeContent` directly under an
  `ItemAttachment`'s item (never a nested attachment's), base64-decoded.
- **Inline images** (`inlineAttachmentIDs`): `FileAttachment`s with `ContentType` starting `image/`, or generic
  (`application/octet-stream`, missing or empty), and a `ContentId` (trimmed of `<`, `>`, space) in the wanted set,
  inline or not; keyed by that ID. A generic type is replaced by the one for the `Name`'s extension (`UTType`), else
  stays `application/octet-stream`.
- **Invite** (`parseInvite`): built for any item with `Start` and `End` (not only meeting requests): location, all-day,
  organizer, required and optional `Attendee/Mailbox`; `isCancellation` when the element is `MeetingCancellation`.
- **Events:** `LegacyFreeBusyStatus` Free/Tentative/Busy → same; OOF and WorkingElsewhere → away; else unknown.
- **Folders:**
  - Standard folders: each successful `GetFolderResponseMessage`, paired with the requested IDs in order.
  - Archive: the `FindFolder` result named "archive" or "archiv" (any case), a top-level one first.
  - User folders (`folderTree`): `Folder` elements only (calendar, contacts, tasks and search folders are other
    tags). Kept if it and every ancestor has class `IPF.Note` or none, isn't hidden (`0x10F4`) and isn't the
    Outbox. Standard folders keep their role. A parent outside the result means top level. Duplicates are not
    removed.
