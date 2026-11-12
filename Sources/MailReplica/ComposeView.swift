import AppKit
import MailModel
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: Draft
    @AppStorage("includeAttachmentsWithReplies") private var includeMode = IncludeAttachments.never
    /// Exclude Attachments was chosen: adding a recipient doesn't bring them back.
    @State private var excluded = false
    @State private var askInclude = false
    @State private var confirmSize = false
    @FocusState private var inRecipients: Bool

    var body: some View {
        VStack(spacing: 0) {
            if draft.inviteAnswer != nil {
                answerFields
            } else {
                field("To:") { TextField("", text: $draft.to).focused($inRecipients).onSubmit(checkNewRecipients) }
                field("Cc:") { TextField("", text: $draft.cc).focused($inRecipients).onSubmit(checkNewRecipients) }
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
            if !draft.attachments.isEmpty { messageSize }
            ComposeTextView(draft: $draft,
                            files: draft.inviteAnswer == nil ? { store.files($0) } : nil)
            if draft.loadingOriginal != nil {
                Divider()
                ProgressView("Adding the original attachments…").controlSize(.small).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in drop(providers) }
        .task(id: draft.loadingOriginal) { await includeOriginal() }
        .task(id: draft.accountID) { await store.loadMaxMessageSize(for: draft.accountID) }
        .onAppear {
            // Ask: a reply to a message with attachments, which a forward or Always would already include.
            if includeMode == .ask && draft.original != nil && draft.loadingOriginal == nil && !draft.hasOriginalAttachments {
                askInclude = true
            }
        }
        // Only for a finished address: on leaving To/Cc or pressing Return, not on every keystroke.
        .onChange(of: inRecipients) { if !inRecipients { checkNewRecipients() } }
        .alert(originalCount == 1 ? "Include Attachment From Original Message?" : "Include Attachments From Original Message?",
               isPresented: $askInclude) {
            Button("Include") { draft.loadingOriginal = draft.original }
            Button("Don't Include", role: .cancel) { excluded = true }
        }
        .alert("This message is larger than your account allows.", isPresented: $confirmSize) {
            Button("Try Sending in Email") { store.send(draft); dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(sizeText) The server will probably refuse it. Remove some attachments, or try sending anyway.")
        }
        .focusedSceneValue(\.attachFiles, draft.inviteAnswer == nil ? { attachFiles() } : nil)
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
                // Mail's ComposeWindow.toolbar: insertAttachment:.
                ToolbarItem {
                    Button { attachFiles() } label: { Label("Attach", systemImage: "paperclip") }
                        .help("Attach a file or photo to this message")
                }
                // insertOriginalAttachments: in Mail's toolbar, for replies and forwards of mail with attachments.
                if draft.original != nil {
                    ToolbarItem {
                        let included = draft.hasOriginalAttachments
                        Button { toggleOriginal() } label: {
                            Label(included ? "Exclude Attachments" : "Include Attachments", systemImage: "rectangle.and.paperclip")
                        }
                        .help(included ? "Exclude attachments from original message" : "Include attachments from original message")
                        .disabled(draft.loadingOriginal != nil)
                    }
                }
                ToolbarItem {
                    Button { store.saveDraft(draft); dismiss() } label: { Label("Save Draft", systemImage: "doc") }
                        .keyboardShortcut("s", modifiers: .command).disabled(draft.loadingOriginal != nil)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private var canSend: Bool {
        if draft.loadingOriginal != nil { return false }  // the original's files are still loading
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

    /// Files dropped on the header are attached at the insertion point; the text takes its own drops.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in add([url]) }
            }
        }
        return true
    }

    private func add(_ urls: [URL]) { store.attach(urls, to: &draft) }

    /// Include Attachments With Replies ▸ When Adding Recipients.
    private func checkNewRecipients() {
        if includeMode == .whenAddingRecipients && !excluded && !draft.hasOriginalAttachments
            && draft.loadingOriginal == nil && store.addsNewRecipient(draft) {
            draft.loadingOriginal = draft.original
        }
    }

    private var originalCount: Int { draft.original.flatMap { store.message($0)?.attachments.count } ?? 0 }

    private func toggleOriginal() {
        if draft.hasOriginalAttachments {
            draft.excludeOriginalAttachments()
            excluded = true
        } else {
            draft.loadingOriginal = draft.original
        }
    }

    /// "Message Size: 4.1 MB", and "(maximum …)" when it is over the account's limit, as in Mail's header.
    private var sizeText: String {
        let f = { (n: Int) in ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
        guard store.isOverSizeLimit(draft), let max = store.maximumSize(for: draft) else { return f(draft.estimatedSize) }
        return "\(f(draft.estimatedSize)) (maximum \(f(max)))"
    }

    private var messageSize: some View {
        field("Message Size:") {
            Text(sizeText).foregroundStyle(store.isOverSizeLimit(draft) ? .red : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The original message's attachments: when a forward opens, or when they are included later.
    private func includeOriginal() async {
        guard draft.loadingOriginal != nil else { return }
        var d = draft
        d.attachments = []  // files the user adds meanwhile stay as they are
        await store.includeOriginalAttachments(in: &d)
        draft.attachments += d.attachments
        draft.loadingOriginal = nil
        excluded = false
    }

    /// File ▸ Attach Files… and the toolbar's Attach: an open panel for any number of files.
    private func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true  // a folder goes as a zip
        panel.prompt = "Choose File"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func send() {
        if store.isOverSizeLimit(draft) { return confirmSize = true }
        store.send(draft)
        dismiss()
    }

    private func field(_ label: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
                content().textFieldStyle(.plain)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider().padding(.leading, 12)
        }
    }
}

/// Attach Files… of the compose window in front. A plain key: the `@Entry` macro needs Xcode.
struct AttachFilesKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var attachFiles: (() -> Void)? {
        get { self[AttachFilesKey.self] }
        set { self[AttachFilesKey.self] = newValue }
    }
}
