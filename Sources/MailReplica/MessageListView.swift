import MailModel
import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    /// A pull to refresh is checking for mail: the spinner above the list.
    @State private var pulling = false
    /// Settings ▸ Viewing: a conversation is one row of the list, as with Mail's Organize by Conversation.
    @AppStorage("showConversations") private var showConversations = true

    var body: some View {
        let msgs = store.visibleMessages
        // SwiftUI compares a view's data and the values its closures capture on every change, field by field.
        // For tens of thousands of messages that blocked the window, so the list gets IDs and the rows look
        // their message up in a class, which is compared by reference.
        let lookup = Lookup(msgs)
        let isEmpty = msgs.isEmpty
        VStack(spacing: 0) {
            // Rows, not messages: a conversation's row stays selected when a reply arrives and becomes its newest.
            List(selection: Bindable(store).listSelection) {
                ForEach(msgs.map(\.id), id: \.self) { id in
                    let m = lookup.byID[id]!
                    // Actions on a row act on every message of its conversation.
                    let all = store.withConversations([m.id])
                    MessageRow(message: m, conversation: store.conversationRow(m.id))
                        .tag(m.id)
                        // Dragging a selected row drags the whole selection, as in Mail.
                        .draggable(MessageDrag(ids: Array(store.withConversations(store.listSelection.contains(m.id) ? store.listSelection : [m.id])))) {
                            let n = store.withConversations(store.listSelection.contains(m.id) ? store.listSelection : [m.id]).count
                            Label(n == 1 ? m.subject : "\(n) Messages", systemImage: "envelope")
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .swipeActions(edge: .leading) {
                            let read = store.conversationRow(m.id)?.isRead ?? m.isRead
                            Button { store.toggleRead(all) } label: {
                                Label(read ? "Unread" : "Read",
                                      systemImage: read ? "envelope.badge" : "envelope.open")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(all) } label: {
                                Label("Trash", systemImage: "trash")
                            }
                            Button { store.setFlag((store.conversationRow(m.id)?.flag ?? m.flag) == nil ? .orange : nil, for: all) } label: {
                                Label("Flag", systemImage: "flag")
                            }
                            .tint(.orange)
                        }
                }
            }
            .listStyle(.inset)
            .safeAreaInset(edge: .top, spacing: 0) {
                if pulling {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 10)
                }
            }
            .background(PullToRefresh { pullToRefresh() })
            .overlay {
                if isEmpty {
                    if store.searchText.isEmpty {
                        ContentUnavailableView(store.filterUnread ? "No Unread Messages" : "No Messages",
                                               systemImage: "tray")
                    } else if !store.awaitingSearchResults {
                        ContentUnavailableView.search(text: store.searchText)
                    }
                }
            }
            .contextMenu(forSelectionType: Message.ID.self) { ids in
                // Read state from the rows' lookup: `store.message` goes over every message, on every redraw.
                MessageContextMenu(rows: ids, ids: store.withConversations(ids),
                                   unread: ids.contains { (store.conversationRow($0)?.isRead ?? lookup.byID[$0]?.isRead) == false })
            } primaryAction: { ids in
                // Double-click opens the message; in Mail that's a separate window. Here: reply-less read.
                store.selection = ids
            }
            .onDeleteCommand { store.deleteSelection() }
            .onChange(of: showConversations, initial: true) { store.groupsConversations = showConversations }
            .onChange(of: store.selection) {
                // Mail marks a message read as soon as it is displayed. One main-loop turn later: changing the
                // rows while the table is still reporting the click is a reentrant table update (AppKit warns).
                guard store.selection.count == 1 else { return }
                Task { @MainActor in store.markSelectionRead() }
            }
        }
    }
}

