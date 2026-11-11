# MacExchangeClient

<img src="docs/icon.png" width="128" alt="App icon: a white envelope on a pink rounded square">

A native macOS mail client in SwiftUI. It starts as a faithful replica of the Apple Mail main window, and the goal is to connect it to real mail servers.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/dark.png">
  <img alt="Three-column mail window: mailboxes sidebar, message list with category bar, message view" src="docs/screenshots/light.png">
</picture>

> **Status:** reads and changes mail on on-prem Exchange over EWS. Without an account it shows built-in sample messages. See [Roadmap](#roadmap).

## Features

- **Exchange accounts over EWS:** sign in under Settings ▸ Accounts with email, `DOMAIN\user`, password and server, as in iOS Mail. Inbox, Drafts, Sent, Junk, Deleted Items and Archive are synced, and so are your own mail folders and subfolders. What you look at drives the order, as described under [How mail is fetched](#how-mail-is-fetched). The password is kept in the Keychain

- **Meeting invites, as in Outlook:** for each invite you see:
  - when and where, with the required and optional attendees;
  - Accept, Tentative and Decline menus, as in Outlook: Respond with Comments, Respond without Comments, or Do Not Send a Response (only the calendar changes). With Comments opens a message window to the organizer, with the subject Exchange will use ("Declined: …"); its text becomes the comment;
  - Propose New Time, together with Tentative or Decline, in the same message window with a new start and end;
  - "Please respond" until you have answered, and a yellow note when the meeting overlaps other events;
  - the invite's day from your Exchange calendar next to the text, with overlapping events side by side and the invite's slot hatched.

  Attendee answer icons are missing: your copy of an invite reports every attendee's answer as unknown.
- **HTML mail:** shown as the sender laid it out, on a white page also in dark mode. Mail without its own fonts uses Mail's default, Helvetica 14, with Mail's margins. Images, styles and fonts from the web follow Outlook's "Download external images" (Settings ▸ Privacy): by default they load for senders in your organisation (your account's mail domain and its subdomains). Other mail shows Load Remote Content first, so opening it doesn't tell the sender. Images load straight from the sender's server, with no privacy relay like Mail's. The app runs no JavaScript in mail, and links open in your browser. Images attached to the message and shown in its text (`cid:`, such as signature logos) load from Exchange when you open the message; they are kept in memory only, not in the cache. The list, search and replies use the plain-text version, which Exchange sends along
- **Three-column window** with a mailboxes sidebar, a message list and a message view, using Mail's toolbar layout and SF Symbols
- **Favorites and smart mailboxes:** All Inboxes, VIPs, Flagged, Unread, then each account's Inbox, Drafts, Sent, Junk, Trash and Archive, with unread badges
- **Folder trees, as in Mail:** each account's own folders follow its standard mailboxes, sorted by name. Subfolders sit under their parent (for example Inbox ▸ Projects ▸ Launch), behind a disclosure triangle. With more than one account, Favorites ▸ All Inboxes opens into each account's Inbox. Folders are move and drop targets, and the Move menu lists them indented under their parent. From Exchange you get every mail folder below the mailbox root, without calendar, contacts, tasks, Outbox and hidden folders. The folder list is read once per launch, so a folder created elsewhere shows up after a relaunch. Mail in a subfolder of Inbox doesn't count towards All Inboxes, as in Mail
- **Categories:** Primary, Transactions, Updates and Promotions in the Inbox (⌥⌘1–4)
- **Message actions:** reply, reply all, forward, archive, delete, junk, flag in seven colours, mark read or unread. After an action the next message is selected, as in Mail
- **Drag & drop:** drag messages onto a mailbox to move them, also to another account. Drop them on Flagged to flag them, or on All Inboxes to put each back in its own Inbox
- **Search** across the whole account (not Trash or Junk), plus an unread filter
- **Compose window** with reply quoting, Send and Save Draft
- **Swipe actions:** swipe right for Unread, left for Trash or Flag
- **Menu bar and shortcuts** taken from Mail's own `MainMenu.nib`
- **Light and dark mode**
- **Own app icon:** Mail's envelope icon in pink, drawn in code (`AppIcon.swift`). `MAIL_ICON_EXPORT=icon.png` writes it as a PNG. `run.sh` wraps the build in `MailReplica.app` with that icon, so Activity Monitor and system dialogs show it too

## Getting started

You need macOS 14 or later and Swift 6. Command Line Tools are enough; Xcode is not needed.

```sh
git clone https://github.com/tillg/MacExchangeClient.git
cd MacExchangeClient
./run.sh          # build and launch .build/MailReplica.app
./run.sh build    # build only (the bare binary and the .app)
./run.sh test     # run the model tests
```

<details>
<summary>Why <code>run.sh</code> and not <code>swift run</code>?</summary>

In the macOS 27 SDK, `@State` is a macro whose plugin (`SwiftUIMacros`) ships only with Xcode. So `run.sh` builds the app against the macOS 26.5 SDK. The tests use the default SDK, because the Swift Testing macros live there, and get their own build folder (`.build/tests`) so the two setups don't spoil each other's cache. With Xcode installed, `swift run` works as is.
</details>

### Connecting to Exchange

Open Settings (⌘,) ▸ Accounts and sign in. The server can be a host name (`mail.example.com`, expanded to `https://mail.example.com/EWS/Exchange.asmx`) or a full EWS URL. The app checks the credentials before saving anything.

Changes to Exchange mail show at once and are then written to the server in order: read state (without sending read receipts), flags, moves (Archive, Junk, Trash, drag & drop), deleting from Trash (recoverable on the server, like Outlook), Send and Save Draft.
- Exchange knows only *flagged*, so flag colours stay on this Mac.
- If the server refuses a change, it is undone and the reason shows under the window title.
- Offline, changes wait until the next refresh. A message that fails to send is never resent automatically. It is kept in Drafts on this Mac instead.
- Exchange messages can't be dragged to another account yet.

Exchange mail, sync positions, the folder tree and unsent changes are kept in a SQLite database, `~/Library/Application Support/MailReplica/Mail.sqlite`, readable only by you. There is one row per message, like Mail's Envelope Index, so:

- **Launch:** the Inboxes load first and show at once, about 0.1s for 2,870 messages. The other mailboxes follow in the background, about 4s for 180,000 messages on a busy machine, while “Loading Mail…” shows in the sidebar. The Inbox is checked with the server meanwhile. Other mailboxes are synced only once their mail is in memory, and changes waiting for Exchange go out after that.
- **Saving:** changes are written every 15 seconds and on quit, off the main thread, only what changed: one flag change is one row, a few milliseconds.
- **Upgrading:** the first launch with the database moves the old `Cache.json` into it, which takes a while for a big cache (31s for 180,000 messages on a busy machine). The sidebar shows “Updating Mail Storage…” meanwhile. The database is built under a temporary name and gets its real name only once the count matches. Quit midway, and the next launch imports again. Afterwards the old file is renamed to `Cache.json.imported`; delete it once you're happy. To go back, delete `Mail.sqlite*` and rename `Cache.json.imported` to `Cache.json`.

Messages are still all held in memory, and the list, counts and search work on that, as before. Sample data is never stored. Delete `Mail.sqlite` (and its `-wal` and `-shm` files) to start fresh.

`MAIL_SAMPLE_DATA=1 ./run.sh` shows the sample data even when an account is set up.

**Keychain prompt after every build:** each new build asks for the login password once before it can read the Exchange password. `./make-signing-identity.sh` creates a self-signed certificate "MailReplica Dev", and `run.sh` signs each build with it, but that does not stop the prompt. A certificate without an Apple Team ID gives the Keychain nothing stable to recognise, so it ties access to the exact binary. Checked on 2026-11-11: a rebuilt binary with the same certificate was refused the item the previous build had stored. Signing with an Apple Development certificate (with a Team ID) should end the prompts, but this hasn't been tried yet. Remove the self-signed certificate with `security delete-identity -c "MailReplica Dev"`.

### How mail is fetched

What's on screen comes first:

1. **Quick check:** every 15 seconds, and at once when you select a mailbox. It covers only the Inbox and the selected mailbox. A fully synced folder is asked only for changes, one small request of about 0.05s. A folder still syncing gets its newest 50 messages, about 0.1s.
2. **Bodies:** loaded when you open a message.
3. **History, in the background:** first the newest 200 messages of every folder. Then each folder's full contents, one page of 512 at a time. The selected mailbox goes first, your own folders come after the standard ones, and Sent comes last. While it runs, the sidebar shows "Synchronizing “Exchange”" with a progress bar based on the server's message counts. It never holds up the quick check.

4. **Folders not on screen:** once history is done, fully synced folders are also asked for changes, one small request each.

If Exchange rejects the password, the app stops sending requests for that account until you relaunch, because repeated wrong passwords lock domain accounts. A folder whose history fails is skipped, and the error stays under the window title.

A change you made that hasn't reached the server yet is kept when a sync reports the old state. Sidebar counts and the message list are computed once per change, so a mailbox with 70,000 messages stays smooth.

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
  MailModel/        MailStore (@MainActor @Observable), the models, MailDatabase (SQLite), the drag payload and the MailBackend protocol
  EWS/              MailBackend over Exchange Web Services, Keychain and account settings
  MailReplica/      SwiftUI views, MailCommands (menu bar), DebugSnapshot
Tests/
  MailModelTests/   Swift Testing suites for MailStore, the database, the drag payload and EWS requests and parsing (139 tests, plus live tests against a real server)
docs/screenshots/   README images
run.sh              build / launch / test
```

Views stay thin. Every action is a method on `MailStore`, and each one has a test.

`MailStore` talks to servers only through the `MailBackend` protocol: folders, newest messages, sync with an opaque token, and message bodies. EWS is one implementation; Microsoft Graph will be another, with the token holding a Graph delta link. The data store doesn't change.

The live EWS tests run only with `EWS_USER` (`DOMAIN\user`) and `EWS_SERVER` set and the password in the Keychain (service `MailReplica-EWS`, account = username). Otherwise they are skipped. The read test only reads. The write test also needs `EWS_WRITE_TEST=1`. It works only inside the folder `MailReplica-Test` (created if missing), on a message it creates there itself, and never sends mail. `EWS_DEBUG=1` logs which sign-in method was used. `EWS_PROBE=1` lists which fields a real invite carries, never values. `EWS_TIMING=1` prints read-only timings and folder sizes, never mail content. `MAIL_CACHE_PROBE=1` times loading your real `Cache.json` and moving a copy of it into SQLite, and prints only sizes and counts. Run the live tests on their own (`--filter EWSLive`): the performance tests hold the main thread and would skew their timings.

### Screenshots without screen recording

The app can save a PNG of its window and quit. This checks the UI without screen-recording permission:

```sh
MAIL_SNAPSHOT=$PWD/tmp/snap.png .build/debug/MailReplica
MAIL_SNAPSHOT=$PWD/tmp/snap-dark.png MAIL_SNAPSHOT_DARK=1 .build/debug/MailReplica
```

`MAIL_SNAPSHOT_SUBJECT="Q4 numbers review"` selects a message by subject (here the sample invite), switching to its category; `"30% off everything this weekend 🌊"` is the sample HTML newsletter. HTML bodies are drawn into the PNG once they have loaded. `MAIL_SNAPSHOT_HTML=mail.html` shows that file as the selected message's HTML body, to check how a particular mail renders. `MAIL_SNAPSHOT_ANSWER=decline` (or `accept`, `tentative`, `propose`) opens the answer window for the selected invite and captures that window. `MAIL_SNAPSHOT_PROGRESS=0.3` shows the progress bar. Use `MAIL_SAMPLE_DATA=1` so no real mail ends up in a screenshot.

## How faithful is it?

The details come from Mail.app's own resources in `/System/Applications/Mail.app/Contents/Resources`: nibs, `MainWindow.toolbar` and `*.loctable`.

✅ read from the bundle · ⚠️ estimated

| Area | What the replica does | Source |
|---|---|---|
| Window | Sidebar, message list, message view | ✅ nibs `MailboxesViewController`, `MessageListListLayoutViewController`, `MessageViewController` |
| Toolbar | toggle sidebar · back/forward · filter · view options · compose ‖ reply/reply all/forward · archive/delete/junk · move · flag ‖ search | ✅ `MainWindow.toolbar` default set and SF Symbol names |
| Sidebar | Favorites, Smart Mailboxes, per-account mailboxes, badges | ✅ `Sidebar*.icns` names · ⚠️ badge rules |
| Folder tree | Own folders after the standard ones, by name; subfolders behind disclosure triangles, closed at launch; a closed folder shows only its own count; All Inboxes opens into one Inbox per account | ⚠️ from memory of Mail, not read from the bundle |
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
- [x] Flags, read state, moves, deletes and sending written back to Exchange
- [ ] Push for new mail (EWS notifications) instead of the 15-second quick check
- [x] Local cache on disk, so a launch doesn't sync everything again
- [x] HTML message view
- [x] Inline images in HTML mail
- [ ] Opening attachments
- [x] Custom folders and subfolders, as a tree
- [ ] Microsoft Graph backend, once the mailbox is reachable there

**Not planned for now:** rules, conversation threading, rich-text compose, Remind Me, Follow Up, Mute, and the separate message window on double-click.
