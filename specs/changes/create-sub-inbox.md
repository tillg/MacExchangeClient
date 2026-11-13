# Change spec: mailbox context menu (create-sub-inbox)

Status: ready to implement · Written 2026-11-13 · Scope: the sidebar context menu on an account's mailboxes, the
mailbox operations behind it, and an Account Info window (Messages on Server, Out of Office, Summary).

## Goal

Right-clicking a mailbox in the sidebar today offers only **Mark All Messages as Read**. Extend that menu to Mail's
menu, minus the items we don't build, so the user can manage their Exchange folders in the app:

```
New Mailbox…
──────────────
Add to Favorites            (Remove from Favorites when it already is one)
Rename Mailbox…
Delete Mailbox…
──────────────
Erase Deleted Items…
Mark All Messages as Read   (exists today, stays)
──────────────
Out of Office…
──────────────
Get Account Info
```

The headline is **New Mailbox…**: create a folder, by default inside the clicked one (a "sub-inbox").

Titles are Mail's own, from `MailboxesContextMenu.loctable` (`en`): `New Mailbox…`, `Add to Favorites`,
`Rename Mailbox…`, `Delete Mailbox…`, `Erase Deleted Items…`, `Mark All Messages as Read`, `Out of Office…`,
`Get Account Info`; `Remove from Favorites` is `Localizable.loctable` `RemoveMailboxFromFavoritesMenuItem`. The
user's screenshot shows the en_GB spelling ("Favourites", "Bin"); the app uses US English throughout, so it stays
"Favorites" and "Trash".

## Non-goals

- Mail's other items: Add Favorite Mailbox…, Export Mailbox…, Erase Junk Mail…, Synchronize “…”, Edit “…”…, Edit
  Smart Mailbox…. Also no **Mailbox** menu-bar entries for the new actions (Mail has New Mailbox… and Erase Deleted
  Items there; a later change can add them through the same store calls).
- Moving a mailbox by drag (Mail allows dragging a folder onto another). Only messages are dragged.
- Changing folders while offline. Every folder operation needs the server at that moment; it isn't queued.
- Rich-text editing of Out of Office replies (see 6).
- Quotas: on-prem Exchange quota isn't shown (Mail's Account Info has no quota tab for EWS either).

## Current state (read these first)

- `Sources/MailReplica/SidebarView.swift`
  - `.contextMenu(forSelectionType: Row.self)` (around line 79) has the one button. `Row` is `(ref, favorite)`;
    `favorite` marks the copy of an account's Inbox under Favorites ▸ All Inboxes.
  - The Favorites section is fixed: All Inboxes (a disclosure group over each account's Inbox when there is more
    than one account), VIPs, Flagged.
  - Account sections: `MailboxKind.allCases` then `store.children(of: nil, account:)`, each a `tree(...)`.
- `Sources/MailReplica/MailCommands.swift`: `favorites` (⌘1…⌘9) is `[All Inboxes, VIPs, Flagged] + each
  account's Inbox`.
- `Sources/MailModel/Models.swift`: `MailboxKind` (standard roles, or `.folder(serverID)`), `Folder(box, name,
  parent)`, `MailboxRef`.
- `Sources/MailModel/MailStore.swift`
  - `folders: [UUID: [Folder]]` (persisted through `StoreChanges.folders` into the DB `folders` table) and the
    private `remoteFolders: [UUID: [RemoteFolder]]` (the server IDs, in memory).
  - `setRemoteFolders(_:account:)` rebuilds `folders` from the server list and handles folders that are gone: their
    mail, sync tokens and history state go, and a selected one falls back to the Inbox. **Reuse it** for rename and
    delete rather than writing a second path.
  - The folder list is read once per launch (`remoteFolders[acct] == nil` in `refresh`, `moveToTrash`, …).
  - `foldersInTrash`: folders inside Trash at any depth count as deleted.
  - `delete(_:)`: messages in Trash are erased (`.delete` change, EWS `DeleteItem SoftDelete`), others move to Trash.
  - Server writes go through the `outbox` (`enqueue` → `drain`). `refresh` flushes it first (`scheduleFlush()` +
    `await flushTask?.value`).
  - `noteWritten` / `written` stop an answer requested before a write from undoing it.
  - `backends` is private; the UI never talks to a backend directly.
- `Sources/MailModel/MailBackend.swift`: the `MailBackend` protocol and `RemoteFolder(role, id, totalCount, name,
  parent)`.
