import MailModel
import SwiftUI

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft

    var body: some View {
        VStack(spacing: 0) {
            if draft.inviteAnswer != nil {
                answerFields
            } else {
                field("To:") { TextField("", text: $draft.to) }
                field("Cc:") { TextField("", text: $draft.cc) }
                field("Subject:") { TextField("", text: $draft.subject) }
            }
            if store.accounts.count > 1 && draft.inviteAnswer == nil {
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
                    .disabled(!canSend)
                    .help("Send message")
            }
            if draft.inviteAnswer == nil {
                ToolbarItem {
                    Button { store.saveDraft(draft); dismiss() } label: { Label("Save Draft", systemImage: "doc") }
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var canSend: Bool {
        guard let a = draft.inviteAnswer else { return !draft.to.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let s = a.proposedStart, let e = a.proposedEnd else { return true }
        return e > s
    }

    /// An invite answer: Exchange sends it to the organizer with its own subject, so both are shown, not edited.
    @ViewBuilder private var answerFields: some View {
        field("To:") { Text(draft.to.isEmpty ? "Organizer" : draft.to).frame(maxWidth: .infinity, alignment: .leading) }
        field("Subject:") { Text(draft.subject).frame(maxWidth: .infinity, alignment: .leading) }
        if let a = draft.inviteAnswer, let start = a.proposedStart, let end = a.proposedEnd {
            field("Start:") {
                DatePicker("", selection: Binding { start } set: { draft.inviteAnswer?.proposedStart = $0 }).labelsHidden().fixedSize()
                Spacer()
            }
            field("End:") {
                DatePicker("", selection: Binding { end } set: { draft.inviteAnswer?.proposedEnd = $0 }).labelsHidden().fixedSize()
                if end <= start { Text("The meeting must end after it starts.").foregroundStyle(.red) }
                Spacer()
            }
        }
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
