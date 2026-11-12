import MailModel
import QuickLook
import SwiftUI

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if let m = store.selectedMessage {
            MessageContent(message: m)
                .task(id: m.id) {
                    await store.loadBody(m.id)
                    await store.loadInlineImages(for: m.id)
                    await store.loadDay(for: m.id)
                }
        } else if store.selection.count > 1 {
            ContentUnavailableView("\(store.selection.count) messages selected", systemImage: "envelope.stack")
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }
}

struct MessageContent: View {
    @Environment(MailStore.self) private var store
    let message: Message
    /// Messages whose remote content the user loaded, until the window closes (Mail asks again later too).
    @State private var remoteAllowed: Set<Message.ID> = []
    @AppStorage("remoteImages") private var remoteImages = RemoteImages.defaultValue
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeader(message: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                if let invite = message.invite {
                    InviteCard(message: message, invite: invite)
                    HStack(alignment: .top, spacing: 0) {
                        text
                        Divider()
                        DayColumn(invite: invite, subject: message.subject, events: store.dayEvents[message.id])
                            .frame(width: 300)
                    }
                } else {
                    Divider()
                    text
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .quickLookPreview(Bindable(store).previewItem, in: store.previewItems)
    }
}

extension MessageContent {
    private var loadsRemoteContent: Bool {
        guard let account = store.accounts.first(where: { $0.id == message.accountID }) else { return false }
        return remoteImages.loadsAutomatically(from: message.from, account: account)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 0) {
            if message.bodyLoaded, let html = message.html {
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
