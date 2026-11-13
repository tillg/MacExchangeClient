import MailModel
import QuickLook
import SwiftUI

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store
    @AppStorage("showConversations") private var showConversations = true

    var body: some View {
        if let m = store.selectedMessage {
            let thread = showConversations ? store.conversation(of: m.id) : [m]
            Group {
                if thread.count > 1 {
                    ConversationView(selected: m, messages: thread)
                } else {
                    ScrollView { MessageContent(message: m) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .quickLookPreview(Bindable(store).previewItem, in: store.previewItems)
        } else if store.selection.count > 1 {
            ContentUnavailableView("\(store.selection.count) messages selected", systemImage: "envelope.stack")
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }
}

/// The message with the rest of its conversation, newest first, each on its own card as in Mail.
private struct ConversationView: View {
    @Environment(MailStore.self) private var store
    let selected: Message
    let messages: [Message]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(messages) { m in
                        MessageContent(message: m, foundIn: m.mailbox == selected.mailbox ? nil : foundIn(m))
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                            .id(m.id)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: selected.id) {
                // Again once the cards above have their height: HTML bodies measure themselves after loading.
                proxy.scrollTo(selected.id, anchor: .top)
                try? await Task.sleep(for: .milliseconds(600))
                proxy.scrollTo(selected.id, anchor: .top)
            }
        }
    }

    /// Mail's "Found in Sent – Work Mailbox" above a message from another mailbox.
    private func foundIn(_ m: Message) -> String {
        let box = store.name(of: m.mailbox, in: m.accountID)
        return "Found in \(box) – \(store.account(m.accountID)?.name ?? "") Mailbox"
    }
}

/// One message: header, invite and body. Loads its body and inline images the first time it is shown.
struct MessageContent: View {
    @Environment(MailStore.self) private var store
    let message: Message
    var foundIn: String?
    /// The message whose body and inline images have finished loading (or failed to).
    @State private var loaded: Message.ID?
    /// Messages whose remote content the user loaded, until the window closes (Mail asks again later too).
    @State private var remoteAllowed: Set<Message.ID> = []
    @AppStorage("remoteImages") private var remoteImages = RemoteImages.defaultValue
    @Environment(\.colorScheme) private var colorScheme

    private var loading: Bool { loaded != message.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let foundIn {
                Label(foundIn, systemImage: message.mailbox.symbol)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.top, 10)
            }
            MessageHeader(message: message)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            if let invite = message.invite {
                InviteCard(message: message, invite: invite)
                HStack(alignment: .top, spacing: 0) {
                    text
                    Divider()
                    DayColumn(invite: invite, subject: message.subject, events: store.dayEvents[message.id],
                              unavailable: store.unavailableDays.contains(message.id))
                        .frame(width: 300)
                }
            } else {
                Divider()
                text
            }
        }
        .task(id: message.id) {
            await store.loadBody(message.id)
            await store.loadInlineImages(for: message.id)
            loaded = message.id
            await store.loadDay(for: message.id)
        }
    }
}

extension MessageContent {
    private var loadsRemoteContent: Bool {
        guard let account = store.accounts.first(where: { $0.id == message.accountID }) else { return false }
        return remoteImages.loadsAutomatically(from: message.from, account: account)
    }

    /// Shown once, complete: not the plain preview before the formatted body, nor the body before its
    /// pictures (adding them would load the page again). Mail also shows nothing until the message is in.
    private var waiting: Bool {
        guard loading else { return false }
        if message.needsBody { return true }
        guard let html = message.html else { return false }
        return store.inlineImages(for: message.id).isEmpty && !HTMLPage.contentIDs(in: html).isEmpty
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            if waiting {
                LoadingBody()
            } else if message.bodyLoaded, let html = message.html {
                let allowed = remoteAllowed.contains(message.id) || loadsRemoteContent
                if message.hasRemoteContent && !allowed {
                    RemoteContentBanner { remoteAllowed.insert(message.id) }
                }
                HTMLBodyView(html: html, allowRemote: allowed, inline: store.inlineImages(for: message.id))
            } else {
                Text(message.bodyLoaded ? message.body : message.preview)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            if !message.attachments.isEmpty {
                // On the HTML's white page, as in Mail, also in dark mode.
                let onPage = message.bodyLoaded && message.html != nil
                AttachmentsView(message: message).padding(.horizontal, 20).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(onPage ? Color.white : .clear)
                    .environment(\.colorScheme, onPage ? .light : colorScheme)
            }
        }
    }
}

/// The body's place while it loads: empty, with a spinner only if it takes a moment.
private struct LoadingBody: View {
    @State private var slow = false

    var body: some View {
        ZStack { if slow { ProgressView().controlSize(.small) } }
            .frame(maxWidth: .infinity, minHeight: 120)
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                slow = true
            }
    }
}

/// Mail's bar above a message whose images and styles from the web were blocked.
struct RemoteContentBanner: View {
    let load: () -> Void

    var body: some View {
        HStack {
            Text("This message contains remote content.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Load Remote Content", action: load).controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct MessageHeader: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(contact: message.from, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(message.from.name).font(.system(size: 14, weight: .bold))
                    Spacer()
                    if !message.attachments.isEmpty { AttachmentButton(message: message) }
                    if let f = message.flag {
                        Image(systemName: "flag.fill").foregroundStyle(f.color).font(.system(size: 11))
                    }
                    Text(message.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Text(message.subject).font(.system(size: 13, weight: .semibold))
                recipients("To:", message.to)
                if !message.cc.isEmpty { recipients("Cc:", message.cc) }
            }
        }
        .textSelection(.enabled)
    }

    private func recipients(_ label: String, _ list: [Contact]) -> some View {
        (Text(label + " ").foregroundStyle(.secondary) + Text(list.map(\.name).joined(separator: ", ")))
            .font(.system(size: 12))
    }
}
