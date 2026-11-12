---
title: "System description: Mail Replica"
created: 2026-11-12
edited: 2026-11-12
---

# System description: Mail Replica

What the app does today, as the code in `Sources/` implements it. Mail Replica (repo name MacExchangeClient) is a
SwiftUI copy of the macOS Mail main window, built with SwiftPM, that reads and changes mail on an on-prem Exchange
server over EWS, or shows built-in sample data without an account. These files describe current behaviour, including
known bugs; whoever fixes a bug updates the file that describes it. How to build, test and take snapshots:
[`CLAUDE.md`](../../CLAUDE.md) and the root [`README.md`](../../README.md).

| File | Topic |
|---|---|
| [architecture.md](architecture.md) | Targets, data flow store ↔ backend ↔ database, outbox and flush, sync loops, threading |
| [functional.md](functional.md) | What a user can do: mailboxes, list, selection, actions, drag and drop, conversations, compose, invites, settings |
| [domain-model.md](domain-model.md) | `Message`, `Contact` (and `parseList`), `Account`, mailbox kinds, `Attachment`, `Draft`, `Invite`, `ServerChange`/`PendingChange` |
| [search.md](search.md) | Memory search vs FTS5 index search: when each runs, matching rules, scope, limits |
| [storage.md](storage.md) | `Mail.sqlite` schema, encodings, migrations, the `Cache.json` import, saving |
| [ews.md](ews.md) | EWS requests and responses, parsing rules, authentication, account and URL handling |
| [rendering.md](rendering.md) | HTML page, remote content, `cid:` images, list previews, the HTML of sent mail |
| [limitations.md](limitations.md) | Known limits by design; link to the open bug list |
