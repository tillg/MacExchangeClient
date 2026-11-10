import MailModel
import SwiftUI

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft

    var body: some View {
        VStack(spacing: 0) {
            field("To:") { TextField("", text: $draft.to) }
            field("Cc:") { TextField("", text: $draft.cc) }
            field("Subject:") { TextField("", text: $draft.subject) }
            if store.accounts.count > 1 {
                field("From:") {
                    Picker("", selection: $draft.accountID) {
                        ForEach(store.accounts) { a in Text("\(a.name) – \(a.address)").tag(a.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            TextEditor(text: $draft.body)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(draft.subject.isEmpty ? "New Message" : draft.subject)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { send() } label: { Label("Send", systemImage: "paperplane") }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(draft.to.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Send message")
            }
            ToolbarItem {
                Button { store.saveDraft(draft); dismiss() } label: { Label("Save Draft", systemImage: "doc") }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func send() {
        store.send(draft)
        dismiss()
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                content().textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider().padding(.leading, 12)
        }
    }
}
