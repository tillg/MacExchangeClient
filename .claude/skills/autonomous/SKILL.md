---
name: autonomous
description: Working alone, w/o having the user for feedback or answering questions. Use when user wants to make progress on a plan but doesn't have the time or energy or is not available.
argument-hint: "[task]"
metadata:
  author: Till Gartner
---

The user is away from the computer. Finish the task, even if you have to make assumptions and
decisions on your own. Don't wait for user feedback to keep making progress.

**Input**: the task. If it is a spec change (`specs/changes/<name>/` with the `spec` plugin
installed), the task is its plan: work through it as `/spec:apply` does.

**Driving spec skills.** The spec skills are user-invoked only, so the Skill tool can't call
them: read the skill's `SKILL.md` (in the spec plugin's `skills/<name>/`) and follow it. Their
rules for "inside an `/autonomous` run" apply to you. When the plan has `Depends on:` lines and
at least 2 steps are ready at once, apply with `--parallel` (step 4b of `/spec:apply`);
otherwise — or when a `--parallel` precondition fails — apply sequentially and log that once.

## Whatever it takes

Invoking `/autonomous` is the user's **standing permission** for every action the task needs
to move on — including what other runs must ask about. Typical examples, not a whitelist:

- **Commit** each green unit of work (a plan step, a fix, a test) — only with the full suite
  green, or with **no new failures** when the suite was already red before the run (log that
  baseline once); never with `--no-verify`. Stage only the files this unit changed; a file
  that was already dirty before the run is never committed — log it and leave it for the
  user. End the message with trailers — the **decision trailer**
  `Decision: <decision id, e.g. run-2026-10-05-1430-2>` when the commit carries out a
  logged decision, `Refs #N` / `Closes #N` for issues.
- **Push** the current branch after each green commit (`git push -u origin <branch>` if it has
  no upstream).
  - Rejected because the remote moved on → `git pull --rebase` (it rewrites only your own
    unpushed commits), run the suite, push. A rebase conflict → `git rebase --abort`, log it,
    stop pushing for this run and keep committing locally. At most 3 attempts per push.
  - Rejected because the branch is protected → create a new branch `autonomous/<task-slug>`
    from `HEAD` (add `-2`, `-3`, … if it exists), switch to it, push it, open **one** PR, and
    keep committing and pushing there for the rest of the run. Leave the local default branch
    as it is (it is now ahead of its remote) and say so in the report.
- **Write to the issue tracker** (rules: the spec plugin's `reference/issue-tracker.md`, else
  `docs/agents/issue-tracker.md` directly): file bugs you find while testing (with the
  label `docs/agents/triage-labels.md` maps the `needs-triage` role to — no label if that
  file doesn't exist), comment progress, and close an issue once its fix is **on the default
  branch** (a fix still on an unmerged branch or PR gets a comment, not a close). Every issue,
  comment and PR body starts with the **AI disclaimer**
  `> Written by Claude (/autonomous) while the user was away.`
- **Archive** a finished, reviewed spec change (`/spec:archive`) after step 3 (self-review),
  before step 4 (retro) — later fixes become tweaks. Its decision gate has nobody to ask, so the change's decisions stay `open` and are listed in the archive commit's body.
- **Deploy, restart, migrate** when the task or its testing needs it — to **non-production**
  environments, unless the task itself names production; only with the project's documented
  command (README, `justfile`, CI); put the rollback command in the decision's Consequences.
  No documented way → don't improvise one: log it and leave it for the user. Test data goes to
  test environments only.
- **Steps that need a person** (e.g. `/spec:grill`): decide the open questions yourself and log
  them.

**Accountability replaces asking.** Log **one decision per kind** of bent rule (an **override kind**) per run, with
`Overrides` set, on its first occurrence (e.g. "push to the default branch", "create a branch
and PR", "archive past the decision gate", "deploy to staging"); append every later occurrence
of the same kind to that decision's Consequences instead of logging it again. Routine work —
green commits, pushes to a non-default branch, tracker writes — is not a decision; the report
lists it.

## Hard limits

Never, whatever the task. None of these is needed to move on, and none can be undone:

1. **No force-push** and no history rewrite of anything already pushed — revert forward
   instead.
2. **No deleting data you didn't create**: user data, other people's issues or branches,
   production records.
3. **No exposing secrets** — in commits, issues, comments, logs or PRs.

If the only way forward hits a hard limit, find another way, log it, or leave that part open
for the user.

**Steps**

1. **Decide instead of asking**

   Whenever you would ask the user, make a decision based on your best judgement and move on.
   Record every decision and assumption in `DECISIONS.md` at the project root, exactly in the
   format of `decisions-format.md` (next to this file; read it before the first entry):
   - this invocation is one **run** (`#` heading: start date and time, a summary title, then
     who started it and the task **exactly as the user gave it**);
   - each choice is one **decision** under it (`##` heading: time and the choice, then
     Status `open`, Overrides (only when a guardrail is bent), Context, Question, Decision, Why, Alternatives, Consequences);
   - the **Contents** list at the top gets the run and each decision in the same edit.

   Skills you drive (e.g. `/spec:apply`) add their decisions to this run, not a new one.

   When a decision **bends a guardrail** (a rule from a skill, a CLAUDE.md or the user's
   instructions), fill in its `Overrides` field with the rule and where it lives — once per
   kind, as "Whatever it takes" says. The user reviews these first.

2. **Work until completely done**

   Don't stop until all functionality and all tests are complete. Work test-first: write the
   test, see it fail for the expected reason, implement, then run it and the full suite. Never
   call something done while a test fails, and never weaken, skip or delete a test to get there.
   Commit and push as you go (see "Whatever it takes").

   Use agents as much as possible: parallelize the work, but only across sub-tasks you have
   identified as independent.

3. **Review your own work**

   Once you think you are done, review the work and make sure you didn't miss anything (for a
   spec change: `/spec:adversarial-code-review`). If you find something that needs fixing, fix
   it, don't wait for user feedback.

4. **Retro your own run**

   Before the open-ended testing, follow the `/spec:retro` flow (the spec plugin's `skills/retro/SKILL.md`;
   without the spec plugin, do the same yourself: find what went wrong in the run, pick the
   most mechanical fix per item — test, then lint/hook/CI, then a one-line CLAUDE.md pointer)
   over this run, without asking: apply the **project-level** environment fixes yourself
   (test-first where they have a runtime surface), each logged as a decision; **draft** the
   plugin-level issues into the report but don't publish them — other repos can wait for the
   user.

5. **Test until the user comes back**

   Test end-to-end. For a web app use the Playwright MCP: start the stack, enter data (feel free
   to create MANY test entries), try all kinds of functions — the ones just built as well as
   regressions. Create, search, edit, delete data. Without a UI, exercise the CLI or API the same
   way. Fix what you find (test first) and log any choice involved. Test forever, until the user
   comes back. Before reporting, add any new findings to the retro.

6. **Report**

   When the user returns (or there is truly nothing left), present:
   - this run's decisions from `DECISIONS.md` (titles, statuses, overrides first, with a link to
     the file — or to its HTML page if `/spec:view` is running);
   - every **commit, push, branch/PR, tracker write, archive and deploy** of the run;
   - the retro: fixes applied, plugin issues drafted;
   - what was built and tested, and what is still open (including anything a hard limit
     blocked).

**Guardrails**

- The hard limits above are absolute; everything else is allowed when the task needs it — and
  logged.
- Edit `DECISIONS.md` and spec files with the Edit/Write tools, not sed/python in Bash, so the
  md2html lint hook (if installed) checks them.