- `Sources/EWS/EWSBackend.swift`: requests are built by `static func …Request(...) -> String` and parsed by
  `static func parse…`, both unit-tested in `Tests/MailModelTests/EWSParsingTests.swift`. `folders()` is
  `GetFolder` for the standard folders plus `FindFolder Deep` from `msgfolderroot` (`folderTree` filters to mail
  folders). Details: `specs/system/ews.md`.
- `Sources/EWS/ExchangeAccount.swift`: `email`, `username`, `server`, `ewsURL` (for the Summary tab).
- `Sources/MailReplica/MailReplicaApp.swift`: scenes are `WindowGroup("Mail")`, `WindowGroup("New Message")`,
  `Window("What's New")`, `Settings`.
- Tests that touch a server use `ScriptedServer` / `LoopbackEndpoint` in `Tests/MailModelTests/EWSFlowTests.swift`:
  the real `EWSClient`, `EWSBackend` and `MailStore` over HTTP to 127.0.0.1, answering with hand-written XML. No
  fake classes. Live checks against the real server live in `EWSLiveTests` / `EWSLiveWriteTests` (gated by
  `EWS_USER`, `EWS_SERVER`).
- `specs/system/limitations.md` currently says: "Folders can't be created, renamed or deleted in the app". This
  change removes that line.

## Design

### 1. Menu: which items apply where

The context menu is built for the clicked row (`rows.first`). Enabled states:

