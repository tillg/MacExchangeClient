import MailModel
import SwiftUI

struct MessageDetailView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if let m = store.selectedMessage {
            MessageContent(message: m)
                .task(id: m.id) { await store.loadBody(m.id) }
        } else if store.selection.count > 1 {
            ContentUnavailableView("\(store.selection.count) messages selected", systemImage: "envelope.stack")
        } else {
            ContentUnavailableView("No Message Selected", systemImage: "envelope")
        }
    }
}

struct MessageContent: View {
    let message: Message

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                MessageHeader(message: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                Divider()
                Text(message.bodyLoaded ? message.body : message.preview)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                if !message.attachments.isEmpty {
                    AttachmentStrip(names: message.attachments).padding(.horizontal, 20).padding(.bottom, 20)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
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

struct AttachmentStrip: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Label("\(names.count) Attachment\(names.count == 1 ? "" : "s")", systemImage: "paperclip")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(names, id: \.self) { n in
                    VStack(spacing: 4) {
                        Image(systemName: icon(n)).font(.system(size: 28)).foregroundStyle(.secondary)
                            .frame(width: 64, height: 56)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                        Text(n).font(.system(size: 11)).lineLimit(1).frame(width: 90)
                    }
                }
            }
        }
    }

    private func icon(_ n: String) -> String {
        switch (n as NSString).pathExtension.lowercased() {
        case "pdf": "doc.richtext"
        case "jpeg", "jpg", "png", "heic": "photo"
        default: "doc"
        }
    }
}
