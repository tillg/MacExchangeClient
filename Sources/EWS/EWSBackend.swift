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

    // MARK: Write-back

    public func setRead(_ ids: [String], _ read: Bool) async throws {
        _ = try await client.call(Self.updateRequest(ids, field: "message:IsRead", value: "<t:IsRead>\(read)</t:IsRead>"))
    }

    public func setFlagged(_ ids: [String], _ flagged: Bool) async throws {
        _ = try await client.call(Self.flagRequest(ids, flagged: flagged))
    }

    public func move(_ ids: [String], to folder: RemoteFolder) async throws -> [String: String] {
        Self.parseMove(try await client.call(Self.moveRequest(ids, to: folder.id)), ids: ids)
    }

    public func delete(_ ids: [String]) async throws { _ = try await client.call(Self.deleteRequest(ids)) }

    public func send(_ draft: Draft) async throws { _ = try await client.call(Self.createRequest(draft, send: true)) }

    public func saveDraft(_ draft: Draft) async throws { _ = try await client.call(Self.createRequest(draft, send: false)) }

    static func itemIDs(_ ids: [String]) -> String {
        ids.map { "<t:ItemId Id=\"\(xmlEscape($0))\"/>" }.joined()
    }

    /// Sets one field on each item. AlwaysOverwrite needs no ChangeKey; opening a message must not send a read receipt.
    static func updateRequest(_ ids: [String], field: String, value: String) -> String {
        let changes = ids.map {
            "<t:ItemChange><t:ItemId Id=\"\(xmlEscape($0))\"/><t:Updates><t:SetItemField><t:FieldURI FieldURI=\"\(field)\"/>"
                + "<t:Message>\(value)</t:Message></t:SetItemField></t:Updates></t:ItemChange>"
        }.joined()
        return "<m:UpdateItem MessageDisposition=\"SaveOnly\" ConflictResolution=\"AlwaysOverwrite\" SuppressReadReceipts=\"true\">"
            + "<m:ItemChanges>\(changes)</m:ItemChanges></m:UpdateItem>"
    }

    static func flagRequest(_ ids: [String], flagged: Bool) -> String {
        updateRequest(ids, field: "item:Flag",
                      value: "<t:Flag><t:FlagStatus>\(flagged ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag>")
    }

    static func moveRequest(_ ids: [String], to folderID: String) -> String {
        "<m:MoveItem><m:ToFolderId><t:FolderId Id=\"\(xmlEscape(folderID))\"/></m:ToFolderId>"
            + "<m:ItemIds>\(itemIDs(ids))</m:ItemIds><m:ReturnNewItemIds>true</m:ReturnNewItemIds></m:MoveItem>"
    }

    /// One response message per requested item, in request order.
    static func parseMove(_ doc: XMLDocument, ids: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for (old, reply) in zip(ids, doc.all("MoveItemResponseMessage")) {
            if let new = reply.first("ItemId")?.attr("Id") { map[old] = new }
        }
        return map
    }

    /// SoftDelete: into Recoverable Items, like Outlook's delete from Deleted Items.
    static func deleteRequest(_ ids: [String]) -> String {
        "<m:DeleteItem DeleteType=\"SoftDelete\"><m:ItemIds>\(itemIDs(ids))</m:ItemIds></m:DeleteItem>"
    }

    static func createRequest(_ d: Draft, send: Bool) -> String {
        func recipients(_ tag: String, _ list: String) -> String {
            let boxes = Contact.parseList(list).map {
                "<t:Mailbox><t:Name>\(xmlEscape($0.name))</t:Name><t:EmailAddress>\(xmlEscape($0.email))</t:EmailAddress></t:Mailbox>"
            }
            return boxes.isEmpty ? "" : "<t:\(tag)>\(boxes.joined())</t:\(tag)>"
        }
        let disposition = send ? "SendAndSaveCopy" : "SaveOnly"
        return "<m:CreateItem MessageDisposition=\"\(disposition)\"><m:SavedItemFolderId>"
            + "<t:DistinguishedFolderId Id=\"\(send ? "sentitems" : "drafts")\"/></m:SavedItemFolderId><m:Items><t:Message>"
            + "<t:Subject>\(xmlEscape(d.subject))</t:Subject><t:Body BodyType=\"Text\">\(xmlEscape(d.body))</t:Body>"
            + recipients("ToRecipients", d.to) + recipients("CcRecipients", d.cc)
            + "</t:Message></m:Items></m:CreateItem>"
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
