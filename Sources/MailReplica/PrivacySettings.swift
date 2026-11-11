import MailModel
import SwiftUI

/// Outlook's "Download external images" choice, under Privacy as in Outlook and Mail.
struct PrivacySettings: View {
    @AppStorage("remoteImages") private var remoteImages = RemoteImages.defaultValue

    var body: some View {
        Form {
            Section {
                Picker("Download external images", selection: $remoteImages) {
                    ForEach(RemoteImages.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("Images load straight from the sender's server, which lets the sender see that you opened the message and from which IP address. \"My organisation\" means senders in your account's mail domain.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}