| Item | Standard mailbox (Inbox, Drafts, Sent, Junk, Trash, Archive) | Own folder | Smart mailbox (All Inboxes, VIPs, Flagged, Unread) | A user favorite (copy under Favorites) |
|---|---|---|---|---|
| New Mailbox… | ✅ location = that mailbox | ✅ location = that folder | ✅ location = first account's top level | ✅ location = that mailbox |
| Add to Favorites / Remove from Favorites | ✅ Add (not for an account's Inbox: it is already there via All Inboxes) | ✅ | hidden | ✅ shows **Remove** |
| Rename Mailbox… | disabled | ✅ | disabled | ✅ (renames the folder) |
| Delete Mailbox… | disabled | ✅ | disabled | ✅ (deletes the folder) |
| Erase Deleted Items… | ✅ for the row's account | ✅ | ✅ all accounts (see 4) | ✅ |
| Mark All Messages as Read | as today | as today | as today | as today |
| Out of Office… | ✅ if the account has a server | ✅ | hidden | ✅ |
| Get Account Info | ✅ (account preselected) | ✅ | ✅ (first server account) | ✅ |

- "Has a server" is `Account.isServer`. Sample-data accounts have none; there Out of Office… is disabled and the
  Account Info window shows only Summary (with "n/a" values) — see 5.
- Erase Deleted Items… is disabled when the account's Trash, and every folder inside it, is empty in memory.
- Rename/Delete are disabled for a folder while another folder operation of the same account runs (one at a time per
  account; see 3).
- The store answers "what's allowed": `MailStore.canRename(_ ref:)`, `canDelete(_:)`, `canEraseDeleted(account:)`,
  `isFavorite(_:)`, so the rules are tested in `MailModel`, not in the view.

### 2. Favorites (Add to Favorites / Remove from Favorites)

- New store state `favorites: [MailboxRef]` (only `.account` refs), in the order added. Persisted in
  `UserDefaults` under `favoriteMailboxes` as `["<accountUUID>/<box.rawValue>", …]`; loaded in `MailStore.init`
  only when a defaults object is passed in (tests pass none, so they stay hermetic). The snapshot hook runs under its
  own empty defaults domain already.
- Sidebar: user favorites are listed in the Favorites section after Flagged, with the mailbox's own symbol and name.
  When the account isn't the only one, the title is `"<name> – <account>"`, like Mail's
  `FavoritesBarParentMailboxFormat` ("%1$@ - %2$@"). Their rows carry `Row.favorite = true` so selecting one
  highlights only that row (the existing `inFavorites` logic, generalised from "Inbox" to any ref).
- ⌘1…⌘9 (`MailCommands.favorites`): the fixed list, then user favorites, capped at 9.
- A favorite whose folder disappears (deleted here, or gone from the server's list) is dropped from `favorites`.
  A rename keeps it (the ref holds the server ID, which a rename doesn't change).
- Drops onto a favorite row behave as drops on the mailbox itself (`store.drop(_, on: ref)`).

### 3. New / Rename / Delete Mailbox

All three go **straight to the server**, not through the outbox: a new folder's ID only exists once the server made
it, and a queued rename/delete of a folder that later fails would leave the user looking at a tree the server doesn't
have. The local tree changes only after the server said yes.

Flow for each (`MailStore`, `async throws`):
1. For a server account: flush the outbox first (as `refresh` does), so a move into a folder that is about to be
   deleted, or mail moved into Trash just before an erase, reaches the server first.
2. Show progress in the sidebar's activity view with Mail's task names: `Creating new mailbox`, `Renaming “X”…`,
   `Deleting “X”…` (`Localizable.loctable`: `CreateMailboxTaskName`, `RenamingMailboxStatusFormat%1$@`,
   `DeletingMailboxStatusFormat%1$@`).
3. Call the backend. On success, update `remoteFolders[acct]` and pass the new list to `setRemoteFolders`, which
   rebuilds `folders` (and, for delete, removes the mail, sync state and selection of the folder and every
   subfolder). On failure, nothing changes and the error is thrown to the view, which shows an alert (below).
4. Accounts without a backend (sample data): the same operations change `folders` directly in memory, so the
   feature is usable and testable without a server. New folder IDs there are `.folder(UUID().uuidString)`.

**New Mailbox…** — a sheet, as Mail's `NewMailboxPanel`:
- Title `New Mailbox`; `Location:` popup; `Name:` text field; `Cancel` / `OK`.
- Location lists, per account, the account (top level) and every mailbox of it indented by depth: the standard
  mailboxes and every own folder. Preselected: the clicked mailbox (so right-click ▸ New Mailbox… on "07 customers"
  creates a subfolder of it). Exchange allows folders inside Inbox, Sent etc., so standard mailboxes are valid parents.
- OK is disabled while the name, trimmed of spaces, is empty, or while a sibling in that location already has the name
  (case-insensitive, as Exchange compares). The sheet then says `A mailbox with that name already exists.`
  (`AppIntents.loctable` `Mailbox_Already_Exists_Dialog`).
- After OK: the new folder is created, its parent opens in the sidebar (`expanded`), and the new folder is selected.
- It is a normal folder for history sync: empty, `complete` after its first sync.

**Rename Mailbox…** — a sheet with the same `Name:` field, prefilled with the current name, OK / Cancel, same
validation. (Mail renames inline in the sidebar. In a SwiftUI `List` with selection and drag targets, an inline
`TextField` row fights with selection and focus; a sheet is the robust choice. Revisit if it feels wrong.)

**Delete Mailbox…** — an alert, then the delete:
- Message: `Delete the mailbox “%@”?` (`DeleteMailboxQuestionFormat%1$@`).
- Informative text: `Deleting a mailbox permanently removes it and any messages it contains. This action cannot be
  undone.`, or with subfolders `Deleting a mailbox permanently removes it and its contents. This action cannot be
  undone.` (`DeleteMailboxAlertMessageFormat`, `DeleteMailboxAndSubmailboxesAlertMessageFormat`).
- Buttons: `Delete` (destructive) and `Cancel`.

**Errors** (alert, server's `MessageText` as the informative text): `The mailbox “%@” could not be created.`,
`The mailbox “%@” could not be renamed.`, `The mailbox “%@” could not be deleted.` (`Alerts.loctable`
`CouldntCreateMailboxTitle%1$@`, `RenameFailedErrorFormat%1$@`, `DeleteFailedErrorFormat%1$@`). Offline (URLError)
and busy (ServerBusy) are errors here too; nothing is retried.

**EWS** (new `MailBackend` calls, implemented in `EWSBackend`):

| Call | EWS request |
|---|---|
| `createFolder(named:in:) -> RemoteFolder` | `CreateFolder` with `ParentFolderId` = the parent's ID (`DistinguishedFolderId msgfolderroot` for top level), one `t:Folder` with `FolderClass IPF.Note` and `DisplayName`. Returns the new `FolderId` |
| `renameFolder(_:to:)` | `UpdateFolder`, `SetFolderField folder:DisplayName` |
| `deleteFolder(_:)` | `DeleteFolder DeleteType="SoftDelete"` (into Recoverable Items, like message erase; it leaves the tree at once, matching Mail's "permanently removes" text) |

`ErrorFolderExists` (a same-named folder made elsewhere since the last list) is shown with the existing-name message.

### 4. Erase Deleted Items…

- Alert as Mail: `Are you sure you want to erase deleted items in the Trash mailbox of your “%@” account?`
  (`EmptyTrashWarningOneAccountQuestionFormat%1$@`); on a smart mailbox with several accounts `Are you sure you
  want to erase deleted items in the Trash mailbox?` (`EmptyTrashWarningAllAccountsQuestion`) and it erases every
  account's. Informative: `Erasing deleted items such as messages and mailboxes permanently deletes them. This action
  cannot be undone.` Buttons: `Erase` (destructive), `Cancel`.
- Progress: `Erasing deleted messages` (`CompactMailboxTaskName`).
- Server account: flush the outbox, then `emptyTrash(_ trash: RemoteFolder)` = EWS `EmptyFolder`
  `DeleteType="SoftDelete"` `DeleteSubFolders="true"` on the Trash folder ID. On success, locally: remove every
  message in Trash or a folder inside it (`isDeleted`), `forget` them, note their remote IDs as written (as an erase
  does, so a Trash sync answer requested before the erase can't bring them back), and drop the folders inside Trash
  through `setRemoteFolders`. On failure: alert `Couldn't erase deleted items: <message>`; nothing changes.
- Sample account: the same local removal, no server.
- Mail selected in Trash that is erased leaves the selection (existing `keepingSelectionVisible` rules).

### 5. Get Account Info (window)

A new single window, `Window("Account Info", id: "account-info")`, opened by the menu item with the row's account
preselected (pass it through a `@State`/store property; `openWindow(id:)` can't carry a value for a `Window`). Out of
Office… opens the same window on the Out of Office tab. Layout as Mail's (screenshots 3 and 4):

- Top: `Account:` popup listing accounts as `"<name> (Exchange)"` (`AccountPopUpSuffix%1$@`).
- A segmented control with three tabs: `Messages on Server`, `Out of Office`, `Summary`.

**Messages on Server**
- A `Table` with columns `Mailbox` (symbol + name), `Messages`, `Size`. Sortable by each; default **Size,
  descending** (as the screenshot). Every mail folder of the account in a flat list (standard and own, also those
  inside Trash), not a tree.
- Numbers use the user's locale: `54.183`, `9,72 GB` (`ByteCountFormatter`, `.file` style).
- Bottom left: a spinner and `Sizing mailboxes…` while loading (Mail shows `Sizing “<folder>”` per folder because it
  asks one folder at a time; we ask once, see below). Bottom right: `Show Messages` (Mail's `EWSQuota` string),
  enabled with one row selected: selects that mailbox in the main window and brings it forward. A double-click does
  the same.
- Loaded each time the tab is shown for an account; not cached, not persisted.
- New `MailBackend.folderSizes() -> [FolderSize]` with `FolderSize(id, count, bytes)`: one paged `FindFolder Deep`
  from `msgfolderroot` (same paging as `folders()`), `FolderShape IdOnly` plus `folder:TotalCount` and
  `ExtendedFieldURI PropertyTag="0x0E08" PropertyType="Long"` (`PR_MESSAGE_SIZE_EXTENDED`), plus the standard
  folders via `GetFolder` with the same properties. The store joins sizes with its own folder list by server ID
  (names, symbols, role) and leaves out IDs it doesn't show (calendar, contacts, hidden folders).
- ⚠️ `0x0E08` on folders through EWS is not verified on the user's server. Verify it first with a live read-only
  test (`EWSLiveTests`). If it isn't returned, fall back to the per-folder approach Mail uses (`FindItem` with
  `item:Size`, summed, one folder at a time with `Sizing “<folder>”` progress) and say so in the result.

**Out of Office** — see 6.

**Summary**
- Read-only labels from Mail's `AccountSummary`: `Account Description:` (account name), `Email Address:`,
  `User Name:` (`DOMAIN\user`), `Incoming Mail Server:` (host of `ewsURL`), `Outgoing Mail Server:` (same host,
  Exchange sends through EWS), `SSL:` `on`. `Full Name:` is left out (not known without a directory lookup).
- Sample accounts show their name and address, the rest `n/a` (`QuotaNotAvailable`).

### 6. Out of Office

UI as screenshot 4 (`OofPanel.loctable`):
- Checkbox `Send Out of Office replies:` and popup `Until disabled` / `While scheduled`.
- `Starting` and `Ending` date-and-time pickers (stepper style), enabled only with the checkbox on and `While
  scheduled` chosen. Defaults when the server has none: now, rounded to the hour, and +1 day.
- `Internal Reply:` and `External Reply:` text editors, enabled only with the checkbox on.
- Ending earlier than Starting: the Ending picker is clamped to Starting (as a `DatePicker` range).

Behaviour:
- Read on showing the tab (spinner meanwhile): `MailBackend.outOfOffice() -> OutOfOffice` = EWS
  `GetUserOofSettingsRequest` with the account's address. Map `OofState` Disabled → off; Enabled → on, Until
  disabled; Scheduled → on, While scheduled, with `Duration` `StartTime`/`EndTime`.
- `InternalReply`/`ExternalReply` `Message` are HTML. They are shown as plain text (the existing
  `EWSBackend.plainText`). **Only a reply the user edited is written back**; an untouched one is sent back exactly
  as read, so the server's formatting (the signature rule in screenshot 4) survives opening the tab. An edited one is
  sent as HTML built from the text (escaped, line breaks as `<br>`), losing its old formatting; the editor says so
  with a one-line note under it after the first edit: "Formatting of this reply is replaced by plain text."
- `ExternalAudience` has no control in Mail; it is kept as read and sent back unchanged.
- **Saving:** Mail's panel has no Save button. Save when the window closes, the account popup changes, or the tab
  changes — only if something changed. `MailBackend.setOutOfOffice(_:)` = `SetUserOofSettingsRequest` with the
  full settings. Failure: alert `Couldn't save Out of Office: <message>`, and the tab stays open with the edits.
- Times are sent and read in UTC (the client's existing `ISO8601DateFormatter` convention); shown in local time.
- The settings are not stored locally and not persisted.

### 7. Store API summary

```swift
// MailStore (all @MainActor)
public private(set) var favorites: [MailboxRef]
public func isFavorite(_ ref: MailboxRef) -> Bool
public func addFavorite(_ ref: MailboxRef)
public func removeFavorite(_ ref: MailboxRef)

public func canRename(_ ref: MailboxRef) -> Bool
public func canDelete(_ ref: MailboxRef) -> Bool
public func canEraseDeleted(account: UUID) -> Bool
public func siblingNameExists(_ name: String, in parent: MailboxKind?, account: UUID, except: MailboxKind? = nil) -> Bool

public func createMailbox(named: String, in parent: MailboxKind?, account: UUID) async throws -> MailboxKind
public func renameMailbox(_ box: MailboxKind, account: UUID, to name: String) async throws
public func deleteMailbox(_ box: MailboxKind, account: UUID) async throws
public func eraseDeletedItems(account: UUID) async throws

public func mailboxSizes(account: UUID) async throws -> [MailboxSize]      // (box, name, symbol, count, bytes)
public func outOfOffice(account: UUID) async throws -> OutOfOffice
public func setOutOfOffice(_ s: OutOfOffice, account: UUID) async throws
```

`OutOfOffice` (in `MailBackend.swift`): `state` (`.disabled`, `.enabled`, `.scheduled`), `start`, `end`,
`internalReply`, `externalReply` (HTML as read), `externalAudience` (opaque string, round-tripped).

## Tests (write first, see that each fails, then implement)

`Tests/MailModelTests/EWSParsingTests.swift` (request builders and parsers, no network):
1. `createFolderRequest` puts the escaped name, `IPF.Note` and the parent ID (or `msgfolderroot`) in the right
   elements; `parseCreateFolder` returns the new `FolderId`.
2. `renameFolderRequest` and `deleteFolderRequest` (`SoftDelete`), `emptyFolderRequest` (`SoftDelete`,
   `DeleteSubFolders="true"`, the Trash ID).
3. `folderSizesRequest` asks for `TotalCount` and `0x0E08`; `parseFolderSizes` reads count and bytes per ID, and a
   folder without the property gets `bytes = nil` (shown as "n/a").
4. `GetUserOofSettings` parsing: Disabled, Enabled, Scheduled with times; HTML replies kept as-is;
   `ExternalAudience` kept. `setOofRequest` round-trips an untouched settings value unchanged and escapes edited text.

`Tests/MailModelTests/EWSFlowTests.swift` (`ScriptedServer`, real client, backend and store):
5. **Create:** `createMailbox("Sub", in: .folder(A))` → the folder is in `children(of: .folder(A))` with the
   server's new ID; a pending move queued before it went out **before** the `CreateFolder` (script order).
6. **Create refused** (`ErrorFolderExists`): throws, `folders` unchanged.
7. **Rename:** name changes, ID, selection and favorite stay.
8. **Delete** a folder with a subfolder and mail in both: both folders, their mail and sync tokens are gone, a
   selected one falls back to the Inbox, a favorite of it is dropped. Refused delete: nothing changes.
9. **Erase Deleted Items:** a queued move to Trash goes out first, then `EmptyFolder`; afterwards no message is in
   Trash or a folder inside it, those folders are gone, and a Trash sync answer requested before the erase that
   still lists an erased item doesn't bring it back.
10. **Offline** (endpoint stopped): each folder operation throws and changes nothing; nothing is added to the outbox.

`Tests/MailModelTests/MailStoreTests.swift` (no server, sample-style accounts):
11. Local create/rename/delete/erase change `folders` and `messages` in memory as above.
12. `canRename`/`canDelete` false for standard and smart mailboxes, true for own folders; `canEraseDeleted` false
    with an empty Trash, true with mail in a folder inside Trash.
13. `siblingNameExists` is case-insensitive, looks only at the given parent, and ignores the folder being renamed.
14. Favorites: add/remove/order; no duplicates; account Inbox and smart mailboxes can't be added; persisted and
    reloaded through a `UserDefaults(suiteName:)` made for the test; a folder that leaves the server's list is dropped.

Live, gated (`EWSLiveTests`, read-only): 15. `folderSizes()` returns a byte size for the Inbox (answers the ⚠️ in 5);
`outOfOffice()` parses the real settings. No live write test for OOF or folders unless the user asks.

Run the tests as `CLAUDE.md` says: two separate top-level Bash calls, then check the test count.

## Acceptance

- All tests above pass; no existing test changed to make it pass.
- Visual, with `tools/snapshot.sh` (sample data): a context menu isn't part of a window snapshot, so add a `MAIL_SNAPSHOT_SHEET=newMailbox|accountInfo|oof` hook to `DebugSnapshot` that opens
  the sheet/window over the snapshot, and check: the New Mailbox sheet with Location preselected; Account Info on
  each tab in light and dark (`MAIL_SNAPSHOT_DARK=1`); a user favorite row under Flagged in the sidebar.
- On the real account (by the user, since writes are involved): create "zz test" inside a folder, rename it, delete
  it; each shows in Outlook Web within one refresh. Account Info lists sizes close to Mail's (screenshot 3).
- `README.md`: the sidebar bullet gets the new menu, Favorites, Account Info; remove the "can't create, rename or
  delete folders" note.
- `WhatsNew.days`: one line per user-visible feature (new mailboxes, rename/delete, favorites, erase deleted items,
  account info, out of office), plain words.
- `specs/system/`: `functional.md` (sidebar, menu, Account Info), `ews.md` (new requests), `domain-model.md`
  (`OutOfOffice`, favorites), `limitations.md` (remove the line; add "folder operations need the server, they aren't
  queued" and "Out of Office replies are edited as plain text").

## Open decisions (defaults chosen; flag if wrong)

1. **Delete = `SoftDelete`** (gone from the tree, recoverable by an admin) rather than `MoveToDeletedItems` (the
   folder would reappear inside Trash). Matches Mail's wording.
2. **Rename in a sheet**, not inline in the sidebar.
3. **Out of Office edited as plain text**, untouched replies round-tripped as HTML.
4. **Folder operations are online-only**, not queued in the outbox.
5. **Favorites in `UserDefaults`**, not the database (they are a view preference, like Mail's).

## Risks and notes

- `FindFolder Deep` with an extended property over ~900 folders: one or two pages; should be well under a second.
  Measure on the real account in the live test.
- `EmptyFolder` with `DeleteSubFolders` on Deleted Items needs Exchange 2010 SP1+; the client requests
  `Exchange2013_SP1`, so it's available. A very large Trash (screenshot: 11,966 items, 1.8 GB) may take a while;
  use a longer timeout for this one call (e.g. 300 s instead of 60 s).
- After any folder operation the tree differs from what the next launch's `folders()` returns only if someone
  changed folders elsewhere meanwhile; that is the existing "read once per launch" limitation.
