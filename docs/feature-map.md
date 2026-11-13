---
title: "Feature map: what Apple Mail and Outlook have that we don't"
created: 2026-11-13
edited: 2026-11-13
---

# Feature map

121 features that **Apple Mail** (macOS) and/or **Microsoft Outlook** have and this app (MailReplica / MacExchangeClient) doesn't, as of 2026-11-13. Each chapter explains the feature so that anyone can follow it, says who has it and what we have today. The list is sorted by priority, from HIGH to LOW.

**How priority was set.** This app is used for daily work with an on-prem Exchange mailbox. So:

- **HIGH:** you miss it every day, losing it costs mail or time, or every other mail app has it.
- **MEDIUM:** you miss it every week, or it makes a common task much quicker.
- **LOW:** nice to have, rarely used, or only possible with services this app can't use (iCloud, Microsoft 365 cloud only).

Labels used in the chapters:

- *Not planned:* the [README](../README.md#roadmap) says the project decided against it for now. Kept in the list, and ranked MEDIUM or LOW, except rich text (chapter 5): without it, replies lose the look of the mail they answer, which hurts every day.
- *Specced:* a change spec for it exists in [`specs/changes/`](../specs/changes/).
- *Not possible here:* needs a service only Apple or Microsoft can offer.

**Where the facts come from.** Apple Mail's menu names and shortcuts were read from its own app bundle (`/System/Applications/Mail.app/Contents/Resources`: `MainMenu.nib`, context-menu nibs, `*.loctable`). Outlook's come from the text files of Outlook for Mac (new Outlook) and from Microsoft support pages that were fetched and read; only those pages are linked. A claim marked ⚠️ is recalled, not read from either source. "Mail" in this file means Apple Mail.

**About the pictures.** Real screenshots couldn't be taken: this Mac blocks screen recording, and copying Apple's or Microsoft's images into this repo isn't allowed. The pictures are **sketches** drawn in text. They show the idea, not the exact look.

## Contents

**HIGH**

1. [Email signatures](#1-email-signatures)
2. [Address autocomplete](#2-address-autocomplete)
3. [Company address book lookup](#3-company-address-book-lookup)
4. [Bcc field](#4-bcc-field)
5. [Rich text formatting](#5-rich-text-formatting)
6. [Replies keep the original look](#6-replies-keep-the-original-look)
7. [Undo for delete and move](#7-undo-for-delete-and-move)
8. [Undo Send](#8-undo-send)
9. [New mail notifications](#9-new-mail-notifications)
10. [Unread count on the Dock icon](#10-unread-count-on-the-dock-icon)
11. [Instant new mail](#11-instant-new-mail)
12. [Create, rename and delete folders](#12-create-rename-and-delete-folders)
13. [Out of Office replies](#13-out-of-office-replies)
14. [Edit and remove accounts](#14-edit-and-remove-accounts)
15. [Search on the server](#15-search-on-the-server)
16. [Find text inside a message](#16-find-text-inside-a-message)
17. [Print a message](#17-print-a-message)
18. [Sort the message list](#18-sort-the-message-list)
19. [Ask before quitting with unsent messages](#19-ask-before-quitting-with-unsent-messages)
20. [Be the default email app](#20-be-the-default-email-app)
21. [Spell checking while typing](#21-spell-checking-while-typing)
22. [Shared mailboxes](#22-shared-mailboxes)
23. [Send from another address or on behalf of someone](#23-send-from-another-address-or-on-behalf-of-someone)

**MEDIUM**

24. [Open a message in its own window](#24-open-a-message-in-its-own-window)
25. [Open a conversation in the list](#25-open-a-conversation-in-the-list)
26. [Follow-up flags with due dates](#26-follow-up-flags-with-due-dates)
27. [Rules](#27-rules)
28. [Your own smart mailboxes](#28-your-own-smart-mailboxes)
29. [Save a search](#29-save-a-search)
30. [Search filters](#30-search-filters)
31. [Search in this mailbox only](#31-search-in-this-mailbox-only)
32. [Highlight search words in the message](#32-highlight-search-words-in-the-message)
33. [Jump to a mailbox by typing](#33-jump-to-a-mailbox-by-typing)
34. [Move to a folder by typing](#34-move-to-a-folder-by-typing)
35. [Add any mailbox to Favorites](#35-add-any-mailbox-to-favorites)
36. [Empty the Trash and Junk](#36-empty-the-trash-and-junk)
37. [Recover deleted items](#37-recover-deleted-items)
38. [Manage VIPs](#38-manage-vips)
39. [Block a sender](#39-block-a-sender)
40. [Junk mail settings and safe senders](#40-junk-mail-settings-and-safe-senders)
41. [Report phishing](#41-report-phishing)
42. [Unsubscribe with one click](#42-unsubscribe-with-one-click)
43. [Always load pictures from a trusted sender](#43-always-load-pictures-from-a-trusted-sender)
44. [Send Later](#44-send-later)
45. [Forgotten attachment reminder](#45-forgotten-attachment-reminder)
46. [Recipient warnings](#46-recipient-warnings)
47. [Priority of a message](#47-priority-of-a-message)
48. [Read receipts](#48-read-receipts)
49. [Contact card for a sender](#49-contact-card-for-a-sender)
50. [Add sender to Contacts](#50-add-sender-to-contacts)
51. [Reply with only the selected text](#51-reply-with-only-the-selected-text)
52. [Forward as attachment](#52-forward-as-attachment)
53. [Export as PDF](#53-export-as-pdf)
54. [Make the text bigger or smaller](#54-make-the-text-bigger-or-smaller)
55. [Choose when mail counts as read](#55-choose-when-mail-counts-as-read)
56. [Choose the window layout](#56-choose-the-window-layout)
57. [Move Exchange mail to another account](#57-move-exchange-mail-to-another-account)
58. [Your full name on sent mail](#58-your-full-name-on-sent-mail)
59. [Other account types](#59-other-account-types)
60. [Microsoft 365 accounts](#60-microsoft-365-accounts)
61. [Signed and encrypted mail](#61-signed-and-encrypted-mail)
62. [Online Archive](#62-online-archive)
63. [Show all headers and the raw source](#63-show-all-headers-and-the-raw-source)

**LOW**

64. [Remind Me and Snooze](#64-remind-me-and-snooze)
65. [Pin a message](#65-pin-a-message)
66. [Mute or ignore a conversation](#66-mute-or-ignore-a-conversation)
67. [Categories](#67-categories)
68. [Focused Inbox and mail categories](#68-focused-inbox-and-mail-categories)
69. [Quick Steps](#69-quick-steps)
70. [Sweep](#70-sweep)
71. [Clean Up Conversation](#71-clean-up-conversation)
72. [Templates](#72-templates)
73. [Text snippets](#73-text-snippets)
74. [Redirect](#74-redirect)
75. [Resend a message](#75-resend-a-message)
76. [Copy to a folder](#76-copy-to-a-folder)
77. [Move Again](#77-move-again)
78. [Recall a message](#78-recall-a-message)
79. [Voting buttons](#79-voting-buttons)
80. [Sensitivity and protection labels](#80-sensitivity-and-protection-labels)
81. [Mentions](#81-mentions)
82. [Reactions](#82-reactions)
83. [Translate a message](#83-translate-a-message)
84. [Summaries and writing help](#84-summaries-and-writing-help)
85. [Smart Replies](#85-smart-replies)
86. [Markup and drawings](#86-markup-and-drawings)
87. [Insert photos from iPhone](#87-insert-photos-from-iphone)
88. [Photo browser](#88-photo-browser)
89. [Shrink pictures before sending](#89-shrink-pictures-before-sending)
90. [Link previews](#90-link-previews)
91. [Cloud links for big files](#91-cloud-links-for-big-files)
92. [Mail Drop](#92-mail-drop)
93. [Hide My Email](#93-hide-my-email)
94. [Mail Privacy Protection](#94-mail-privacy-protection)
95. [Save a message as a file](#95-save-a-message-as-a-file)
96. [Open a saved message file](#96-open-a-saved-message-file)
97. [Import mailboxes](#97-import-mailboxes)
98. [Export a mailbox](#98-export-a-mailbox)
99. [Empty Trash and Junk automatically](#99-empty-trash-and-junk-automatically)
100. [Account info and storage quota](#100-account-info-and-storage-quota)
101. [Connection Doctor and Activity window](#101-connection-doctor-and-activity-window)
102. [How often to check for mail](#102-how-often-to-check-for-mail)
103. [Work offline](#103-work-offline)
104. [New mail sounds](#104-new-mail-sounds)
105. [Fonts and colors settings](#105-fonts-and-colors-settings)
106. [Preview lines and list density](#106-preview-lines-and-list-density)
107. [Customize the toolbar](#107-customize-the-toolbar)
108. [Folder colors and sorting](#108-folder-colors-and-sorting)
109. [Group the list](#109-group-the-list)
110. [Conditional formatting](#110-conditional-formatting)
111. [Delegates and folder sharing](#111-delegates-and-folder-sharing)
112. [Public folders](#112-public-folders)
113. [Retention policies](#113-retention-policies)
114. [Expand a distribution list](#114-expand-a-distribution-list)
115. [Automatic Cc or Bcc to myself](#115-automatic-cc-or-bcc-to-myself)
116. [Quote levels and paste as quotation](#116-quote-levels-and-paste-as-quotation)
117. [Who answered a meeting](#117-who-answered-a-meeting)
118. [Shortcuts and AppleScript](#118-shortcuts-and-applescript)
119. [Accessibility checker](#119-accessibility-checker)
120. [Read aloud](#120-read-aloud)
121. [Tabs](#121-tabs)

## HIGH priority

### 1. Email signatures

- **Priority:** HIGH
- **Who has it:** Mail (Settings ▸ Signatures, one or more per account, a signature picker in the compose header) · Outlook (Preferences ▸ Signatures, a default per account)
- **What it is (ELI5):** A signature is the "goodbye card" at the bottom of every mail: your name, job, phone number, maybe the company logo. You write it once, and the app adds it to every new mail, reply and forward by itself, so you never type it again.
- **What we have today:** Nothing. You type your name and details by hand in every message.
- **Picture:**

  ```
  ┌ New Message ───────────────────────────────┐
  │ To:  anna@example.com                       │
  │ Subject: Offer                              │
  │ Signature: [ Work ▾ ]                       │
  ├─────────────────────────────────────────────┤
  │ Hi Anna, here is the offer.                 │
  │                                             │
  │ --                                          │  ← added by itself
  │ Till Example · Project Lead                 │
  │ +49 89 000000 · example.com                 │
  └─────────────────────────────────────────────┘
  ```

### 2. Address autocomplete

- **Priority:** HIGH
- **Who has it:** Mail (Edit ▸ Complete, ⌥⎋, and suggestions while typing; Window ▸ Previous Recipients) · Outlook (suggestions while typing, from people you wrote to and the company directory)
- **What it is (ELI5):** When you type "ann" in the To field, the app guesses "Anna Schmidt <anna@example.com>" and you just press Return. Like your phone finishing a word for you, but for email addresses.
- **What we have today:** You must type every address in full. Nothing is suggested.
- **Picture:**

  ```
  To: ann▌
      ┌──────────────────────────────────────┐
      │ Anna Schmidt   anna@example.com      │ ← Return picks it
      │ Annette Wolf   a.wolf@example.com    │
      └──────────────────────────────────────┘
  ```

### 3. Company address book lookup

- **Priority:** HIGH
- **Who has it:** Outlook (Check Names…, Find in Address Book, directory search) · Mail (Exchange accounts look up the directory while you type ⚠️)
- **What it is (ELI5):** Your company has one big phone book with everybody in it (Exchange calls it the Global Address List). The app can look up a colleague there by name, even if you never wrote to them before.
- **What we have today:** No lookup. You need to know the exact address.
- **Picture:**

  ```
  Check Names: [ schmidt          ] [Search]
    Anna Schmidt     Sales      anna.schmidt@example.com
    Bernd Schmidt    IT         b.schmidt@example.com
  ```

### 4. Bcc field

- **Priority:** HIGH
- **Who has it:** Mail (View ▸ Bcc Address Field, ⌥⌘B) · Outlook (Bcc field in the compose window)
- **What it is (ELI5):** "Bcc" is a secret copy. Everyone in To and Cc sees each other, but nobody sees who is in Bcc. Useful when you write to many people who shouldn't see each other's addresses.
- **What we have today:** Only To and Cc. There is no way to send a hidden copy. (Mail also has a **Reply-To** field, View ▸ Reply-To Address Field, ⌥⌘R, to ask answers to go to another address; we don't have that either.)
- **Picture:**

  ```
  To:   team@example.com
  Cc:   boss@example.com
  Bcc:  me@example.com        ← nobody else sees this line
  ```

### 5. Rich text formatting

- **Priority:** HIGH
- **Who has it:** Mail (Format menu: Bold ⌘B, Italic ⌘I, Underline ⌘U, Lists, Alignment, Indentation, fonts and colors; Edit ▸ Add Link… ⌘K; Format ▸ Make Rich Text ⇧⌘T) · Outlook (the formatting ribbon)
- **What it is (ELI5):** Making words **bold**, *slanted*, coloured or bigger, adding bullet lists and clickable links, like in a word processor. It helps people see what is important.
- **What we have today:** Plain text only. Pictures can go in the text, but no bold, lists or links. *Not planned* for now (README: "rich-text compose").
- **Picture:**

  ```
  ┌───────────────────────────────────────────────┐
  │ Helvetica ▾  12 ▾  [B] [I] [U]  ≡ ≡ ≡  • 1.   │ ← format bar
  ├───────────────────────────────────────────────┤
  │ Agenda:                                       │
  │  • Budget  (bold)                             │
  │  • Timeline                                   │
  └───────────────────────────────────────────────┘
  ```

### 6. Replies keep the original look

- **Priority:** HIGH
- **Who has it:** Mail (Settings ▸ Composing: "Respond using the same message format as the original") · Outlook (replies quote the original with its formatting)
- **What it is (ELI5):** When you reply to a nicely laid-out mail (with tables, colours, logos), the quoted original below your answer should still look the same, so the reader can follow the thread.
- **What we have today:** Replies and forwards quote only the plain text of the original. Tables, pictures and colours of the original are lost in the quote.
- **Picture:**

  ```
  Thanks, see below!
  ┌ On Monday, Anna wrote: ───────────────┐
  │ ┌──────────┬──────────┐               │
  │ │ Q1       │ 12,000 € │  ← table and  │
  │ │ Q2       │ 15,500 € │    colours    │
  │ └──────────┴──────────┘    kept       │
  └───────────────────────────────────────┘
  ```

### 7. Undo for delete and move

- **Priority:** HIGH
- **Who has it:** Mail (Edit ▸ Undo, ⌘Z, after Delete, Move, Archive, Flag ⚠️) · Outlook (Edit ▸ Undo ⚠️)
- **What it is (ELI5):** You deleted the wrong mail by accident. Press ⌘Z and it's back where it was, like the "oops" button in every text editor.
- **What we have today:** No undo for actions on messages. A deleted mail must be found in Trash and moved back by hand.
- **Picture:**

  ```
  Edit ▸ Undo Delete Message   ⌘Z
       Redo                    ⇧⌘Z
  ```

### 8. Undo Send

- **Priority:** HIGH
- **Who has it:** Mail ("Undo Send" at the bottom of the sidebar; Settings ▸ Composing: Undo send delay Off / 10 / 20 / 30 seconds) · Outlook (Edit ▸ Undo Send; Mac, new Outlook, web)
- **What it is (ELI5):** After you click Send, the app waits a few seconds before the mail really leaves. If you notice a mistake ("I forgot the attachment!"), you click Undo Send and the mail comes back to you, unsent.
- **What we have today:** Send is final at once.
- **Picture:**

  ```
  ┌ Sidebar ──────────────┐
  │ Inbox            3    │
  │ Sent                  │
  │                       │
  │ Sending… [Undo Send]  │ ← 10 seconds to change your mind
  └───────────────────────┘
  ```

### 9. New mail notifications

- **Priority:** HIGH
- **Who has it:** Mail (Settings ▸ General: New message notifications) · Outlook (Preferences ▸ Notifications: show subject and preview)
- **What it is (ELI5):** When a new mail arrives, a little box pops up in the corner of the screen, even if you are in another app: "Anna: Lunch today?". You don't have to keep looking at the mail window.
- **What we have today:** No notifications. You only see new mail when you look at the app.
- **Picture:**

  ```
                           ┌──────────────────────────────┐
                           │ ✉ Mail                  now  │
                           │ Anna Schmidt                 │
                           │ Lunch today?                 │
                           └──────────────────────────────┘
  ```

### 10. Unread count on the Dock icon

- **Priority:** HIGH
- **Who has it:** Mail (red number on the Dock icon; Settings ▸ General: Dock unread count, Inbox only or all mailboxes) · Outlook (badge count: Focused only or all unread)
- **What it is (ELI5):** A red bubble with a number on the app's icon in the Dock: "5" means five unread mails. One glance tells you if there is something new.
- **What we have today:** The Dock icon never shows a number.
- **Picture:**

  ```
     ┌──────┐
     │  ✉  ⑤│  ← five unread mails
     └──────┘
  ```

### 11. Instant new mail

- **Priority:** HIGH
- **Who has it:** Mail (Exchange accounts: push ⚠️) · Outlook (always connected to Exchange ⚠️)
- **What it is (ELI5):** The server taps the app on the shoulder the moment a new mail arrives, so it shows up within a second, instead of the app asking "anything new?" over and over.
- **What we have today:** The app asks the server every 15 seconds. New mail can take up to 15 seconds to appear. On the [roadmap](../README.md#roadmap) (EWS notifications).

### 12. Create, rename and delete folders

- **Priority:** HIGH
- **Who has it:** Mail (Mailbox ▸ New Mailbox…, Rename…, Delete…; the same in the sidebar's right-click menu) · Outlook (New Folder, Rename, Move, Delete in the folder's right-click menu)
- **What it is (ELI5):** Folders are drawers for your mail. You should be able to make a new drawer ("Project X"), give it another name, or throw it away, right in the app.
- **What we have today:** Folders made elsewhere show up after a relaunch, but you can't make, rename or delete one here. *Specced:* [`create-sub-inbox`](../specs/changes/create-sub-inbox.md).
- **Picture:**

  ```
  Right-click "Projects" ▸ New Mailbox…
                          Rename Mailbox…
                          Delete Mailbox…
  ```

### 13. Out of Office replies

- **Priority:** HIGH
- **Who has it:** Mail (right-click an Exchange account ▸ Out of Office…: until turned off, or between two dates; text for inside and outside the company) · Outlook (Tools ▸ Automatic Replies…)
- **What it is (ELI5):** Before your holiday you write "I'm away until Monday, please ask Ben." The server then answers everybody who writes to you with that note, by itself, while you are on the beach.
- **What we have today:** Must be set in Outlook or the web. *Specced:* [`create-sub-inbox`](../specs/changes/create-sub-inbox.md) (Out of Office… in the mailbox menu).
- **Picture:**

  ```
  ┌ Out of Office ─────────────────────────────┐
  │ ( ) Off                                     │
  │ (•) From [Dec 20] to [Jan 6]                │
  │ Inside my company:                          │
  │ ┌─────────────────────────────────────────┐ │
  │ │ I'm away until Jan 6. Please ask Ben.   │ │
  │ └─────────────────────────────────────────┘ │
  │ Outside my company: [same text ▾]           │
  └─────────────────────────────────────────────┘
  ```

### 14. Edit and remove accounts

- **Priority:** HIGH
- **Who has it:** Mail (Settings ▸ Accounts: description, full name, server settings, enable/disable, remove with −) · Outlook (Preferences ▸ Accounts)
- **What it is (ELI5):** If your password, server or name changes, or you leave a job, you should be able to fix or delete the account in Settings.
- **What we have today:** Accounts can only be added. Changing or removing one isn't possible in the app, and every account is named after its email address.
- **Picture:**

  ```
  ┌ Settings ▸ Accounts ─────────────────────────┐
  │ ● Exchange   │ Description: [ Work         ] │
  │ ● Private    │ Full Name:   [ Till Example ] │
  │              │ Server:      [ mail.example ] │
  │  [+]  [−]    │ [✓] Enable this account        │
  └──────────────────────────────────────────────┘
  ```

### 15. Search on the server

- **Priority:** HIGH
- **Who has it:** Mail (Exchange and IMAP search on the server for mail not on this Mac ⚠️) · Outlook (search Current Folder / Current Mailbox / All Mailboxes, including the Online Archive)
- **What it is (ELI5):** Your mailbox on the server may hold years of mail that isn't on this Mac yet. Server search asks the server to look through all of it, not just what was downloaded.
- **What we have today:** Search looks only at mail stored on this Mac, and only in the text that was loaded. Mail whose text was never opened is searched by subject, people and preview only. See [search.md](../specs/system/search.md).
- **Picture:**

  ```
  🔍 invoice 2019
    On this Mac (12)
    On the server (240)   ← years of mail not downloaded
  ```

### 16. Find text inside a message

- **Priority:** HIGH
- **Who has it:** Mail (Edit ▸ Find ▸ Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G) · Outlook (Find in the message)
- **What it is (ELI5):** In a very long mail, press ⌘F, type "price", and the app jumps to every place where "price" is written, marked in yellow.
- **What we have today:** No find inside the opened message; the Edit menu has no Find (checked: a SwiftUI app's default Edit menu has none).
- **Picture:**

  ```
  ┌ 🔍 price          2 of 5  [<] [>]  Done ┐
   … the total price is 400 € and the price for …
                ^^^^^           ^^^^^ (yellow)
  ```

### 17. Print a message

- **Priority:** HIGH
- **Who has it:** Mail (File ▸ Print… ⌘P; Print button for the toolbar) · Outlook (Print…, Page Setup)
- **What it is (ELI5):** Put the mail on paper, or into a PDF through the print window, e.g. a ticket or an invoice.
- **What we have today:** No Print in the menu. ⌘P does nothing.
- **Picture:**

  ```
  File ▸ Print…   ⌘P
       ┌ Print ───────────────────┐
       │ Printer: [Office ▾]      │
       │ [PDF ▾]  [Cancel] [Print]│
       └──────────────────────────┘
  ```

### 18. Sort the message list

- **Priority:** HIGH
- **Who has it:** Mail (View ▸ Sort By: Attachments, Date, Date Sent, Flags, From, Mailbox, Size, Subject, To, Unread; Ascending / Descending) · Outlook (Sort By, also by Categories, Priority, Account, Folder)
- **What it is (ELI5):** Choose the order of the list: newest first, oldest first, by sender A–Z, biggest first. Like sorting your photos by date or by name.
- **What we have today:** Always newest first. No other order.
- **Picture:**

  ```
  View ▸ Sort By ▸ ✓ Date
                     From
                     Subject
                     Size
                     Unread
                   ───────────
                   ✓ Descending
                     Ascending
  ```

### 19. Ask before quitting with unsent messages

- **Priority:** HIGH
- **Who has it:** Mail (quitting with open compose windows asks to save them as drafts ⚠️) · Outlook (the same ⚠️)
- **What it is (ELI5):** If you quit the app while a half-written mail is open, the app first asks "Save this as a draft?", so your writing isn't lost.
- **What we have today:** Closing one compose window asks. Quitting the whole app doesn't, so unsaved text can be lost.
- **Picture:**

  ```
  ┌──────────────────────────────────────────┐
  │ You have 2 unsent messages.              │
  │ Do you want to review them before quit?  │
  │      [Review…]  [Discard & Quit] [Cancel]│
  └──────────────────────────────────────────┘
  ```

### 20. Be the default email app

- **Priority:** HIGH
- **Who has it:** Mail (Settings ▸ General: Default email reader) · Outlook (sets itself as the default)
- **What it is (ELI5):** When you click an email link on a website ("mailto:"), or choose Share ▸ Email in another app, the Mac opens a new mail in *your* mail app. That only works if the app can be chosen as the default.
- **What we have today:** The app can't open `mailto:` links, so it can't be the default mail app; those clicks open Apple Mail or Outlook.
- **Picture:**

  ```
  Settings ▸ General
    Default email reader: [ MailReplica ▾ ]
  ```

### 21. Spell checking while typing

- **Priority:** HIGH
- **Who has it:** Mail (Edit ▸ Spelling and Grammar; Settings ▸ Composing: Check spelling As I Type / When I Click Send / Never) · Outlook (spelling and grammar, AutoCorrect)
- **What it is (ELI5):** Words with a typo get a red wavy line under them while you write. Right-click shows the right spelling.
- **What we have today:** The compose text has spell checking off, and the Edit menu has no Spelling and Grammar item to turn it on (checked: a SwiftUI app's default Edit menu has none), and there is no setting.
- **Picture:**

  ```
  Ich freu mich auf das Treffn.
                        ~~~~~~~ ← red wave, right-click: "Treffen"
  ```

### 22. Shared mailboxes

- **Priority:** HIGH
- **Who has it:** Outlook (File ▸ Open ▸ Shared Mailbox… and Other User's Folder…) · Mail (Exchange accounts, limited ⚠️)
- **What it is (ELI5):** A team inbox like "support@company.com" that several people can read and answer. It shows up in the sidebar next to your own mailbox.
- **What we have today:** Only your own mailbox. Team mailboxes can't be opened.
- **Picture:**

  ```
  ▾ Exchange
      Inbox
      Sent
  ▾ Support (shared)       ← team mailbox
      Inbox            12
  ```

### 23. Send from another address or on behalf of someone

- **Priority:** HIGH
- **Who has it:** Outlook (From picker; "on behalf of"; send as a shared mailbox) · Mail (From picker; Settings ▸ Accounts: Edit Email Addresses…)
- **What it is (ELI5):** Choose which address a mail comes from: your own, your team address, or your boss's (if you are allowed). The reader then sees e.g. "Ben on behalf of Anna".
- **What we have today:** Mail always goes from the account's own address. There is no From picker.
- **Picture:**

  ```
  From: [ Till Example <till@example.com>      ▾ ]
           Support Team <support@example.com>
           Anna Schmidt (on behalf of)
  ```

## MEDIUM priority

### 24. Open a message in its own window

- **Priority:** MEDIUM
- **Who has it:** Mail (double-click a message, or File ▸ Open Message ⌘O) · Outlook (Open in separate window, ⌘O)
- **What it is (ELI5):** Double-click a mail and it opens in its own window, so you can put it next to another mail or keep it open while you go on reading.
- **What we have today:** Only the reading pane. *Not planned* (README: "the separate message window on double-click").

### 25. Open a conversation in the list

- **Priority:** MEDIUM
- **Who has it:** Mail (click the conversation's number; View ▸ Expand All Conversations / Collapse All Conversations) · Outlook ("Automatically expand a conversation when selected")
- **What it is (ELI5):** A conversation is one row with a number "4" for four mails. Click the arrow and the row opens up, showing each of the four mails as its own small row, so you can pick one.
- **What we have today:** The row shows the count, but doesn't open in the list. The mails are shown together in the reading pane.
- **Picture:**

  ```
  ▾ Jan & Sergio            4   Budget 2027
      Sergio   10:42   Re: Budget 2027
      Jan      09:15   Re: Budget 2027
      You      Mon     Re: Budget 2027
      Jan      Mon     Budget 2027
  ```

### 26. Follow-up flags with due dates

- **Priority:** MEDIUM
- **Who has it:** Outlook (Message ▸ Follow Up: Today, Tomorrow, This Week, Next Week, No Due Date, Custom Date…, Add Reminder…, Mark as Complete) · Mail (only coloured flags)
- **What it is (ELI5):** A flag that says *when* you must deal with a mail: "Tomorrow". The mail then shows up in your to-do list for that day and the app can remind you.
- **What we have today:** Seven flag colours, without dates or reminders. On Exchange the colour stays on this Mac.
- **Learn more:** [Outlook for Mac keyboard shortcuts](https://support.microsoft.com/en-us/accessibility/outlook/mac/keyboard-shortcuts-in-outlook-for-mac) (Follow Up shortcuts)
- **Picture:**

  ```
  Follow Up ▸ Today
              Tomorrow
              This Week
              Next Week
              Custom Date…
              Mark as Complete
  ```

### 27. Rules

- **Priority:** MEDIUM
- **Who has it:** Mail (Settings ▸ Rules; Message ▸ Apply Rules ⌥⌘L) · Outlook (Tools ▸ Rules…; on Exchange the rules live on the server)
- **What it is (ELI5):** Little robots that sort your mail. "If a mail comes from the newsletter, move it to the Newsletter folder." "If the subject says URGENT, flag it red." They work every time a mail arrives.
- **What we have today:** No rules. Rules made in Outlook still run on the Exchange server, but can't be seen or changed here. *Not planned* (README).
- **Picture:**

  ```
  If [any ▾] of the following conditions are met:
     [From ▾]    [contains ▾]   newsletter@shop.com
  Perform the following actions:
     [Move Message ▾]  to mailbox: [Newsletters ▾]
  ```

### 28. Your own smart mailboxes

- **Priority:** MEDIUM
- **Who has it:** Mail (Mailbox ▸ New Smart Mailbox…, Edit Smart Mailbox…, New Smart Mailbox Folder…) · Outlook (Smart Folders, Search Folders)
- **What it is (ELI5):** A "magic folder" that collects mail by a rule you set, without moving it: "all mail from Anna with attachments from the last 30 days". It always stays up to date.
- **What we have today:** Only the built-in ones (All Inboxes, VIPs, Flagged, Unread). You can't make your own.
- **Picture:**

  ```
  Smart Mailbox Name: [ Anna with files ]
  Contains messages that match [all ▾] of:
    [From ▾]            [contains ▾]  anna
    [Contains attachments ▾]
    [Date Received ▾]   [is in the last ▾] 30 days
  ```

### 29. Save a search

- **Priority:** MEDIUM
- **Who has it:** Mail (Save Search toolbar button: turns the search into a smart mailbox) · Outlook (Save Search creates a Smart Folder)
- **What it is (ELI5):** You searched for something you will look for again and again. One click saves the search as a folder in the sidebar, so next time you just click it.
- **What we have today:** A search is gone once you clear the field.
- **Learn more:** [Save a search by using a Smart Folder in Outlook for Mac](https://support.microsoft.com/en-gb/office/save-a-search-by-using-a-smart-folder-in-outlook-for-mac-fd86c4dc-8fc3-495e-8a28-5f670ebfa393)

### 30. Search filters

- **Priority:** MEDIUM
- **Who has it:** Mail (search suggestions: People, Subject, Attachments; date words ⚠️) · Outlook (Advanced Search ⇧⌘F with criteria rows; `hasattachments:yes`, `from:`)
- **What it is (ELI5):** Tell the search *what* you mean: "from Anna" (not mails that just mention Anna), "has attachment", "last week". Like the filters in an online shop.
- **What we have today:** Every word must match somewhere (subject, sender, To, Cc, text). You can't say which field or limit by date or attachments.
- **Learn more:** [Search refiners in Outlook](https://support.microsoft.com/topic/86fe4399-fba1-42e1-8057-6a5d7f99a230)
- **Picture:**

  ```
  🔍 [From: Anna ×] [Has attachment ×] budget▌
  ```

### 31. Search in this mailbox only

- **Priority:** MEDIUM
- **Who has it:** Mail (search bar scope: All or the selected mailbox ⚠️) · Outlook (Current Folder / Current Mailbox / All Mailboxes)
- **What it is (ELI5):** Look only in the folder you are in ("only in Project X"), instead of everywhere.
- **What we have today:** Search always covers the whole account. Settings to include Trash and Junk (Mail: "When searching all mailboxes, include results from Trash / Junk") are missing too.

### 32. Highlight search words in the message

- **Priority:** MEDIUM
- **Who has it:** Mail (search hits are marked in the opened message ⚠️) · Outlook (search terms highlighted ⚠️)
- **What it is (ELI5):** You searched for "invoice". When you open a result, the word "invoice" is coloured yellow, so you see at once why this mail was found.
- **What we have today:** Results open without any marking.

### 33. Jump to a mailbox by typing

- **Priority:** MEDIUM
- **Who has it:** Mail (Mailbox ▸ Open Quickly… ⇧⌘O; Go to Previous / Next Mailbox ⌃⌘[ / ⌃⌘]; Previous / Next Unread Mailbox) · Outlook (Go to Folder…)
- **What it is (ELI5):** With many folders, scrolling is slow. Press a key, type "proj", and you are in "Projects ▸ Launch". Like Spotlight, but for folders.
- **What we have today:** ⌘1–⌘9 for the first mailboxes. Everything else needs the mouse.
- **Picture:**

  ```
  ┌ Open Quickly ─────────────────────┐
  │ 🔍 proj▌                          │
  │   📁 Projects                     │
  │   📁 Projects ▸ Launch            │
  │   📁 Old projects                 │
  └───────────────────────────────────┘
  ```

### 34. Move to a folder by typing

- **Priority:** MEDIUM
- **Who has it:** Outlook (Move ▸ Choose Folder… ⇧⌘M, Copy ⇧⌘C) · Mail (Message ▸ Move to Predicted Mailbox ⌃⌘M; Move to Favorite Mailbox ⌃⌘1–9)
- **What it is (ELI5):** Instead of dragging a mail to a folder, press a shortcut, type part of the folder name and Return. Mail also guesses the right folder for you based on where you put similar mails.
- **What we have today:** Drag & drop or the Move menu with all folders.

### 35. Add any mailbox to Favorites

- **Priority:** MEDIUM
- **Who has it:** Mail (Mailbox ▸ Add Favorite Mailbox…; right-click ▸ Add to Favorites; View ▸ Show Favorites Bar ⇧⌥⌘H) · Outlook (right-click a folder ▸ Add to Favorites)
- **What it is (ELI5):** Put the folders you use most at the top of the sidebar, like bookmarks, so you don't have to search for them.
- **What we have today:** Favorites are fixed. *Specced:* [`create-sub-inbox`](../specs/changes/create-sub-inbox.md).

### 36. Empty the Trash and Junk

- **Priority:** MEDIUM
- **Who has it:** Mail (Mailbox ▸ Erase Deleted Items ⇧⌘⌫; Erase Junk Mail ⌥⌘J) · Outlook (Empty Folder, Empty Junk)
- **What it is (ELI5):** Empty the bin in one go, instead of selecting every mail in Trash and deleting it.
- **What we have today:** Select all in Trash and press Delete. *Specced:* [`create-sub-inbox`](../specs/changes/create-sub-inbox.md) (Erase Deleted Items…).

### 37. Recover deleted items

- **Priority:** MEDIUM
- **Who has it:** Outlook (Recover Deleted Items, Undelete; Exchange) · Mail (no)
- **What it is (ELI5):** Even after you emptied the Trash, Exchange keeps deleted mail for some days. This shows those mails and puts one back.
- **What we have today:** Deleting from Trash is recoverable on the server, but only with Outlook or the web.

### 38. Manage VIPs

- **Priority:** MEDIUM
- **Who has it:** Mail (click the star next to a sender ⚠️, or Add to VIPs / Remove from VIPs; each VIP gets its own mailbox under VIPs)
- **What it is (ELI5):** Mark the most important people (your boss, your partner) with a star. Their mails get a star in the list and their own folder, so you never miss them.
- **What we have today:** A VIPs mailbox and stars exist, but you can't add or remove a VIP.
- **Picture:**

  ```
  ☆ Anna Schmidt   ← click the star: she becomes a VIP
  ★ VIPs
      Anna Schmidt     3
  ```

### 39. Block a sender

- **Priority:** MEDIUM
- **Who has it:** Mail (Block Sender / Unblock Sender in the message menu; Settings ▸ Junk Mail ▸ Blocked: mark as blocked, or move to Trash) · Outlook (Block Sender)
- **What it is (ELI5):** Someone keeps sending you mail you don't want. Block them, and their mails go straight to the bin from then on.
- **What we have today:** Only Move to Junk for single mails.
- **Picture:**

  ```
  ┌───────────────────────────────────────────┐
  │ ⛔ This message is from a blocked sender.  │
  └───────────────────────────────────────────┘
  ```

### 40. Junk mail settings and safe senders

- **Priority:** MEDIUM
- **Who has it:** Mail (Settings ▸ Junk Mail: filter on/off, mark or move, exceptions for senders in Contacts or Previous Recipients, Trust junk mail headers) · Outlook (Preferences ▸ Junk: Safe Senders and Blocked Senders, by address or domain)
- **What it is (ELI5):** Tell the spam filter "mail from this company is always OK" (safe list) or "this domain is always spam" (block list).
- **What we have today:** Junk / Not Junk per message. Exchange's own filter runs on the server, but its lists can't be edited here.

### 41. Report phishing

- **Priority:** MEDIUM
- **Who has it:** Outlook (Message ▸ Report ▸ Report Junk / Report Phishing)
- **What it is (ELI5):** A fake mail tries to steal your password ("your account will be closed, click here"). Report it, and it goes to the IT security team, who can warn everybody.
- **What we have today:** Only Move to Junk. Nobody is told.
- **Learn more:** [Report suspicious messages](https://support.microsoft.com/en-us/office/report-suspicious-messages-101871d4-9894-44e0-9e10-591f94f0164c)

### 42. Unsubscribe with one click

- **Priority:** MEDIUM
- **Who has it:** Mail (Unsubscribe in the message menu, and a banner above newsletters) · Outlook (Message ▸ Unsubscribe)
- **What it is (ELI5):** Newsletters have a hidden "please stop sending me this" address. The app shows an Unsubscribe button that uses it, so you don't need to find the tiny link at the bottom.
- **What we have today:** You must find and click the link in the mail.
- **Picture:**

  ```
  ┌──────────────────────────────────────────────────────┐
  │ ✉ This message is from a mailing list.  [Unsubscribe] │
  └──────────────────────────────────────────────────────┘
  ```

### 43. Always load pictures from a trusted sender

- **Priority:** MEDIUM
- **Who has it:** Outlook ("Automatically download pictures from the Internet: in all messages / from my contacts / never"; per sender "Always download from this sender" ⚠️) · Mail (Settings ▸ Privacy)
- **What it is (ELI5):** Pictures from outside are blocked to protect you. For senders you trust, you want to say "always show pictures from this one", once.
- **What we have today:** Load Remote Content works for one mail at a time. Settings has Always / My organisation / Ask, but nothing per sender or for your contacts.

### 44. Send Later

- **Priority:** MEDIUM
- **Who has it:** Mail (Send Later button next to Send: Send Now, tonight, tomorrow, or a time you pick; Cancel Send Later) · Outlook (Send ▸ Schedule send; needs Exchange 2016 CU5 or later)
- **What it is (ELI5):** Write the mail now, but let it go out tomorrow at 9:00. Useful so you don't send work mail at midnight.
- **What we have today:** Send goes out at once.
- **Learn more:** [Schedule send for Outlook on Mac](https://support.microsoft.com/en-us/office/schedule-send-for-outlook-on-mac-a02097de-76c2-4895-9557-0818ef229024) · [Delay or schedule sending](https://support.microsoft.com/en-us/office/delay-or-schedule-sending-email-messages-026af69f-c287-490a-a72f-6c65793744ba)
- **Picture:**

  ```
  [ Send ▾ ]
      Send Now
      Send 9:00 PM Tonight
      Send 8:00 AM Tomorrow
      Send Later…
  ```

### 45. Forgotten attachment reminder

- **Priority:** MEDIUM
- **Who has it:** Outlook ("You might have forgotten to attach a file.")
- **What it is (ELI5):** You wrote "please find attached" but attached nothing. When you press Send, the app asks: "Did you forget the attachment?"
- **What we have today:** No check.
- **Picture:**

  ```
  ┌──────────────────────────────────────────────┐
  │ You wrote "attached" but there is no file.   │
  │                 [Send Anyway]  [Add File…]   │
  └──────────────────────────────────────────────┘
  ```

### 46. Recipient warnings

- **Priority:** MEDIUM
- **Who has it:** Outlook (MailTips: recipient is outside the company, recipient has an automatic reply on, very large audience)
- **What it is (ELI5):** Before you send, the app warns you: "Anna is on holiday until Monday" or "Ben is outside your company". So you don't send something to the wrong person or wait for an answer that can't come.
- **What we have today:** Only the size limit from MailTips (Message Size in red). No other warnings.
- **Picture:**

  ```
  ┌─────────────────────────────────────────────────┐
  │ ℹ Anna Schmidt: automatic reply: away until 6/1 │
  │ ⚠ ben@other.org is outside your organisation    │
  └─────────────────────────────────────────────────┘
  ```

### 47. Priority of a message

- **Priority:** MEDIUM
- **Who has it:** Mail (Message ▸ Set Priority ▸ Low / Normal / High; View ▸ Priority Field in compose) · Outlook (Importance: High / Normal / Low)
- **What it is (ELI5):** Mark a mail as "urgent" (a red !) or "not urgent" (a blue arrow). The receiver sees the sign in their list.
- **What we have today:** Priority isn't shown on received mail and can't be set when writing.
- **Picture:**

  ```
  ! Anna Schmidt     10:42   ← high priority
  ↓ Newsletter       09:00   ← low priority
  ```

### 48. Read receipts

- **Priority:** MEDIUM
- **Who has it:** Outlook (Options ▸ Request Receipts ▸ Request a Read Receipt / Request a Delivery Receipt) · Mail (no request; doesn't send receipts)
- **What it is (ELI5):** Ask to get a little note back when the receiver opens your mail ("read") or when it reached their mailbox ("delivered").
- **What we have today:** Can't ask for a receipt. Received requests are ignored on purpose (marking read sends none).

### 49. Contact card for a sender

- **Priority:** MEDIUM
- **Who has it:** Mail (click a name: address, Add to Contacts, Add to VIPs, Copy Address, New Email ⚠️; Settings ▸ Viewing: Use Smart Addresses) · Outlook (contact card with phone, office, manager ⚠️)
- **What it is (ELI5):** Click on a sender's name to see who they are: email address, phone, job title, and buttons like "write a new mail" or "copy address".
- **What we have today:** The header is text you can select and copy, but a name can't be clicked: no card, no buttons.
- **Picture:**

  ```
  ┌ Anna Schmidt ────────────────────┐
  │ anna.schmidt@example.com         │
  │ Sales · +49 89 000000            │
  │ [New Email] [Add to VIPs]        │
  │ [Copy Address] [Add to Contacts] │
  └──────────────────────────────────┘
  ```

### 50. Add sender to Contacts

- **Priority:** MEDIUM
- **Who has it:** Mail (Message ▸ Add Sender to Contacts; Add to Contacts toolbar button) · Outlook (Add to Contacts on the contact card)
- **What it is (ELI5):** Put the sender into your address book with one click, so the Contacts app knows them.
- **What we have today:** Not possible from the app.

### 51. Reply with only the selected text

- **Priority:** MEDIUM
- **Who has it:** Mail (Settings ▸ Composing: "Include selected text if any; otherwise include all text") · Outlook ("Only reply to selected text")
- **What it is (ELI5):** Mark one sentence in a long mail and press Reply: only that sentence is quoted, so it's clear what you answer.
- **What we have today:** Reply always quotes the whole mail.

### 52. Forward as attachment

- **Priority:** MEDIUM
- **Who has it:** Mail (Message ▸ Forward as Attachment; Forward Message and Parent as Attachments) · Outlook (Forward As Attachment)
- **What it is (ELI5):** Send a mail on as a file inside a new mail, exactly as it arrived. IT departments often ask for this when you report spam.
- **What we have today:** Only normal forward.

### 53. Export as PDF

- **Priority:** MEDIUM
- **Who has it:** Mail (File ▸ Export as PDF…) · Outlook (Print ▸ Save as PDF)
- **What it is (ELI5):** Save a mail as a PDF file, e.g. a booking confirmation, to keep it or send it on.
- **What we have today:** Not possible (no print either).

### 54. Make the text bigger or smaller

- **Priority:** MEDIUM
- **Who has it:** Mail (Smaller / Bigger toolbar buttons, ⌘+ / ⌘−) · Outlook (zoom)
- **What it is (ELI5):** Make the letters of a mail bigger when they are too small to read, like zooming in a web page.
- **What we have today:** The mail shows at the sender's size, with no zoom.

### 55. Choose when mail counts as read

- **Priority:** MEDIUM
- **Who has it:** Outlook (Preferences ▸ Reading: "When selection changes", "When viewed in the reading pane for N seconds", "Only when opened in a separate window", "Never") · Mail (Settings ▸ Viewing: Mark as read)
- **What it is (ELI5):** Decide when a mail stops being "new": as soon as you click it, after you looked at it for 5 seconds, or only when you say so. Then clicking through the list doesn't hide what you haven't really read.
- **What we have today:** A mail is marked read the moment you select it.
- **Picture:**

  ```
  Mark as read: (•) When selected
                ( ) After [5] seconds
                ( ) Never
  ```

### 56. Choose the window layout

- **Priority:** MEDIUM
- **Who has it:** Mail (View ▸ Use Column Layout, Show Side Preview) · Outlook (View ▸ Reading Pane: Right, Below, Hidden)
- **What it is (ELI5):** Put the mail text to the right of the list, under it, or hide it. On a narrow screen "under" gives longer lines; a table-like list with columns (From, Subject, Date, Size) shows more at once.
- **What we have today:** One layout: three columns side by side.
- **Picture:**

  ```
  Right:                       Below:
  ┌────┬────────┬──────────┐   ┌────┬────────────────────┐
  │    │ list   │  mail    │   │    │ list               │
  │side│        │  text    │   │side├────────────────────┤
  │bar │        │          │   │bar │ mail text          │
  └────┴────────┴──────────┘   └────┴────────────────────┘
  ```

### 57. Move Exchange mail to another account

- **Priority:** MEDIUM
- **Who has it:** Mail (drag between any accounts) · Outlook (Move / Copy between accounts)
- **What it is (ELI5):** Drag a mail from your work account into a folder of your other account.
- **What we have today:** Exchange mail can't be moved to another account (drag or Move menu).

### 58. Your full name on sent mail

- **Priority:** MEDIUM
- **Who has it:** Mail (Settings ▸ Accounts: Full Name, Description) · Outlook (account name from the server)
- **What it is (ELI5):** Choose how you are called in other people's inbox ("Till Example" instead of an address) and how the account is named in the sidebar ("Work").
- **What we have today:** Every account is named after its email address; no name or description can be set.

### 59. Other account types

- **Priority:** MEDIUM
- **Who has it:** Mail (iCloud, Google, Yahoo, IMAP, POP, Exchange) · Outlook (Microsoft 365, Outlook.com, Gmail, iCloud, IMAP)
- **What it is (ELI5):** Read your private mail (Gmail, iCloud, a web host) in the same app as your work mail.
- **What we have today:** Only Exchange over EWS.

### 60. Microsoft 365 accounts

- **Priority:** MEDIUM
- **Who has it:** Mail (Microsoft Exchange sign-in) · Outlook (Microsoft 365 is its main account type)
- **What it is (ELI5):** Companies move their mailboxes from their own server to Microsoft's cloud. Those mailboxes need a different way to connect (Microsoft Graph and a Microsoft sign-in).
- **What we have today:** Only on-prem Exchange. On the [roadmap](../README.md#roadmap) (Microsoft Graph backend).

### 61. Signed and encrypted mail

- **Priority:** MEDIUM
- **Who has it:** Mail (Digitally Sign / Encrypt Message buttons in compose when a certificate is installed) · Outlook (Sign, Encrypt With S/MIME; per-account certificates)
- **What it is (ELI5):** A digital seal on a mail proves it really comes from you and wasn't changed. Encryption locks the mail so only the receiver can open it.
- **What we have today:** Can't sign or encrypt, and a signed or encrypted mail you receive isn't checked or opened.

### 62. Online Archive

- **Priority:** MEDIUM
- **Who has it:** Outlook (Online Archive in the sidebar, Search Online Archive)
- **What it is (ELI5):** Exchange can keep old mail in a second "attic" mailbox to keep the main one small. Outlook shows that attic as its own folder tree.
- **What we have today:** The archive mailbox isn't shown. (Our Archive folder is a normal folder in the main mailbox.)

### 63. Show all headers and the raw source

- **Priority:** MEDIUM
- **Who has it:** Mail (View ▸ Message ▸ All Headers ⇧⌘H, Raw Source ⌥⌘U) · Outlook (View Source)
- **What it is (ELI5):** Every mail has hidden "envelope notes": which servers it passed, spam scores, the real sender. Showing them helps IT find out where a strange mail came from.
- **What we have today:** Not possible.

## LOW priority

### 64. Remind Me and Snooze

- **Priority:** LOW
- **Who has it:** Mail (Message ▸ Remind Me ▸ in 1 Hour / Tonight / Tomorrow / Later…) · Outlook (Snooze: Later Today, Tomorrow, This Weekend, Next Week)
- **What it is (ELI5):** "Not now, show me this again tomorrow." The mail goes away and comes back to the top of the Inbox at the time you picked, like a snooze button on an alarm clock.
- **What we have today:** Nothing. *Not planned* (README: Remind Me).
- **Learn more:** [Snooze in Outlook](https://support.microsoft.com/en-us/article/6c5aa4d4-147a-4a0b-831b-eafc041e6028)

### 65. Pin a message

- **Priority:** LOW
- **Who has it:** Outlook (Pin / Unpin; Mac, new Outlook, web)
- **What it is (ELI5):** Stick a mail to the top of the list with a pin, so it stays there while new mail comes in below.
- **What we have today:** Nothing.

### 66. Mute or ignore a conversation

- **Priority:** LOW
- **Who has it:** Mail (Message ▸ Mute, ⇧⌃M) · Outlook (Ignore Conversation: moves the thread and every later reply to Deleted Items)
- **What it is (ELI5):** A big group discussion you don't care about? Mute it: new answers arrive without bothering you, or go straight to the bin.
- **What we have today:** Nothing. *Not planned* (README: Mute).
- **Learn more:** [Ignore all email messages in a conversation](https://support.microsoft.com/en-us/office/ignore-all-email-messages-in-a-conversation-5ec0c3c2-3440-484e-9aca-0588234d44e9)

### 67. Categories

- **Priority:** LOW
- **Who has it:** Outlook (Message ▸ Categorize; Preferences ▸ Categories; Exchange stores them)
- **What it is (ELI5):** Coloured sticky labels like "Customer A" or "Invoices". A mail can have several, and you can filter by them. Unlike folders, one mail can be in many groups.
- **What we have today:** Removed on purpose (README: "mail categories (removed: not used here)").

### 68. Focused Inbox and mail categories

- **Priority:** LOW
- **Who has it:** Outlook (View ▸ Focused Inbox: Focused / Other) · Mail (View ▸ Show Mail Categories: Primary ⌥⌘1, Transactions ⌥⌘2, Updates ⌥⌘3, Promotions ⌥⌘4, All Mail ⌥⌘5; Show Priority Messages)
- **What it is (ELI5):** The app sorts your Inbox into "important" and "everything else" (shops, newsletters, receipts), so you see real mail from people first.
- **What we have today:** One Inbox. Outlook's Focused Inbox depends on Microsoft 365 ⚠️; Mail's sorting works on this Mac.

### 69. Quick Steps

- **Priority:** LOW
- **Who has it:** Outlook (Quick Steps; Windows, new Outlook, web)
- **What it is (ELI5):** One button that does several things at once, for example "mark as read, move to Done, and reply 'Thanks!'".
- **What we have today:** Nothing.
- **Learn more:** [Quick Steps in Outlook](https://support.microsoft.com/en-gb/office/quick-steps-in-outlook-d8efbdbd-5098-491b-9d2e-8c7b6f45a9b4)

### 70. Sweep

- **Priority:** LOW
- **Who has it:** Outlook (Sweep; new Outlook and web, Microsoft 365 only)
- **What it is (ELI5):** "Delete everything from this shop, and do it again for every new one", or "keep only the newest mail from them". A broom for one sender.
- **What we have today:** Nothing. Needs Microsoft 365, so not possible with on-prem Exchange.
- **Learn more:** [Organize your inbox with Sweep](https://support.microsoft.com/en-au/office/organize-your-inbox-with-sweep-73e36fba-6918-41e8-a0c6-e5700219e918)

### 71. Clean Up Conversation

- **Priority:** LOW
- **Who has it:** Outlook for Windows (Clean Up ⚠️)
- **What it is (ELI5):** In a long back-and-forth, each reply repeats the earlier ones. Clean Up deletes the older mails whose text is already quoted in a newer one, so nothing is lost but the folder is tidier.
- **What we have today:** Nothing.

### 72. Templates

- **Priority:** LOW
- **Who has it:** Outlook (File ▸ Save As Template…; New ▸ Email From Template)
- **What it is (ELI5):** A ready-made mail you use again and again (a weekly report, a standard answer). Open the template, change two words, send.
- **What we have today:** Nothing.

### 73. Text snippets

- **Priority:** LOW
- **Who has it:** Outlook (Quick Parts; Windows and new Outlook)
- **What it is (ELI5):** Saved pieces of text (your bank details, directions to the office) that you insert into any mail with two clicks.
- **What we have today:** Nothing.

### 74. Redirect

- **Priority:** LOW
- **Who has it:** Mail (Message ▸ Redirect ⇧⌘E) · Outlook (Redirect To)
- **What it is (ELI5):** Pass a mail on to someone else *as if it had been sent to them directly*: their answer goes to the original sender, not to you. Good for "this went to the wrong person".
- **What we have today:** Only Forward.

### 75. Resend a message

- **Priority:** LOW
- **Who has it:** Outlook (Message ▸ Resend) · Mail (Send Again, from Sent ⚠️)
- **What it is (ELI5):** Open a mail you already sent as a new mail with the same text and people, change it if needed, and send it again.
- **What we have today:** Nothing.

### 76. Copy to a folder

- **Priority:** LOW
- **Who has it:** Mail (Message ▸ Copy to; Copy toolbar button) · Outlook (Copy to Folder… ⇧⌘C)
- **What it is (ELI5):** Put a copy of a mail into another folder while the original stays where it is.
- **What we have today:** Move only.

### 77. Move Again

- **Priority:** LOW
- **Who has it:** Mail (Message ▸ Move Again)
- **What it is (ELI5):** You just moved a mail to "Receipts". The next one goes there too with one shortcut, without choosing the folder again.
- **What we have today:** Nothing.

### 78. Recall a message

- **Priority:** LOW
- **Who has it:** Outlook (Recall; both people in the same Microsoft 365 company, and the mail not yet opened)
- **What it is (ELI5):** Try to pull back a mail you sent by mistake from the receiver's inbox. Only works in some cases, and you get a report whether it worked.
- **What we have today:** Nothing. Needs Microsoft 365.
- **Learn more:** [Recall an Outlook email message](https://support.microsoft.com/en-us/office/recall-an-outlook-email-message-35027f88-d655-4554-b4f8-6c0729a723a0)

### 79. Voting buttons

- **Priority:** LOW
- **Who has it:** Outlook for Windows (Options ▸ Use Voting Buttons; Exchange)
- **What it is (ELI5):** Add buttons like "Yes / No / Maybe" to a mail. Receivers click one, and you get a tally of who voted what.
- **What we have today:** Nothing.
- **Learn more:** [Use voting buttons in messages](https://support.microsoft.com/en-us/office/use-voting-buttons-in-messages-4d10e079-8ea1-489a-a79c-18cb71ae12dd)

### 80. Sensitivity and protection labels

- **Priority:** LOW
- **Who has it:** Outlook (Sensitivity: Normal, Personal, Private, Confidential ⚠️; sensitivity labels; Restrict Permissions / Do Not Forward)
- **What it is (ELI5):** Stamp a mail "Confidential". With protection, the receiver can't forward, copy or print it.
- **What we have today:** Nothing. Labels and protection need Microsoft 365 services.

### 81. Mentions

- **Priority:** LOW
- **Who has it:** Outlook (type @name in the text: the person is added to To and their name is highlighted; Mentions filter and column in the list)
- **What it is (ELI5):** Write "@Anna can you check this?" and Anna is added to the mail and sees that she was named.
- **What we have today:** Nothing.

### 82. Reactions

- **Priority:** LOW
- **Who has it:** Outlook (Message ▸ React: 👍 ❤️ 😄 …)
- **What it is (ELI5):** Answer with a thumbs-up instead of writing "OK, thanks", like in a chat app.
- **What we have today:** Nothing. Reactions likely need Microsoft 365 ⚠️.

### 83. Translate a message

- **Priority:** LOW
- **Who has it:** Outlook (Translator: the whole mail or a selection)
- **What it is (ELI5):** A mail in a language you don't speak? One click shows it in your language.
- **What we have today:** Nothing (macOS can translate selected text through the right-click menu in some places).
- **Learn more:** [Translator for Outlook](https://support.microsoft.com/en-us/office/translator-for-outlook-3d7e12ed-99d6-406e-a453-b9db0d9653fa)

### 84. Summaries and writing help

- **Priority:** LOW
- **Who has it:** Mail (Apple Intelligence: Summarize, Summarize Message Previews, Writing Tools) · Outlook (Copilot)
- **What it is (ELI5):** A helper reads a long mail and tells you in two lines what it's about, or rewrites your draft to sound friendlier or shorter.
- **What we have today:** Nothing.

### 85. Smart Replies

- **Priority:** LOW
- **Who has it:** Mail (Smart Replies when you reply; Settings: Personalize Smart Replies)
- **What it is (ELI5):** The app offers ready answers like "Sounds good!" or "Can we do Friday?" that you click instead of typing.
- **What we have today:** Nothing.

### 86. Markup and drawings

- **Priority:** LOW
- **Who has it:** Mail (Markup on attached pictures and PDFs; Insert Drawing)
- **What it is (ELI5):** Draw circles and arrows on a screenshot, or sign a PDF, right inside the mail before you send it.
- **What we have today:** Nothing.

### 87. Insert photos from iPhone

- **Priority:** LOW
- **Who has it:** Mail (File ▸ Insert from iPhone or iPad: take a photo or scan a document)
- **What it is (ELI5):** Point your iPhone at a paper, and the scan appears in your mail on the Mac.
- **What we have today:** Nothing.

### 88. Photo browser

- **Priority:** LOW
- **Who has it:** Mail (Window ▸ Photo Browser; Photo / Media Browser button in compose)
- **What it is (ELI5):** A small window with your Photos library, so you can drag a picture into a mail without opening the Photos app.
- **What we have today:** Drag from Photos or Finder works; there is no browser.

### 89. Shrink pictures before sending

- **Priority:** LOW
- **Who has it:** Mail (Image Size in the compose header: Small, Medium, Large, Actual Size, with the new Message Size)
- **What it is (ELI5):** Phone photos are big. Make them smaller before sending, so the mail goes through and loads fast.
- **What we have today:** Pictures go at full size.

### 90. Link previews

- **Priority:** LOW
- **Who has it:** Mail (Show Link Preview; Settings ▸ Composing: Add link previews) · Outlook (link previews)
- **What it is (ELI5):** Paste a web address and it turns into a little card with the page's title and picture.
- **What we have today:** Nothing.

### 91. Cloud links for big files

- **Priority:** LOW
- **Who has it:** Outlook ("Upload to OneDrive and share link")
- **What it is (ELI5):** Instead of attaching a huge file, the app puts it in the cloud and sends a link. The receiver downloads it from there.
- **What we have today:** Files are always attached; over the limit, Send only warns. Needs OneDrive.

### 92. Mail Drop

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Accounts: Send large attachments with Mail Drop; "Use Mail Drop" when a mail is too big)
- **What it is (ELI5):** Apple's version of cloud links: big files go to iCloud for a limited time (30 days ⚠️) and the mail carries a download link.
- **What we have today:** *Not possible here:* Mail Drop needs an Apple Account sign-in and has no API for other apps (README).

### 93. Hide My Email

- **Priority:** LOW
- **Who has it:** Mail (Hide My Email as the From address; iCloud+)
- **What it is (ELI5):** Send from a random made-up address that forwards to you, so a shop never learns your real address.
- **What we have today:** *Not possible here:* needs iCloud+.

### 94. Mail Privacy Protection

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Privacy: Protect Mail Activity, Hide IP Address, Block All Remote Content)
- **What it is (ELI5):** Senders put invisible pictures in mails to learn when and where you opened them. Apple loads all pictures through its own servers, so senders learn nothing.
- **What we have today:** Remote pictures are blocked until you allow them, but when loaded they come straight from the sender. The relay is *not possible here* (Apple's servers).

### 95. Save a message as a file

- **Priority:** LOW
- **Who has it:** Mail (File ▸ Save As… ⇧⌘S: Rich Text Format; Plain Text and Raw Message Source ⚠️; drag a mail to the Finder ⚠️) · Outlook (Save As…; drag to the desktop as .eml)
- **What it is (ELI5):** Keep a mail as a file in a folder on your Mac, e.g. next to the project's documents.
- **What we have today:** Not possible.

### 96. Open a saved message file

- **Priority:** LOW
- **Who has it:** Mail (File ▸ Open Message ⌘O, double-click an .eml file) · Outlook (.eml and .msg)
- **What it is (ELI5):** Someone sent you a mail as a file. Double-click it and it opens like a normal mail.
- **What we have today:** An attached mail opens in another app; the app can't open .eml files itself.

### 97. Import mailboxes

- **Priority:** LOW
- **Who has it:** Mail (File ▸ Import Mailboxes…: from Mail or mbox files) · Outlook (Import: .olm and .pst archives)
- **What it is (ELI5):** Bring old mail saved from another app or computer into this app.
- **What we have today:** Nothing.

### 98. Export a mailbox

- **Priority:** LOW
- **Who has it:** Mail (Mailbox ▸ Export…, with "Export all subfolders") · Outlook (Export to .olm)
- **What it is (ELI5):** Save a whole folder of mail into one file, as a backup or to take it elsewhere.
- **What we have today:** Nothing.

### 99. Empty Trash and Junk automatically

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Accounts ▸ Mailbox Behaviors: Erase deleted messages after a day / week / month / when Mail quits; the same for junk)
- **What it is (ELI5):** The bin empties itself after a while, so you never have to remember it.
- **What we have today:** Nothing (Exchange's server policies may do this on their own).

### 100. Account info and storage quota

- **Priority:** LOW
- **Who has it:** Mail (right-click an account ▸ Get Account Info: Summary, Quota) · Outlook (folder Properties: size)
- **What it is (ELI5):** See how full your mailbox is ("1.8 GB of 2 GB") and which folders take the most space, before the server stops accepting mail.
- **What we have today:** Nothing. *Specced:* [`create-sub-inbox`](../specs/changes/create-sub-inbox.md) (Get Account Info).

### 101. Connection Doctor and Activity window

- **Priority:** LOW
- **Who has it:** Mail (Window ▸ Connection Doctor; Window ▸ Activity ⌥⌘0) · Outlook (Sync Status, Sync Errors)
- **What it is (ELI5):** A small window that says what the app is doing right now ("Sending 1 message…") and checks why an account can't connect.
- **What we have today:** A progress bar in the sidebar and a status line under the window title.

### 102. How often to check for mail

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ General: Check for new messages: Automatically, every minute, 5 / 15 / 30 minutes, every hour, Manually; Mailbox ▸ Synchronize)
- **What it is (ELI5):** Choose how often the app asks for new mail, or "only when I click", to save battery or avoid distraction.
- **What we have today:** Fixed: every 15 seconds.

### 103. Work offline

- **Priority:** LOW
- **Who has it:** Outlook (Work Offline / Set Account Offline)
- **What it is (ELI5):** Tell the app "don't talk to the server now", e.g. on a plane or an expensive hotspot. Changes wait until you go online again.
- **What we have today:** Changes wait when the server can't be reached, but you can't switch offline on purpose.

### 104. New mail sounds

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ General: New messages sound, Play sounds for other mail actions) · Outlook (Notifications: sounds)
- **What it is (ELI5):** A little "ding" when a mail arrives or is sent.
- **What we have today:** Silent.

### 105. Fonts and colors settings

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Fonts & Colors: message list font, message font, fixed-width font for plain text, colour quoted text by level)
- **What it is (ELI5):** Pick the letters and size you like for the list and the mails, and colour each quote level differently so you see who said what.
- **What we have today:** Fixed fonts (Helvetica 14 for mail without its own fonts).

### 106. Preview lines and list density

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Viewing: List Preview: None, 1–5 lines; Show Date and Time, Show To/Cc Label, Show Message Size) · Outlook (View ▸ Display Density: Roomy, Cozy, Compact; Show Message Previews)
- **What it is (ELI5):** Show more or less of each mail in the list: with two lines of text you see more of each mail, with none you see more mails at once.
- **What we have today:** Always two preview lines, one size.

### 107. Customize the toolbar

- **Priority:** LOW
- **Who has it:** Mail (View ▸ Customize Toolbar…: Print, Get Mail, Copy, Redirect, Mark Read, Save Search, Mute and more) · Outlook (Customize Toolbar)
- **What it is (ELI5):** Choose which buttons sit at the top of the window: add the ones you use, remove the ones you don't.
- **What we have today:** A fixed toolbar.

### 108. Folder colors and sorting

- **Priority:** LOW
- **Who has it:** Outlook (folder right-click: Color, Sort Subfolders A to Z, Move, Copy)
- **What it is (ELI5):** Give important folders a colour so you find them faster.
- **What we have today:** Folders are sorted by name and have no colours.

### 109. Group the list

- **Priority:** LOW
- **Who has it:** Outlook (Show Messages in Groups, group headers like Today / Yesterday / Last Week, collapse groups)
- **What it is (ELI5):** Little headings in the list ("Today", "Yesterday", "Last week") split the mails into easy chunks.
- **What we have today:** One plain list.

### 110. Conditional formatting

- **Priority:** LOW
- **Who has it:** Outlook (Windows; partly new Outlook and web)
- **What it is (ELI5):** Colour mails in the list by a rule: "everything from my boss in red".
- **What we have today:** Nothing (VIP stars are the closest).

### 111. Delegates and folder sharing

- **Priority:** LOW
- **Who has it:** Outlook (Preferences ▸ Accounts ▸ Delegates; folder Sharing Permissions…: Owner, Editor, Author, Reviewer)
- **What it is (ELI5):** Let your assistant read and answer your mail, or let a colleague see one of your folders.
- **What we have today:** Nothing (can be set in Outlook; the server keeps it).

### 112. Public folders

- **Priority:** LOW
- **Who has it:** Outlook (File ▸ Open ▸ Public Folders…, subscribe / unsubscribe)
- **What it is (ELI5):** Old-style shared folders that the whole company can read, like a notice board.
- **What we have today:** Nothing.

### 113. Retention policies

- **Priority:** LOW
- **Who has it:** Outlook (Assign policy on a message or folder; Exchange)
- **What it is (ELI5):** Tell the server how long to keep a mail or folder ("delete after 1 year", "archive after 2 years"), following company rules.
- **What we have today:** Nothing (server policies still run).

### 114. Expand a distribution list

- **Priority:** LOW
- **Who has it:** Outlook (Expand Distribution List) · Mail (Settings ▸ Composing: "When sending to a group, show all member addresses")
- **What it is (ELI5):** A group address like "team@company.com" can be opened up into the list of people inside it, so you can remove one person before sending.
- **What we have today:** Nothing.

### 115. Automatic Cc or Bcc to myself

- **Priority:** LOW
- **Who has it:** Mail (Settings ▸ Composing: Automatically Cc / Bcc myself) · Outlook (Composing preferences)
- **What it is (ELI5):** Every mail you send also lands in your own Inbox, as a reminder or a record.
- **What we have today:** Nothing.

### 116. Quote levels and paste as quotation

- **Priority:** LOW
- **Who has it:** Mail (Format ▸ Quote Level ▸ Increase ⌘' / Decrease ⌥⌘'; Edit ▸ Paste as Quotation ⇧⌘V; Settings ▸ Composing: Increase quote level)
- **What it is (ELI5):** Turn a pasted paragraph into a quote (with the bar on its left), or remove the bar, so it's clear which words are yours.
- **What we have today:** Replies are quoted with "> " lines; nothing else.

### 117. Who answered a meeting

- **Priority:** LOW
- **Who has it:** Outlook (tracking: who accepted, declined or didn't answer)
- **What it is (ELI5):** For a meeting you organised, see a list: Anna ✓, Ben ✗, Carla ? (no answer yet).
- **What we have today:** Attendee names are shown without their answers, because your copy of an invite reports every answer as unknown ([limitations](../specs/system/limitations.md)).

### 118. Shortcuts and AppleScript

- **Priority:** LOW
- **Who has it:** Mail (Shortcuts actions: Compose, Reply, Archive, Flag, Send Later, Open Smart Mailbox and more; AppleScript dictionary)
- **What it is (ELI5):** Let other programs or your own little scripts drive the mail app: "every Friday, send the report mail".
- **What we have today:** Nothing.

### 119. Accessibility checker

- **Priority:** LOW
- **Who has it:** Outlook (Check Accessibility…)
- **What it is (ELI5):** Checks your mail for things people with poor eyesight struggle with, like pictures without a description or text that is too light.
- **What we have today:** Nothing.

### 120. Read aloud

- **Priority:** LOW
- **Who has it:** Outlook (Read Aloud, Immersive Reader on Windows; Speech on Mac) · Mail (Edit ▸ Speech)
- **What it is (ELI5):** The computer reads the mail to you out loud.
- **What we have today:** No Speech item in the Edit menu (checked: a SwiftUI app's default Edit menu has none). macOS Spoken Content may still read selected text.

### 121. Tabs

- **Priority:** LOW
- **Who has it:** Mail (File ▸ New Viewer Tab ⇧⌥⌘N)
- **What it is (ELI5):** Several mail views as tabs in one window, like tabs in a web browser: one for the Inbox, one for a project folder.
- **What we have today:** A second window (File ▸ New Viewer Window ⌥⌘N), but no New Viewer Tab command. macOS may still offer to merge the windows into tabs ⚠️.
