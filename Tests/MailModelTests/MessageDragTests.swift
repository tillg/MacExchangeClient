import AppKit
import CoreTransferable
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MailModel

/// The drag payload must survive the trip a real drag takes: item provider → system pasteboard → item provider.
/// Its type is not declared in an Info.plist, so this is where a drag would silently fail.
struct MessageDragTests {
    @Test func payloadSurvivesPasteboardRoundTrip() async throws {
        let ids = [UUID(), UUID()]
        let type = UTType.mailReplicaMessages

        // Drag source: SwiftUI's .draggable registers the Transferable on an item provider.
        let source = NSItemProvider()
        source.register(MessageDrag(ids: ids))
        #expect(source.registeredTypeIdentifiers.contains(type.identifier))
        let data: Data = try await withCheckedThrowingContinuation { c in
            _ = source.loadDataRepresentation(for: type) { d, e in
                if let d { c.resume(returning: d) } else { c.resume(throwing: e ?? CocoaError(.fileReadUnknown)) }
            }
        }

        // The drag goes through the window server's pasteboard; use a private one.
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        #expect(pb.setData(data, forType: NSPasteboard.PasteboardType(type.identifier)))
        let read = try #require(pb.data(forType: NSPasteboard.PasteboardType(type.identifier)))

        // Drop target: .dropDestination loads the Transferable back from an item provider.
        let target = NSItemProvider(item: read as NSData, typeIdentifier: type.identifier)
        let dropped: MessageDrag = try await withCheckedThrowingContinuation { c in
            _ = target.loadTransferable(type: MessageDrag.self) { c.resume(with: $0) }
        }
        #expect(dropped.ids == ids)
    }
}
