# MacExchangeClient

A native macOS mail client in SwiftUI. It starts as a faithful replica of the Apple Mail main window, and the goal is to connect it to real mail servers.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark.png">
  <img alt="Three-column mail window: mailboxes sidebar, message list with category bar, message view" src="docs/screenshots/light.png">
</picture>

> **Status:** reads mail from on-prem Exchange over EWS (read-only for now). Without an account it shows built-in sample messages. See [Roadmap](#roadmap).

## Features

- **Exchange accounts over EWS:** sign in under Settings ▸ Accounts with email, `DOMAIN\user`, password and server, as in iOS Mail. Inbox, Drafts, Sent, Junk, Deleted Items and Archive are synced. The newest 200 messages show first, then a full sync runs; new mail is checked every minute. Bodies load when a message is opened. The password is kept in the Keychain

- **Three-column window** with a mailboxes sidebar, a message list and a message view, using Mail's toolbar layout and SF Symbols
- **Favorites and smart mailboxes:** All Inboxes, VIPs, Flagged, Unread, then each account's Inbox, Drafts, Sent, Junk, Trash and Archive, with unread badges
- **Categories:** Primary, Transactions, Updates and Promotions in the Inbox (⌥⌘1–4)
- **Message actions:** reply, reply all, forward, archive, delete, junk, flag in seven colours, mark read or unread. After an action the next message is selected, as in Mail
- **Drag & drop:** drag messages onto a mailbox to move them, also to another account. Drop them on Flagged to flag them, or on All Inboxes to put each back in its own Inbox
- **Search** across the whole account (not Trash or Junk), plus an unread filter
- **Compose window** with reply quoting, Send and Save Draft
- **Swipe actions:** swipe right for Unread, left for Trash or Flag
- **Menu bar and shortcuts** taken from Mail's own `MainMenu.nib`
- **Light and dark mode**

## Getting started

You need macOS 14 or later and Swift 6. Command Line Tools are enough; Xcode is not needed.

```sh
git clone https://github.com/tillg/MacExchangeClient.git
cd MacExchangeClient
./run.sh          # build and launch
./run.sh build    # build only
./run.sh test     # run the model tests
```

<details>
<summary>Why <code>run.sh</code> and not <code>swift run</code>?</summary>

In the macOS 27 SDK, `@State` is a macro whose plugin (`SwiftUIMacros`) ships only with Xcode. So `run.sh` builds the app against the macOS 26.5 SDK. The tests use the default SDK, because the Swift Testing macros live there, and get their own build folder (`.build/tests`) so the two setups don't spoil each other's cache. With Xcode installed, `swift run` works as is.
</details>

### Connecting to Exchange

Open Settings (⌘,) ▸ Accounts and sign in. The server can be a host name (`mail.example.com`, expanded to `https://mail.example.com/EWS/Exchange.asmx`) or a full EWS URL. The app checks the credentials before saving anything.

Exchange mail is **read-only for now**: flagging, moving, deleting and marking as read only work on the sample data, and Send is off for Exchange accounts. Nothing is cached on disk yet, so every launch syncs again.

`MAIL_SAMPLE_DATA=1 ./run.sh` shows the sample data even when an account is set up.

### Keyboard shortcuts

| Action | Keys | | Action | Keys |
|---|---|---|---|---|
| New message | ⌘N | | Archive | ⌃⌘A |
| Get Mail | ⇧⌘N | | Delete | ⌘⌫ |
| Reply | ⌘R | | Junk | ⇧⌘J |
| Reply All | ⇧⌘R | | Read / Unread | ⇧⌘U |
| Forward | ⇧⌘F | | Toggle flag | ⇧⌘L |
| Send | ⇧⌘D | | Unread filter | ⌘L |
| Go to mailbox | ⌘1–9 | | Category | ⌥⌘1–4 |

## Project layout

```
Sources/
  MailModel/        MailStore (@MainActor @Observable), the models, the drag payload and the MailBackend protocol
  EWS/              MailBackend over Exchange Web Services, Keychain and account settings
  MailReplica/      SwiftUI views, MailCommands (menu bar), DebugSnapshot
Tests/
  MailModelTests/   Swift Testing suites for MailStore, the drag payload and EWS parsing (37 tests)
docs/screenshots/   README images
run.sh              build / launch / test
```

Views stay thin. Every action is a method on `MailStore`, and each one has a test.

`MailStore` talks to servers only through the `MailBackend` protocol: folders, newest messages, sync with an opaque token, and message bodies. EWS is one implementation; Microsoft Graph will be another, with the token holding a Graph delta link. The data store doesn't change.

The live EWS test only reads, and runs only with `EWS_USER` (`DOMAIN\user`) and `EWS_SERVER` set and the password in the Keychain (service `MailReplica-EWS`, account = username). Otherwise it is skipped.

### Screenshots without screen recording

The app can save a PNG of its window and quit. This checks the UI without screen-recording permission:

```sh
MAIL_SNAPSHOT=$PWD/tmp/snap.png .build/debug/MailReplica
MAIL_SNAPSHOT=$PWD/tmp/snap-dark.png MAIL_SNAPSHOT_DARK=1 .build/debug/MailReplica
```

## How faithful is it?

The details come from Mail.app's own resources in `/System/Applications/Mail.app/Contents/Resources`: nibs, `MainWindow.toolbar` and `*.loctable`.

✅ read from the bundle · ⚠️ estimated

| Area | What the replica does | Source |
|---|---|---|
| Window | Sidebar, message list, message view | ✅ nibs `MailboxesViewController`, `MessageListListLayoutViewController`, `MessageViewController` |
| Toolbar | toggle sidebar · back/forward · filter · view options · compose ‖ reply/reply all/forward · archive/delete/junk · move · flag ‖ search | ✅ `MainWindow.toolbar` default set and SF Symbol names |
| Sidebar | Favorites, Smart Mailboxes, per-account mailboxes, badges | ✅ `Sidebar*.icns` names · ⚠️ badge rules |
| Categories | Primary, Transactions, Updates, Promotions | ✅ `MainMenu.nib` · ⚠️ colours |
| Flags | Red, Orange, Yellow, Green, Blue, Purple, Gray | ✅ `MainMenu.nib` |
| Shortcuts | See table above | ✅ `MainMenu.nib` key equivalents |
| List row | Unread dot, bold sender, relative date, subject, 2-line preview, flag, paperclip, optional contact photo | ⚠️ drawn in code · ✅ fonts 13pt / 11pt |
| Behaviour | Marked read when shown; Delete goes to the account's Trash and deleting from Trash erases; Junk toggles; next message selected after an action; drag & drop as described above | ⚠️ tested in `MailStoreTests` |

## Roadmap

- [x] Main window, actions, compose, shortcuts
- [x] Drag & drop between mailboxes and accounts
- [x] `MailBackend` protocol under `MailStore`
- [x] Reading mail from on-prem Exchange over EWS
- [ ] Flags, read state, moves, deletes and sending written back to Exchange
- [ ] Push for new mail (EWS notifications) instead of checking every minute
- [ ] Local cache on disk, so a launch doesn't sync everything again
- [ ] HTML message view and opening attachments
- [ ] Custom folders (only the standard folders are shown now)
- [ ] Microsoft Graph backend, once the mailbox is reachable there

**Not planned for now:** rules, conversation threading, rich-text compose, Remind Me, Follow Up, Mute, and the separate message window on double-click.
