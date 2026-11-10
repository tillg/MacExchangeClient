import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Drag payload for messages dragged from the list onto a sidebar mailbox.
public struct MessageDrag: Codable, Transferable, Sendable {
    public var ids: [UUID]
    public init(ids: [UUID]) { self.ids = ids }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mailReplicaMessages)
    }
}

extension UTType {
    public static let mailReplicaMessages = UTType(exportedAs: "local.mailreplica.messages", conformingTo: .data)
}
