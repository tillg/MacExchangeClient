---
title: "A recipient typed as \"Name <>\" makes the whole send fail (empty EmailAddress is schema-invalid)"
priority: P3
area: ews
status: open
found: 2026-11-13
---

## Summary
`Contact.parseList` turns `Bob <>` (or `Bob <  >`) into a contact with an empty address, and `EWSBackend.createRequest`
writes it as `<t:Mailbox><t:Name>Bob</t:Name><t:EmailAddress></t:EmailAddress></t:Mailbox>`. Microsoft's schema
doesn't allow an empty `EmailAddress`. Exchange rejects the whole CreateItem, so the message doesn't reach the other,
valid recipients either. It is kept in Drafts with an error that doesn't say which recipient is wrong. Send is enabled
because To isn't blank.

This differs from BUG-195, where the parser builds a wrong but non-empty address from group or comment syntax. Here the
request builder writes an empty address. BUG-068 fixed the `<>` in reply attributions, not this.

## Expected
- https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/emailaddress-nonemptystringtype
  (fetched): type **NonEmptyStringType**; "Text value: A text value that represents an SMTP address is required.";
  "The EmailAddress element is the only required Mailbox element."; Element information "Can be Empty: False".
- https://learn.microsoft.com/en-us/exchange/client-developer/web-service-reference/responsecode (fetched):
  "**ErrorSchemaValidation**: This error occurs when the request cannot be validated against the schema."
- The captured request fails `xmllint` against the Exchange 2013 SP1 `types.xsd`/`messages.xsd`:
  `Element '{…/types}EmailAddress': [facet 'minLength'] The value has a length of '0'; this underruns the allowed minimum length of '1'.`

## Repro
Probe `Probe_R5JTests/r5j02_emptyAddressRecipientNotSentAsEmptyEmailAddress` in `Tests/MailModelTests/Probe_R5JTests.swift`.
It runs the real `EWSBackend.send` over HTTP to a loopback server that records the request body.

```sh
swift test --package-path . --scratch-path .build/tests --skip-build --filter Probe_R5JTests/r5j02_emptyAddressRecipientNotSentAsEmptyEmailAddress
```
(after the test build from CLAUDE.md)

## Failure output
```
Expectation failed: !addresses.contains("")
EmailAddress values sent: ["ann@x.com", ""]
```

## Fix idea
In `EWSBackend.createRequest`'s `recipients`, skip (or, better, have `MailStore.send` refuse with a status naming) a
contact whose `email` is blank after trimming.
