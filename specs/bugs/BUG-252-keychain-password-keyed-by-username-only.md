---
title: 'Two accounts with the same username on different servers share one Keychain password: signing in to one overwrites the other''s, and each server is sent the other''s password'
priority: P2
area: Accounts / Keychain
status: open
found: 2026-11-13
---

## Summary
The Keychain item is a generic password under service `MailReplica-EWS` with the username as its only key
(`Sources/EWS/ExchangeAccount.swift`):

```swift
public static func password(for user: String) -> String? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                            kSecAttrAccount as String: user, kSecReturnData as String: true]
public static func setPassword(_ password: String, for user: String) -> Bool {
    … SecItemDelete(q as CFDictionary) …   // q = service + username, no server
```

`backend()` and `AccountsSettings.signIn` look the password up by `username` alone. Two accounts that share a
username but live on different servers (the same address on an on-prem and a migration/test server, or the same
`DOMAIN\me` behind two hosts) therefore share one item:

- Signing in to the second account deletes and replaces the first account's password. At the next launch the first
  account sends the second server's password, gets 401 and is paused ("Sign-in … failed"); every relaunch repeats
  the wrong-password attempt against that domain, which counts towards an AD lockout (README: "repeated wrong
  passwords lock domain accounts").
- With the password field left empty ("Leave empty to use the Keychain"), Sign In sends the stored password of the
  *other* server's account to the newly typed server, which need not be trusted.

## Expected
Each account's password belongs to that account: the Keychain item should be keyed by server and username (or by
the account ID). DECISIONS d-bug-124: accounts must "be told apart"; ews.md: `backend()` uses "a Keychain
password for `username`" — the design never considered two accounts with one username. Plain security: a
credential for one server must not be sent to another.

## Repro
No probe: the brief forbids writing Keychain items, and the lookup has no pure helper. Code reading of
`Keychain.password(for:)` / `Keychain.setPassword(_:for:)` (above), `ExchangeAccount.backend()` and
`AccountsSettings.signIn()` (`Keychain.password(for: username)`, `Keychain.setPassword(password, for: username)`).
Manual repro with a test Keychain: add account A (`DOMAIN\me` @ a.example.com, password PA), then account B
(`DOMAIN\me` @ b.example.com, password PB); `security find-generic-password -s MailReplica-EWS -a 'DOMAIN\me' -w`
would then print PB, and A's `backend()` would use PB (not run: no Keychain writes allowed).

## Failure output
None (code reading).

## Fix idea
Key the item by server too (`kSecClassInternetPassword` with `kSecAttrServer` = `ewsURL.host`, or account = 
`"\(username)@\(host)"`), falling back to the old username-only item once for migration; pass the account (not the
username) to `Keychain`.
