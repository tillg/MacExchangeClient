import MailModel
import SwiftUI

struct SidebarView: View {
    @Environment(MailStore.self) private var store
    @State private var dropTarget: Row?
    /// Opens a closed mailbox that a drag rests on, as Mail does, so its subfolders can be reached.
    @State private var springOpen: Task<Void, Never>?
    /// Mailboxes whose disclosure triangle is open. Mail starts with them closed.
    @State private var expanded: Set<MailboxRef> = []
    /// An account's Inbox is in Favorites too; this says which of the two rows was clicked, so only it is highlighted.
    @State private var inFavorites = false

    /// A sidebar row: the mailbox, and whether it is the copy under Favorites ▸ All Inboxes.
    struct Row: Hashable { var ref: MailboxRef; var favorite = false }

    private var selection: Binding<Row?> {
        Binding {
            let ref = store.selectedMailbox
            guard case .account(_, .inbox) = ref else { return Row(ref: ref) }
            return Row(ref: ref, favorite: inFavorites)
        } set: { row in
            guard let row else { return }
            inFavorites = row.favorite
            store.selectedMailbox = row.ref
        }
    }

    var body: some View {
        List(selection: selection) {
            Section("Favorites") {
                // With several accounts, Mail's All Inboxes opens into each account's Inbox.
                if store.accounts.count > 1 {
                    DisclosureGroup(isExpanded: isExpanded(.smart(.allInboxes))) {
                        ForEach(store.accounts) { acct in row(.account(acct.id, .inbox), acct.name, "tray", favorite: true) }
                    } label: {
                        row(.smart(.allInboxes), "All Inboxes", "tray.2")
                    }
                } else {
                    row(.smart(.allInboxes), "All Inboxes", "tray.2")
                }
                row(.smart(.vip), "VIPs", "star")
                row(.smart(.flagged), "Flagged", "flag")
            }
            Section("Smart Mailboxes") {
                row(.smart(.unread), "Unread", "folder.badge.gearshape")  // Mail's SidebarSmartFolder (BUG-234)
            }
            ForEach(store.accounts) { acct in
                Section(acct.name) {
                    // The standard mailboxes, then the account's own top-level folders; each with its subfolders.
                    ForEach(MailboxKind.allCases + store.children(of: nil, account: acct.id).map(\.box), id: \.self) { box in
                        tree(acct.id, box)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task {
            // The snapshot hook opens every level, so the deepest rows can be checked. Deepest first, one level
            // per update: opening a folder together with or after its parent makes AppKit report a reentrant update.
            guard ProcessInfo.processInfo.environment["MAIL_SNAPSHOT"] != nil else { return }
            var levels: [[MailboxRef]] = [[.smart(.allInboxes)] + store.accounts.flatMap { a in
                (MailboxKind.allCases + store.children(of: nil, account: a.id).map(\.box)).map { MailboxRef.account(a.id, $0) }
            }]
            while let next = Optional(levels.last!.flatMap { ref -> [MailboxRef] in
                guard case let .account(a, box) = ref else { return [] }
                return store.children(of: box, account: a).map { .account(a, $0.box) }
            }), !next.isEmpty { levels.append(next) }
            // One group per update, as clicks do: opening two visible groups in one update warns of a reentrant update.
            for ref in levels.reversed().joined() where hasChildren(ref) {
                expanded.insert(ref)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onChange(of: store.selectedMailbox) { Task { await store.refresh() } }
        .safeAreaInset(edge: .bottom) {
            if let p = store.progress { ActivityView(progress: p) }
        }
        .contextMenu(forSelectionType: Row.self) { rows in
            if let ref = rows.first?.ref {
                Button("Mark All Messages as Read") { store.markAllRead(in: ref) }
            }
        }
    }

    private func hasChildren(_ ref: MailboxRef) -> Bool {
        switch ref {
        case .smart(.allInboxes): store.accounts.count > 1
        case let .account(a, box): !store.children(of: box, account: a).isEmpty
        default: false
        }
    }

    private func isExpanded(_ ref: MailboxRef) -> Binding<Bool> {
        Binding { expanded.contains(ref) } set: { if $0 { expanded.insert(ref) } else { expanded.remove(ref) } }
    }

    /// A mailbox row, with a disclosure triangle over its subfolders when it has any.
    private func tree(_ acct: UUID, _ box: MailboxKind) -> AnyView {
        let ref = MailboxRef.account(acct, box)
        let label = row(ref, store.name(of: box, in: acct), box.symbol)
        let kids = store.children(of: box, account: acct)
        guard !kids.isEmpty else { return AnyView(label) }
        return AnyView(DisclosureGroup(isExpanded: isExpanded(ref)) {
            ForEach(kids, id: \.box) { tree(acct, $0.box) }
        } label: { label })
    }

    private func row(_ ref: MailboxRef, _ title: String, _ symbol: String, favorite: Bool = false) -> some View {
        // Mail shows unread counts on inboxes / smart boxes; Drafts shows total, Sent/Trash/Archive none.
        let badge: Int = switch ref {
        case .account(_, .drafts): store.count(ref)
        case .account(_, .sent), .account(_, .trash), .account(_, .archive): 0
        default: store.unreadCount(ref)
        }
        let tag = Row(ref: ref, favorite: favorite)
        return Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())  // whole row accepts drops, not just icon + text
            .badge(badge)
            .tag(tag)
            .dropDestination(for: MessageDrag.self) { items, _ in
                store.drop(Set(items.flatMap(\.ids)), on: ref)
            } isTargeted: { on in
                if on {
                    dropTarget = tag
                    springOpen?.cancel()
                    guard !favorite, hasChildren(ref), !expanded.contains(ref) else { return }
                    springOpen = Task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if !Task.isCancelled, dropTarget == tag { expanded.insert(ref) }
                    }
                } else if dropTarget == tag {
                    dropTarget = nil
                    springOpen?.cancel()
                }
            }
            .listRowBackground(
                dropTarget == tag && store.canDrop(on: ref)
                    ? RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) : nil
            )
    }
}

/// Mail's activity view at the bottom of the sidebar: a thin bar with the task below it.
struct ActivityView: View {
    let progress: SyncProgress

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let f = progress.fraction { ProgressView(value: f) } else { ProgressView() }
            }
                .progressViewStyle(.linear)
                .controlSize(.small)
            Text(progress.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
