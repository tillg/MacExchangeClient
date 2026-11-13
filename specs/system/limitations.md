---
title: "Limitations"
created: 2026-11-12
edited: 2026-11-13
---

# Limitations

Known limits of the current design, one line each. Open bugs (with repro probes and priorities) are listed in
[../bugs/README.md](../bugs/README.md); they are not repeated here. Architecture: [architecture.md](architecture.md).

| Limitation | Where |
|---|---|
| Only Exchange over EWS; no IMAP, no Microsoft Graph (planned behind the same `MailBackend`) | [architecture.md](architecture.md#components) |
| New mail is found by polling every 15 s (Inbox and the mailbox on screen); no EWS push notifications | [architecture.md](architecture.md#reading-from-the-server) |
| The folder list is read once per launch; folders created, renamed or deleted elsewhere show after a relaunch (a deleted folder's mail goes then). Folders can't be created, renamed or deleted in the app | `MailStore.refresh`, [ews.md](ews.md#read-operations) |
| Accounts can only be added, not edited or removed, in Settings; every EWS account is named after its email address (no renaming, no display name from the server) | `AccountsSettings.swift` |
| A wrong password pauses the account until relaunch; the password is fixed in the Keychain (`MailReplica-EWS`) | [ews.md](ews.md#transport-ewsclientcall) |
| Exchange mail can't move to another account (drag, Move menu) | [functional.md](functional.md#drag-and-drop) |
| Flag colours stay on this Mac; Exchange stores only flagged/not flagged, and a server flag shows as red | [domain-model.md](domain-model.md#account-and-mailboxes) |
| A send that times out, or was under way when the app quit, is never retried; the message is kept in Drafts on this Mac only. Invite answers under way at a crash are sent again | [architecture.md](architecture.md#writing-to-the-server-the-outbox) |
| Replies and forwards are new messages without `In-Reply-To`/`References`; the server decides on their conversation | [ews.md](ews.md#write-operations) |
| Compose is plain text; HTML is sent only to place JPEG/PNG/GIF pictures; other files are never placed in the sent mail | [rendering.md](rendering.md#html-of-sent-mail) |
| Quoting uses the plain-text body; the HTML of the original isn't quoted or forwarded | `MailStore.draft` |
| No Mail Drop; over the MailTips size limit Send only warns | [functional.md](functional.md#compose) |
| Quitting the app doesn't ask about unsaved compose windows | `ComposeView.swift` |
| Every message is held in memory; the list and counts are computed from memory, not the database | [architecture.md](architecture.md#components) |
| Search is local only: no server search, HTML-only text isn't indexed, results capped at 2,000, the index lags memory up to 15 s | [search.md](search.md#limits) |
| The memory fallback search (sample data, before the index exists) also matches inside words (`report` finds "Misreported"); otherwise it follows the index's rules | [search.md](search.md#memory-path) |
| Bodies are fetched only when a message is shown, so most stored mail has no body to search or quote offline | [architecture.md](architecture.md#reading-from-the-server) |
| Inline images and opened attachments aren't cached across launches; attachments are refetched after the temp folder is cleared | [storage.md](storage.md#what-lives-where) |
| Remote images load straight from the sender's server; no privacy relay | [rendering.md](rendering.md#remote-content) |
| Attendee answers aren't shown: Exchange reports every attendee's answer as unknown on your copy | [functional.md](functional.md#meeting-invites) |
| No rules, categories, VIP management, Remind Me, Follow Up, Mute, separate message windows or conversation grouping in the list | Root `README.md` |
| A sync from the start that is interrupted by quitting doesn't remove mail deleted on the server meanwhile (its noted IDs are in memory only) | [architecture.md](architecture.md#reading-from-the-server) |
| No schema migration framework: the conversation column and the search index are the only upgrades, detected ad hoc | [storage.md](storage.md#migrations) |
| After the first sign-in (launched without accounts) the database isn't opened until relaunch: nothing is saved and search scans memory (`AppSetup.loadMail` runs once at launch) | `AccountsSettings.swift`, `MailReplicaApp.swift` |
| Builds need the macOS 26.5 SDK for the app and a separate build folder for tests (Command Line Tools only) | `CLAUDE.md` |
| Sync with a server has no automated test without a live account (`EWS_USER`, `EWS_SERVER`); mocks aren't used | Root `README.md`, [../bugs/README.md](../bugs/README.md) |