extension MessageListView {
    /// Checks the Inbox and the mailbox on screen, as Get New Mail does. The spinner stays until the check is
    /// done (also one already running), and at least a moment, so it doesn't just flash.
    private func pullToRefresh() {
        guard !pulling else { return }
        withAnimation { pulling = true }
        Task {
            let start = ContinuousClock.now
            await store.refresh()
            while store.isRefreshing { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(until: start + .milliseconds(800), clock: .continuous)
            withAnimation { pulling = false }
        }
    }
}

/// The visible messages by ID, for the rows. A class, so SwiftUI compares it by reference.
private final class Lookup {
    let byID: [Message.ID: Message]
    init(_ msgs: [Message]) { byID = Dictionary(uniqueKeysWithValues: msgs.map { ($0.id, $0) }) }
}

struct MessageRow: View {
    @Environment(MailStore.self) private var store
    @AppStorage("showContactPhoto") private var showPhoto = false
    let message: Message
    /// The conversation this row stands for, when it has more than one message in the list.
    var conversation: ConversationRow? = nil
    private var isRead: Bool { conversation?.isRead ?? message.isRead }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Mail's status column: the unread dot, or for a VIP sender a star (accent-coloured while unread), so the
            // sender stays in line with the subject and preview.
            Group {
                if message.isVIP {
                    Image(systemName: "star.fill").font(.system(size: 9))
                        .foregroundStyle(isRead ? Color.secondary : Color.accentColor)
                } else {
                    Circle().fill(isRead ? Color.clear : Color.accentColor)
                }
            }
            .frame(width: 8, height: 8)
            .padding(.top, 5)
            if showPhoto {
                Avatar(contact: message.from, size: 32)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(senderLabel).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.listDate(message.date)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(conversation?.subject ?? message.subject).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation?.hasAttachments ?? message.hasAttachments {
                        Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let f = conversation?.flag ?? message.flag {
                        Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(f.color)
                    }
                    // Mail's badge: how many messages the row stands for.
                    if let n = conversation?.count {
                        HStack(spacing: 2) {
                            Text("\(n)")
                            Image(systemName: "chevron.forward.circle")
                        }
                        .font(.system(size: 12)).foregroundStyle(Color.accentColor)
                        .help("\(n) messages in this conversation")
                    }
                }
                Text(message.preview).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var senderLabel: String {
        message.mailbox == .sent || message.mailbox == .drafts
            ? "To: " + (message.to.first?.name ?? "") : conversation?.senders ?? message.from.name
    }

    /// Today → time, yesterday → "Yesterday", last 7 days → weekday, else short date.
    static func listDate(_ d: Date) -> String {
        switch ListDate.kind(of: d) {
        case .time: d.formatted(date: .omitted, time: .shortened)
        case .yesterday: "Yesterday"
        case .weekday: d.formatted(.dateTime.weekday(.wide))
        case .date: d.formatted(date: .numeric, time: .omitted)
        }
    }
}

struct MessageContextMenu: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    /// The rows clicked, and every message they stand for (a conversation row stands for all of its messages).
    let rows: Set<Message.ID>
    let ids: Set<Message.ID>
    /// Whether any of them is unread.
    let unread: Bool

    var body: some View {
        if rows.count == 1, let id = rows.first {
            Button("Reply") { Task { openWindow(id: "compose", value: ComposeWindow(await store.loadedDraft(.reply, to: id))) } }
            Button("Reply All") { Task { openWindow(id: "compose", value: ComposeWindow(await store.loadedDraft(.replyAll, to: id))) } }
            Button("Forward") { Task { openWindow(id: "compose", value: ComposeWindow(await store.loadedDraft(.forward, to: id))) } }
            Divider()
        }
        Button(unread ? "Mark as Read" : "Mark as Unread") { store.toggleRead(ids) }
        Menu("Flag") {
            ForEach(FlagColor.allCases, id: \.self) { c in Button(c.title) { store.setFlag(c, for: ids) } }
            Divider()
            Button("Clear Flag") { store.setFlag(nil, for: ids) }
        }
        Divider()
        Button("Archive") { store.archive(ids) }
        Button(store.isAllJunk(ids) ? "Not Junk" : "Move to Junk") { store.toggleJunk(ids) }
        Button("Delete", role: .destructive) { store.delete(ids) }
    }
}

struct Avatar: View {
    let contact: Contact
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [Color(white: 0.66), Color(white: 0.52)], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                Text(contact.initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
    }
}
