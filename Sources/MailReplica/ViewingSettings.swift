import SwiftUI

/// Whether a message shows with the rest of its conversation, as Mail's Settings ▸ Viewing ▸ View conversations.
struct ViewingSettings: View {
    @AppStorage("showConversations") private var showConversations = true

    var body: some View {
        Form {
            Section {
                Toggle("Show messages as conversations", isOn: $showConversations)
            } footer: {
                Text("A message shows together with the replies and forwards that belong to it, also the ones you sent, and the list shows each conversation as one row. Turn this off to see each message by itself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
