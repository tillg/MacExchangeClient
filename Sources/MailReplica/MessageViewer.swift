import MailModel
import SwiftUI

/// The main window: Mail's three-column "message viewer".
struct MessageViewer: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var back: [MailboxRef] = []
    @State private var forward: [MailboxRef] = []

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            MessageListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
                .toolbar { listToolbar }
        } detail: {
            MessageDetailView()
                .toolbar { messageToolbar }
        }
        .navigationTitle(store.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Search")
        .onChange(of: store.selectedMailbox) { old, _ in
            if back.last != old { back.append(old); forward.removeAll() }
            store.selection = []
        }
    }

    private var subtitle: String {
        if let status = store.status { return status }
        let n = store.count(store.selectedMailbox), u = store.unreadCount(store.selectedMailbox)
        return u > 0 ? "\(n) messages, \(u) unread" : "\(n) messages"
    }

    // Default-set order from MainWindow.toolbar:
    // toggleSidebar | back/forward, filter, view options, compose | reply group, archive group, move, flag | search
    @ToolbarContentBuilder private var listToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ControlGroup {
                Button { goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(back.isEmpty)
                Button { goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(forward.isEmpty)
            }
            .controlGroupStyle(.navigation)
        }
        ToolbarItemGroup {
            Toggle(isOn: Bindable(store).filterUnread) {
                Label("Filter", systemImage: store.filterUnread
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .help("Filter messages in this mailbox")
            ViewOptionsMenu()
            Button { openWindow(id: "compose", value: ComposeWindow(Draft(accountID: defaultAccount))) } label: {
                Label("New Message", systemImage: "square.and.pencil")
            }
            .help("Compose new message")
        }
    }

    @ToolbarContentBuilder private var messageToolbar: some ToolbarContent {
        let none = store.selection.isEmpty
        ToolbarItem {
            ControlGroup {
                Button { reply(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.backward") }
                    .help("Reply to sender of selected message")
                Button { reply(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.backward.2") }
                    .help("Reply to all recipients of the selected message")
                Button { reply(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.forward") }
                    .help("Forward selected messages")
            }
            .disabled(store.selectedMessage == nil)
        }
        ToolbarItem {
            ControlGroup {
                Button { store.archiveSelection() } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive selected messages")
                Button { store.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete selected messages")
                Button { store.junkSelection() } label: { Label("Junk", systemImage: "xmark.bin") }
                    .help("Mark selected messages as junk mail")
            }
            .disabled(none)
        }
        ToolbarItem {
            MoveMenu().disabled(none)
        }
        ToolbarItem {
            FlagMenu().disabled(none)
        }
    }

    private var defaultAccount: UUID {
        if case let .account(id, _) = store.selectedMailbox { return id }
        return store.selectedMessage?.accountID ?? store.accounts[0].id
    }

    private func reply(_ kind: ReplyKind) {
        guard let m = store.selectedMessage else { return }
        Task { openWindow(id: "compose", value: ComposeWindow(await store.loadedDraft(kind, to: m.id))) }
    }

    private func goBack() {
        guard let prev = back.popLast() else { return }
        forward.append(store.selectedMailbox)
        jump(to: prev)
    }

    private func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(store.selectedMailbox)
        jump(to: next)
    }

    /// Changes mailbox without recording history (onChange skips when old == back.last).
    private func jump(to ref: MailboxRef) {
        let fwd = forward, bk = back
        store.selectedMailbox = ref
        DispatchQueue.main.async { forward = fwd; back = bk }
    }
}

struct ViewOptionsMenu: View {
    @Environment(MailStore.self) private var store
    @AppStorage("showContactPhoto") private var showPhoto = false

    var body: some View {
        Menu {
            Toggle("Show Contact Photo", isOn: $showPhoto)
        } label: {
            Label("View Options", systemImage: "line.3.horizontal")
        }
        .help("View Options")
    }
}

struct MoveMenu: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Menu {
            ForEach(store.accounts) { acct in
                Section(acct.name) {
                    // Subfolders follow their parent, indented, as in Mail's Move To menu.
                    ForEach(boxes(acct.id), id: \.box) { item in
                        Button { move(acct.id, item.box) } label: {
                            Label(String(repeating: "    ", count: item.depth) + store.name(of: item.box, in: acct.id),
                                  systemImage: item.box.symbol)
                        }
                    }
                }
            }
        } label: {
            Label("Move", systemImage: "folder")
        }
        .help("Move selected messages")
    }

    /// The account's mailboxes in sidebar order, each followed by its subfolders.
    private func boxes(_ acct: UUID) -> [(box: MailboxKind, depth: Int)] {
        func below(_ box: MailboxKind, _ depth: Int) -> [(box: MailboxKind, depth: Int)] {
            [(box, depth)] + store.children(of: box, account: acct).flatMap { below($0.box, depth + 1) }
        }
        return (MailboxKind.allCases + store.children(of: nil, account: acct).map(\.box)).flatMap { below($0, 0) }
    }

    /// Into that account's mailbox; `drop` refuses to move server mail to another account.
    private func move(_ acct: UUID, _ kind: MailboxKind) {
        store.drop(store.selection, on: .account(acct, kind))
    }

}

struct FlagMenu: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Menu {
            ForEach(FlagColor.allCases, id: \.self) { c in
                Button { store.setFlag(c, for: store.selection) } label: {
                    Label(c.title, systemImage: "flag.fill")
                }
                .tint(c.color)
            }
            Divider()
            Button("Clear Flag") { store.setFlag(nil, for: store.selection) }
        } label: {
            Label("Flag", systemImage: "flag")
        } primaryAction: {
            let flagged = store.selection.contains { store.message($0)?.flag != nil }
            store.setFlag(flagged ? nil : .red, for: store.selection)
        }
        .help("Flag selected messages")
    }
}

extension FlagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }
}
