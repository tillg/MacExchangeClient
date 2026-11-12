---
title: "Decisions"
created: 2026-11-12
edited: 2026-11-12
---

# 2026-11-12 23:16 — Unattended bug-fix run {#run-2026-11-12-2316}

- **Started by:** user, unattended
- **Task, as given:** > commit & push what we have incl all the bug reports. Then fix the bugs that u know how to fix w/o guidance, starting with the high prio ones. After every fix: test, commit & push, update the system description in specs/system, then commit & push & delete the bug report. Continue until all solvable bugs are done. Then test until the next 100 bugs and proceed the same way. Take decisions as good as u can and document them in DECISIONS.md.

## 23:16 — `.pilcrow` is ignored, not committed {#d-pilcrow}

- **Status:** confirmed
- **Context:** "commit what we have" found an untracked `.pilcrow`, which holds an editor's per-file scroll and selection state.
- **Decision:** Add it to `.gitignore`.
- **Why:** It is personal editor state, not project content.

## 23:16 — `specs/system` is created, in the format of the user's other repos {#d-specs-system}

- **Status:** confirmed
- **Context:** The task says to update `specs/system`, but it didn't exist. The user's other repos (e.g. `agents2`) use one Markdown file per topic, with `title/created/edited` frontmatter.
- **Decision:** Write a baseline from code and README first, with one file per area. Each fix then updates the file for its area.
- **Why:** The task asks to "update" it, so a baseline is needed first.

## 23:16 — Process: two commits per bug, stable bug ids {#d-process}

- **Decision:** Each bug gets two commits:
  1. the fix with its regression test (and the What's New line), pushed;
  2. the `specs/system` update together with deleting the bug file and its index row, pushed.
- Bug ids stay stable. New bugs are numbered from BUG-052 on.
- Probes move from `specs/bugs/probes` into `Tests/MailModelTests` as regular tests when their bug is fixed.
- **Hard limits:**
  - Existing tests are never changed to make a fix pass. If a fix needs that, the bug is deferred (`status: deferred` plus a note here).
  - The app is built after each fix, but never launched against a real account. Mail and the `EWS_*` live tests stay untouched.
  - No mocks and no branches.

## 23:16 — Memory-search design question: follow the README rules {#d-memory-search}

- **Status:** decided (reversible)
- **Context:** `specs/bugs/design-question-memory-search-fallback.md`. The README says search matches every word, accent-insensitively, in subject, sender, To, Cc, preview and body. It also says the launch fallback searches memory "as before". The fast-search spec said to keep the memory path unchanged.
- **Decision:** Make the in-memory path follow the same matching rules as the index:
  - every word must match, at the start of a word;
  - case and accents don't matter;
  - the fields searched are subject, sender, To, Cc, preview and body.
  
  This is filed as BUG-052.
- **Why:** Users can't tell which path they are on. Search giving different results in the first seconds after launch looks broken. The existing in-memory search tests use single words, so they keep passing.
- **Alternatives:** Keep "as before". That was rejected, because it keeps two behaviours.
