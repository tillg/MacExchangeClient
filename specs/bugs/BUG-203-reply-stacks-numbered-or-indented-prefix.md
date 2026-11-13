---
title: "Reply to \"Re[2]: …\" or to a subject with a leading blank (\" Re: …\") stacks a second \"Re:\""
priority: P4
area: compose
status: open
found: 2026-11-13
---
Draft id: R5H-05 (probe suites `Probe_R5*` in `probes/Probe_R5*Tests.swift`).

## Summary
`MailStore.draft` recognises only `^(?i:re|aw): ?`. Numbered prefixes ("Re[2]:", written by some list servers and old clients) and a prefix after a leading blank are missed: "Re: Re[2]: Budget", "Re:  Re: Budget".

## Expected
One "Re: " prefix (DECISIONS d-bug-028: a reply prefix is replaced by "Re: ", not stacked; that decision doesn't mention the numbered form or leading blanks; Mail's handling of "Re[2]:" ⚠️ recalled, not checked).

## Repro
Probe `Probe_R5H_Dates/replyDoesNotStackNumberedOrIndentedPrefix`:
```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5H_Dates/replyDoesNotStackNumberedOrIndentedPrefix
```

## Failure output
```
Expectation failed: numbered == "Re: Budget"   Re[2]: → Re: Re[2]: Budget
Expectation failed: indented == "Re: Budget"   ' Re:' → Re:  Re: Budget
```

## Fix idea
In `draft`, trim leading whitespace and widen the patterns to `^(?i:re|aw)(\[\d+\])?: ?` (same for forward).
