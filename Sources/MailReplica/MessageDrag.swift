import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Drag payload for messages dragged from the list onto a sidebar mailbox.
struct MessageDrag: Codable, Transferable {
    var ids: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mailReplicaMessages)
    }
}

extension UTType {
    static let mailReplicaMessages = UTType(exportedAs: "local.mailreplica.messages", conformingTo: .data)
}
