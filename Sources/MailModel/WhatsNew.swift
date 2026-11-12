import Foundation

/// One day of the change log in Help ▸ What's New: the date and what was added that day, in plain words.
public struct ChangeLogDay: Identifiable, Sendable {
    public let date: String  // yyyy-MM-dd
    public let features: [String]
    public var id: String { date }
}

/// The change log, newest day first. Written for people who use the app, not for developers:
/// add a day (or extend today's) whenever a change is something a user would notice.
public enum WhatsNew {
    public static let days: [ChangeLogDay] = [
        ChangeLogDay(date: "2026-11-13", features: [
            "If the mail kept by an older version can't be read, the app keeps a copy of it, starts fresh and saves your mail again.",
            "Messages no longer show up dated in the year 1, and more meeting invitations show their details and answer buttons.",
        ]),
        ChangeLogDay(date: "2026-11-12", features: [
            "A message now shows together with its replies and forwards, including the ones you sent, as in Apple Mail. You can turn this off in Settings ▸ Viewing.",
            "Search is now instant, even in mailboxes with many thousands of messages.",
            "Attachments: see what came with a message, preview it with Quick Look and save it.",
            "When writing, attach files and whole folders, or drop pictures right into the text where they belong.",
            "Pictures in your text arrive inside the message, not as separate files.",
            "A warning when a message is too big for your mail server to send.",
            "Messages open complete at once, with their pictures, without flickering.",
            "Pull the message list down to check for new mail.",
            "Once you answer a meeting invitation, it goes to the Trash and the next message opens.",
            "Fewer password prompts from the Keychain after an update.",
            "Drag messages onto any folder in the sidebar; hold over a closed folder to open it.",
            "All your Exchange folders show up, even in mailboxes with more than a thousand.",
            "A cancelled meeting offers Remove from Calendar instead of Accept or Decline.",
            "About MailReplica shows the build number and when it was built.",
            "Mail kept by an older version of the app is carried over again, even messages with attachments, and changes still waiting to reach the server are no longer lost.",
            "Pressing Delete twice no longer erases a message for good that was hidden by a filter or a search; it stays in the Trash.",
            "Search finds your messages even when many newer matches sit in the Trash or Junk.",
            "Text pasted from Word or a PDF no longer stops a message, draft or meeting answer from being sent.",
            "Recipients copied from Outlook work in To and Cc: separated by semicolons, and with names like \"Doe, John\".",
            "With the unread filter or in Unread, the message you open stays in the list until you move on, as in Apple Mail.",
            "Reply All no longer sends a copy to yourself when your address is written in capitals.",
            "Replies and forwards mark every line of the original as quoted, not just the first.",
        ]),
        ChangeLogDay(date: "2026-11-11", features: [
            "Nicely formatted emails now look the way the sender designed them, with their pictures.",
            "You decide when pictures from the internet are loaded (Settings ▸ Privacy).",
            "Your own folders and subfolders appear in the sidebar, just like in Apple Mail.",
            "Much faster start: your Inbox shows up first, and the app stays smooth with very large mailboxes.",
            "Your mail is stored more safely on your Mac, even if the app is interrupted.",
        ]),
        ChangeLogDay(date: "2026-11-10", features: [
            "The first version: a mail app that looks and works like Apple Mail.",
            "Connect your company Exchange account. Your password is kept safely in the Keychain.",
            "Read, flag, move and delete messages, write and send mail, and save drafts.",
            "Your mail is kept on your Mac, so it opens quickly and you can read it offline.",
            "New mail is checked every 15 seconds, with a progress bar while it loads.",
            "Meeting invitations show the details and your day's calendar. Accept, maybe or decline them, add a comment or propose a new time.",
            "If your password is wrong, the app stops trying, so your account doesn't get locked.",
            "A new pink app icon.",
        ]),
    ]
}
