import MailModel
import SwiftUI

struct SidebarView: View {
    @Environment(MailStore.self) private var store
    @State private var dropTarget: MailboxRef?

    var body: some View {
        List(selection: Bindable(store).selectedMailbox) {
            Section("Favorites") {
                row(.smart(.allInboxes), "All Inboxes", "tray.2")
                row(.smart(.vip), "VIPs", "star")
                row(.smart(.flagged), "Flagged", "flag")
            }
            Section("Smart Mailboxes") {
                row(.smart(.unread), "Unread", "gearshape")
            }
            ForEach(store.accounts) { acct in
                Section(acct.name) {
                    ForEach(MailboxKind.allCases, id: \.self) { kind in
                        row(.account(acct.id, kind), kind.title, kind.symbol)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let p = store.progress { ActivityView(progress: p) }
        }
        .contextMenu(forSelectionType: MailboxRef.self) { refs in
            if let ref = refs.first {
                Button("Mark All Messages as Read") { store.markAllRead(in: ref) }
            }
        }
    }

    private func row(_ ref: MailboxRef, _ title: String, _ symbol: String) -> some View {
        // Mail shows unread counts on inboxes / smart boxes; Drafts shows total, Sent/Trash/Archive none.
        let badge: Int = switch ref {
        case .account(_, .drafts): store.count(ref)
        case .account(_, .sent), .account(_, .trash), .account(_, .archive): 0
        default: store.unreadCount(ref)
        }
        return Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())  // whole row accepts drops, not just icon + text
            .badge(badge)
            .tag(ref)
            .dropDestination(for: MessageDrag.self) { items, _ in
                store.drop(Set(items.flatMap(\.ids)), on: ref)
            } isTargeted: { on in
                if on { dropTarget = ref } else if dropTarget == ref { dropTarget = nil }
            }
            .listRowBackground(
                dropTarget == ref && store.canDrop(on: ref)
                    ? RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2) : nil
            )
    }
}

/// Mail's activity view at the bottom of the sidebar: a thin bar with the task below it.
struct ActivityView: View {
    let progress: SyncProgress

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(value: progress.fraction)
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
