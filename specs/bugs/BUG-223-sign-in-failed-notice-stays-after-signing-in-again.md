---
title: "After signing in again in Settings, the status line keeps saying sign-in failed, \"relaunch… Nothing is sent until then\", while mail is checked and sent"
priority: P3
area: MailStore
status: open
found: 2026-11-13
---
Draft id: R5G-03 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
A 401 pauses the account (`pauseIfSignInFailed`) and sets the status "Sign-in to “X” failed. Update the password in the Keychain (MailReplica-EWS), then relaunch. Nothing is sent until then." Settings ▸ Accounts ▸ Sign In with the right password reconnects the account: `add(_:backend:)` lifts the pause (d-bug-056) and `signIn` runs a check, which succeeds. The notice stays: a successful check clears only `connectionNotices`, and the sign-in notice isn't one. The user is told to relaunch and that nothing is sent, although the account works. The same holds for AppSetup's "Password needed for … Sign in again in Settings ▸ Accounts." after signing in (same cause: sign-in notices are never cleared by a sign-in).

## Expected
Once the account is signed in again and checked, the notice that says it is paused goes (DECISIONS d-bug-056: signing in again "lifts a sign-in pause"; functional.md: Sign In "reconnects that account"). A notice that is no longer true is misleading.

## Repro
`EWSFlowTests/Probe_R5GRaces/signingInAgainClearsTheSignInFailedNotice` (loopback server):
```
swift test --package-path W --scratch-path W/.build/tests --skip-build --filter Probe_R5GRaces/signingInAgainClearsTheSignInFailedNotice
```

## Failure output
```
Expectation failed: s.status != notice
after signing in again and a successful check the status still says: Sign-in to “Exchange” failed. Update the password in the Keychain (MailReplica-EWS), then relaunch. Nothing is sent until then.
```

## Fix idea
Note the pause notice per account like `connectionNotices` (`pauseIfSignInFailed` → `connectionNotice`), or clear it in `add(_:backend:)` when it lifts the pause (`status == pausedNotice` → nil). AppSetup's "Password needed" notice likewise.
