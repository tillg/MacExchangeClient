# Mail Replica

A SwiftUI copy of the macOS Mail app's main window, built with SwiftPM. The data is a set of fixture messages kept in memory. There is no IMAP or SMTP.

```sh
./run.sh          # build and launch
./run.sh test     # model tests (Swift Testing)
```

`run.sh` builds against the macOS 26.5 SDK. In the 27 SDK `@State` is a macro, and its plugin (`SwiftUIMacros`) only ships with Xcode. Tests run against the default SDK, because the Swift Testing macros are only there. If Xcode is installed, `swift run` works as is.

## How Apple Mail works (read from `/System/Applications/Mail.app`)

✅ = read from the bundle · ⚠️ = from memory/estimate

| Area | Behaviour | Source |
|---|---|---|
| Window | Three columns: mailboxes sidebar, message list, message view | ✅ nibs `MailboxesViewController`, `MessageListListLayoutViewController`, `MessageViewController` |
| Toolbar default set | toggle sidebar · back/forward · filter · view options · compose ‖ reply/reply all/forward · archive/delete/junk · move · flag ‖ search | ✅ `MainWindow.toolbar` (`default set`, SF Symbol names `archivebox`, `trash`, `xmark.bin`, `arrowshape.turn.up.*`, `folder`) |
| Sidebar | Favorites, Smart Mailboxes, then each account's Inbox/Drafts/Sent/Junk/Trash/Archive, with unread badges | ✅ `Sidebar*.icns` names · ⚠️ badge rules |
| Categories | Inbox top bar: Primary, Transactions, Updates, Promotions (⌥⌘1–4) | ✅ `MainMenu.nib` · ⚠️ colours |
| Flags | Red, Orange, Yellow, Green, Blue, Purple, Gray. Toggle Flag ⇧⌘L | ✅ `MainMenu` |
| Shortcuts | New ⌘N, Get Mail ⇧⌘N, Reply ⌘R, Reply All ⇧⌘R, Forward ⇧⌘F, Archive ⌃⌘A, Junk ⇧⌘J, Read/Unread ⇧⌘U, Filter ⌘L, Delete ⌘⌫, Send ⇧⌘D, mailboxes ⌘1–9 | ✅ `MainMenu.nib` key equivalents |
| List row | Unread dot, sender (bold), date (time / Yesterday / weekday / date), subject, 2-line preview, flag and paperclip, optional contact photo | ⚠️ drawn in code, not in the nibs. Fonts: 13pt system, 11pt header ✅ |
| Behaviour | A message is marked read when it is shown. Delete moves the message to the same account's Trash, and deleting from Trash erases it. Junk toggles back to Inbox. After an action the next message is selected. Search covers all of the account (not Trash or Junk). Swipe right = Unread, swipe left = Trash/Flag. Drag messages (or the whole selection) onto a sidebar mailbox to move them, also to another account; onto Flagged to flag them red; onto All Inboxes to put each back in its own Inbox. VIPs and Unread don't accept drops | ⚠️ / tested in `MailStoreTests` |

## Layout

- `Sources/MailModel`: `MailStore` (`@Observable`) with mailboxes, filtering, the actions and reply drafts. 22 tests in `Tests/MailModelTests`.
- `Sources/MailReplica`: the views (`MessageViewer`, `SidebarView`, `MessageListView`, `MessageDetailView`, `ComposeView`) and `MailCommands` (the menu bar).
- `MAIL_SNAPSHOT=out.png [MAIL_SNAPSHOT_DARK=1] .build/debug/MailReplica` saves a PNG of the window and quits. This checks the UI without needing screen-recording permission.

## Not replicated

Accounts and sync, rules, conversation threading, rich-text compose, attachments (they are placeholders), the separate message window on double-click, Remind Me, Follow Up, and Mute.
