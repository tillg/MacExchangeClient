import Foundation
import MailModel

/// `MailBackend` over Exchange Web Services, for on-prem Exchange.
public struct EWSBackend: MailBackend {
    let client: EWSClient

    public init(client: EWSClient) { self.client = client }

    /// Properties for list rows. FindItem and SyncFolderItems return names only for From/To, no addresses.
    static let summaryProps = ["item:Subject", "item:DateTimeReceived", "message:IsRead", "message:From",
                               "item:HasAttachments", "item:Flag", "item:Preview", "item:DisplayTo", "item:DisplayCc"]

    static var summaryShape: String {
        "<m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>"
            + summaryProps.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
            + "</t:AdditionalProperties></m:ItemShape>"
    }

    static let distinguished: [(MailboxKind, String)] = [
        (.inbox, "inbox"), (.drafts, "drafts"), (.sent, "sentitems"), (.junk, "junkemail"), (.trash, "deleteditems"),
    ]

    public func folders() async throws -> [RemoteFolder] {
        let ids = Self.distinguished.map { "<t:DistinguishedFolderId Id=\"\($0.1)\"/>" }.joined()
        let doc = try await client.call(
            "<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds>\(ids)</m:FolderIds></m:GetFolder>",
            strict: false)
        var result = Self.parseGetFolder(doc)
        // Outlook's Archive folder is a normal folder; there is no distinguished ID for it.
        let found = try await client.call("""
            <m:FindFolder Traversal="Shallow"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/></t:AdditionalProperties></m:FolderShape>\
            <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds></m:FindFolder>
            """)
        if let archive = Self.archiveFolderID(found) { result.append(RemoteFolder(role: .archive, id: archive)) }
        return result
    }

    public func newest(in folder: RemoteFolder, limit: Int) async throws -> [Message] {
        let doc = try await client.call("""
            <m:FindItem Traversal="Shallow">\(Self.summaryShape)\
            <m:IndexedPageItemView MaxEntriesReturned="\(limit)" Offset="0" BasePoint="Beginning"/>\
            <m:SortOrder><t:FieldOrder Order="Descending"><t:FieldURI FieldURI="item:DateTimeReceived"/></t:FieldOrder></m:SortOrder>\
            <m:ParentFolderIds><t:FolderId Id="\(xmlEscape(folder.id))"/></m:ParentFolderIds></m:FindItem>
            """)
        return (doc.first("Items")?.elementChildren ?? []).compactMap(Self.message)
    }

    public func sync(_ folder: RemoteFolder, token: String?) async throws -> SyncResult {
        let state = token.map { "<m:SyncState>\(xmlEscape($0))</m:SyncState>" } ?? ""
        let doc = try await client.call("""
            <m:SyncFolderItems>\(Self.summaryShape)\
            <m:SyncFolderId><t:FolderId Id="\(xmlEscape(folder.id))"/></m:SyncFolderId>\(state)\
            <m:MaxChangesReturned>512</m:MaxChangesReturned></m:SyncFolderItems>
            """)
        return Self.parseSync(doc)
    }

    public func body(remoteID: String) async throws -> MessageBody {
        let doc = try await client.call("""
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>Text</t:BodyType>\
            <t:AdditionalProperties><t:FieldURI FieldURI="item:Body"/><t:FieldURI FieldURI="item:Attachments"/>\
            <t:FieldURI FieldURI="message:From"/><t:FieldURI FieldURI="message:ToRecipients"/>\
            <t:FieldURI FieldURI="message:CcRecipients"/></t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds><t:ItemId Id="\(xmlEscape(remoteID))"/></m:ItemIds></m:GetItem>
            """)
        guard let item = doc.first("Items")?.elementChildren.first else {
            throw EWSError(code: "ErrorItemNotFound", message: "Message not found")
        }
        return Self.parseBody(item)
    }

    // MARK: Parsing

    static func parseGetFolder(_ doc: XMLDocument) -> [RemoteFolder] {
        let replies = doc.all("GetFolderResponseMessage")
        return zip(distinguished, replies).compactMap { pair, reply in
            guard reply.attr("ResponseClass") == "Success", let id = reply.first("FolderId")?.attr("Id") else { return nil }
            return RemoteFolder(role: pair.0, id: id)
        }
    }

    static func archiveFolderID(_ doc: XMLDocument) -> String? {
        let names: Set<String> = ["archive", "archiv"]
        return doc.all("Folder").first { names.contains(($0.text("DisplayName") ?? "").lowercased()) }?
            .child("FolderId")?.attr("Id")
    }

    static func parseSync(_ doc: XMLDocument) -> SyncResult {
        var upserts: [Message] = [], deleted: [String] = [], reads: [String: Bool] = [:]
        for change in doc.first("Changes")?.elementChildren ?? [] {
            switch change.localName {
            case "Create", "Update":
                if let item = change.elementChildren.first, let m = message(item) { upserts.append(m) }
            case "Delete":
                if let id = change.child("ItemId")?.attr("Id") { deleted.append(id) }
            case "ReadFlagChange":
                if let id = change.child("ItemId")?.attr("Id") { reads[id] = change.text("IsRead") == "true" }
            default: break
            }
        }
        return SyncResult(upserts: upserts, deletedRemoteIDs: deleted, readChanges: reads,
                          token: doc.text("SyncState") ?? "", more: doc.text("IncludesLastItemInRange") == "false")
    }

    nonisolated(unsafe) static let isoDate = ISO8601DateFormatter()

    /// A list summary: no body yet, recipients as display names only.
    static func message(_ item: XMLNode) -> Message? {
        guard let rid = item.child("ItemId")?.attr("Id") else { return nil }
        let from = item.child("From").map(contact) ?? Contact(name: "", email: "")
        return Message(accountID: UUID(), from: from, to: names(item.text("DisplayTo")), cc: names(item.text("DisplayCc")),
                       subject: item.child("Subject")?.stringValue ?? "",
                       body: "", date: item.text("DateTimeReceived").flatMap(isoDate.date) ?? .distantPast,
                       isRead: item.text("IsRead") == "true",
                       flag: item.child("Flag")?.text("FlagStatus") == "Flagged" ? .red : nil,
                       remoteID: rid, hasAttachments: item.text("HasAttachments") == "true",
                       serverPreview: item.child("Preview")?.stringValue ?? "", bodyLoaded: false)
    }

    static func parseBody(_ item: XMLNode) -> MessageBody {
        let attachments = (item.child("Attachments")?.elementChildren ?? [])
            .filter { $0.text("IsInline") != "true" }
            .compactMap { $0.child("Name")?.stringValue }
        return MessageBody(text: item.child("Body")?.stringValue ?? "", attachments: attachments,
                           from: item.child("From").map(contact),
                           to: item.child("ToRecipients").map(mailboxes) ?? [],
                           cc: item.child("CcRecipients").map(mailboxes) ?? [])
    }

    static func contact(_ n: XMLNode) -> Contact {
        let mail = n.text("EmailAddress") ?? ""
        let name = n.text("Name") ?? ""
        return Contact(name: name.isEmpty ? mail : name, email: mail)
    }

    static func mailboxes(_ n: XMLNode) -> [Contact] { n.children("Mailbox").map(contact) }

    static func names(_ display: String?) -> [Contact] {
        (display ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map { Contact(name: $0, email: "") }
    }
}
