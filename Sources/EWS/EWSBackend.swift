import Foundation
import UniformTypeIdentifiers
import MailModel

/// `MailBackend` over Exchange Web Services, for on-prem Exchange.
public struct EWSBackend: MailBackend {
    let client: EWSClient

    public init(client: EWSClient) { self.client = client }

    /// Properties for list rows. FindItem and SyncFolderItems return names only for From/To, no addresses.
    static let summaryProps = ["item:Subject", "item:DateTimeReceived", "message:IsRead", "message:From",
                               "item:HasAttachments", "item:Flag", "item:Preview", "item:DisplayTo", "item:DisplayCc",
                               "item:ConversationId"]

    static var summaryShape: String {
        "<m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>"
            + summaryProps.map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
            + "</t:AdditionalProperties></m:ItemShape>"
    }

    static let distinguished: [(MailboxKind, String)] = [
        (.inbox, "inbox"), (.drafts, "drafts"), (.sent, "sentitems"), (.junk, "junkemail"), (.trash, "deleteditems"),
    ]

    public func folders() async throws -> [RemoteFolder] {
        // Outbox is asked for too, only to leave it out of the tree: Mail doesn't show it.
        let ids = (Self.distinguished.map(\.1) + ["outbox"]).map { "<t:DistinguishedFolderId Id=\"\($0)\"/>" }.joined()
        let doc = try await client.call(
            "<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\(Self.countProp)</m:FolderShape><m:FolderIds>\(ids)</m:FolderIds></m:GetFolder>",
            strict: false)
        var result = Self.parseGetFolder(doc)
        // Exchange refused the Inbox (e.g. the mailbox store is unavailable during a move): a list without it would
        // be kept for the session, so the check fails with that error and the list is asked again next time.
        if let inbox = doc.all("GetFolderResponseMessage").first, inbox.attr("ResponseClass") == "Error" {
            throw EWSError(code: inbox.child("ResponseCode")?.stringValue ?? "ErrorFolderNotFound",
                           message: inbox.child("MessageText")?.stringValue ?? "Exchange didn't return the Inbox")
        }
        let outbox = doc.all("GetFolderResponseMessage").dropFirst(Self.distinguished.count).first?.first("FolderId")?.attr("Id")
        // Every mail folder, nested. Outlook's Archive folder is a normal top-level folder; there is no distinguished ID for it.
        var found: [XMLNode] = [], offset: Int? = 0
        while let o = offset {
            let page = try await client.call(Self.findFoldersRequest(offset: o))
            found += page.all("Folder")
            offset = Self.nextFolderOffset(page).flatMap { $0 > o ? $0 : nil }  // never the same page twice
        }
        if let archive = Self.archiveFolder(found) { result.append(archive) }
        return result + Self.folderTree(found, known: result, skip: Set([outbox].compactMap { $0 }))
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
        let doc: XMLDocument
        do {
            doc = try await client.call("""
                <m:SyncFolderItems>\(Self.summaryShape)\
                <m:SyncFolderId><t:FolderId Id="\(xmlEscape(folder.id))"/></m:SyncFolderId>\(state)\
                <m:MaxChangesReturned>512</m:MaxChangesReturned></m:SyncFolderItems>
                """)
        } catch let e as EWSError where token != nil && e.code == "ErrorInvalidSyncStateData" {
            throw SyncTokenRejected()  // expired or corrupt: the store syncs the folder again from the start
        }
        return Self.parseSync(doc)
    }

    public func body(remoteID: String) async throws -> MessageBody {
        let doc = try await client.call(Self.bodyRequest(remoteID))
        guard let item = doc.first("Items")?.elementChildren.first else {
            throw EWSError(code: "ErrorItemNotFound", message: "Message not found")
        }
        return Self.parseBody(item)
    }

    /// `Best` returns HTML when the message has it. `TextBody` (Exchange 2013) adds the plain text for the list and replies.
    static func bodyRequest(_ remoteID: String) -> String {
        """
        <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:BodyType>Best</t:BodyType>\
        <t:AdditionalProperties><t:FieldURI FieldURI="item:Body"/><t:FieldURI FieldURI="item:TextBody"/>\
        <t:FieldURI FieldURI="item:Attachments"/>\
        <t:FieldURI FieldURI="message:From"/><t:FieldURI FieldURI="message:ToRecipients"/>\
        <t:FieldURI FieldURI="message:CcRecipients"/>\(inviteProps)</t:AdditionalProperties></m:ItemShape>\
        <m:ItemIds><t:ItemId Id="\(xmlEscape(remoteID))"/></m:ItemIds></m:GetItem>
        """
    }

    public func inlineImages(remoteID: String, contentIDs: Set<String>) async throws -> [String: InlineImage] {
        let doc = try await client.call("""
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties><t:FieldURI FieldURI="item:Attachments"/></t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds><t:ItemId Id="\(xmlEscape(remoteID))"/></m:ItemIds></m:GetItem>
            """)
        guard let item = doc.first("Items")?.elementChildren.first else { return [:] }
        let ids = Self.inlineAttachmentIDs(item, wanted: contentIDs)
        guard !ids.isEmpty else { return [:] }
        // Not strict: one attachment that fails shouldn't lose the others.
        return Self.parseInlineImages(try await client.call(Self.attachmentRequest(ids), strict: false))
    }

    /// Image attachments the HTML refers to, whether or not Exchange marks them inline. Attachments with a generic
    /// type (`application/octet-stream`, or none) count too: some mailers send pictures that way.
    static func inlineAttachmentIDs(_ item: XMLNode, wanted: Set<String>) -> [String] {
        (item.child("Attachments")?.children("FileAttachment") ?? []).compactMap { a in
            let type = a.text("ContentType")?.lowercased() ?? ""
            guard type.hasPrefix("image/") || isGeneric(type),
                  let cid = a.text("ContentId").map(contentID), wanted.contains(cid) else { return nil }
            return a.child("AttachmentId")?.attr("Id")
        }
    }

    public func attachment(remoteID: String, index: Int) async throws -> Data {
        // The IDs are looked up when opening, not stored: a moved message's attachments get new IDs.
        let doc = try await client.call("""
            <m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape>\
            <t:AdditionalProperties><t:FieldURI FieldURI="item:Attachments"/></t:AdditionalProperties></m:ItemShape>\
            <m:ItemIds><t:ItemId Id="\(xmlEscape(remoteID))"/></m:ItemIds></m:GetItem>
            """)
        let listed = doc.first("Items")?.elementChildren.first.map(Self.listedAttachments) ?? []
        guard listed.indices.contains(index), let id = listed[index].id else {
            throw EWSError(code: "ErrorAttachmentNotFound", message: "The attachment is no longer on the server")
        }
        guard let data = Self.parseAttachmentContent(try await client.call(Self.attachmentContentRequest(id))) else {
            throw EWSError(code: "ErrorAttachmentEmpty", message: "The server sent no content for the attachment")
        }
        return data
    }

    /// The attachments shown below a message, in order, with the IDs to fetch them. Inline pictures (signature
    /// logos and the like) are left out; an attached message is listed as a .eml file. An inline file that isn't a
    /// picture is listed too, since only pictures are placed in the body, and so is one without a name (it gets
    /// "Attachment"). Those come last, so the positions of the other files stay as they were in bodies stored before.
    static func listedAttachments(_ item: XMLNode) -> [(id: String?, attachment: Attachment)] {
        let all = item.child("Attachments")?.elementChildren ?? []
        let named = { (a: XMLNode) in !(a.child("Name")?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let old = all.filter { $0.text("IsInline") != "true" && named($0) }
        let added = all.filter { a in !old.contains { $0 === a } && (a.text("IsInline") != "true" || !isPicture(a)) }
        return (old + added).map { a in
            let isMessage = a.localName == "ItemAttachment"
            let type = isMessage ? "message/rfc822" : a.text("ContentType")
            var name = a.child("Name")?.stringValue ?? ""
            if name.trimmingCharacters(in: .whitespaces).isEmpty {
                let ext = isMessage ? nil : type.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
                name = "Attachment" + (ext.map { "." + $0 } ?? "")
            }
            // A cloud file (OneDrive, SharePoint) is a link: it opens as an Internet location, in the browser.
            if a.localName == "ReferenceAttachment" {
                return (a.child("AttachmentId")?.attr("Id"), Attachment(name: name + ".webloc", contentType: nil))
            }
            let file = isMessage && !name.lowercased().hasSuffix(".eml") ? name + ".eml" : name
            return (a.child("AttachmentId")?.attr("Id"),
                    Attachment(name: file, size: a.text("Size").flatMap { Int($0) }, contentType: type))
        }
    }

    /// MIME content too, so an attached message arrives as a whole .eml.
    static func attachmentContentRequest(_ id: String) -> String {
        "<m:GetAttachment><m:AttachmentShape><t:IncludeMimeContent>true</t:IncludeMimeContent></m:AttachmentShape>"
            + "<m:AttachmentIds><t:AttachmentId Id=\"\(xmlEscape(id))\"/></m:AttachmentIds></m:GetAttachment>"
    }

    /// A file's content, or an attached message's MIME source. Only the returned attachment itself is read, never
    /// the files or messages attached inside an attached message.
    static func parseAttachmentContent(_ doc: XMLDocument) -> Data? {
        guard let a = doc.first("Attachments")?.elementChildren.first else { return nil }
        if a.localName == "ReferenceAttachment" { return a.text("AttachLongPathName").flatMap(webloc) }
        let b64 = a.localName == "ItemAttachment"
            ? a.elementChildren.lazy.compactMap { $0.child("MimeContent")?.stringValue }.first
            : a.child("Content")?.stringValue
        return b64.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }

    /// An Internet location file (.webloc) for a web link; nil for any other kind of link.
    static func webloc(_ link: String) -> Data? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }

    static func attachmentRequest(_ ids: [String]) -> String {
        "<m:GetAttachment><m:AttachmentShape/><m:AttachmentIds>"
            + ids.map { "<t:AttachmentId Id=\"\(xmlEscape($0))\"/>" }.joined()
            + "</m:AttachmentIds></m:GetAttachment>"
    }

    static func parseInlineImages(_ doc: XMLDocument) -> [String: InlineImage] {
        var images = [String: InlineImage]()
        for a in doc.all("FileAttachment") {
            guard let cid = a.text("ContentId").map(contentID),
                  let b64 = a.text("Content"), let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { continue }
            var type = a.text("ContentType") ?? ""
            if isGeneric(type.lowercased()) {
                type = a.text("Name").flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension)?.preferredMIMEType }
                    ?? "application/octet-stream"
            }
            images[cid] = InlineImage(contentType: type, data: data)
        }
        return images
    }

    /// A file the body can show in place: an image type, or a generic one whose name isn't of another kind.
    static func isPicture(_ a: XMLNode) -> Bool {
        guard a.localName == "FileAttachment" else { return false }
        let type = a.text("ContentType")?.lowercased() ?? ""
        if type.hasPrefix("image/") { return true }
        guard isGeneric(type) else { return false }
        let ext = ((a.text("Name") ?? "") as NSString).pathExtension
        return UTType(filenameExtension: ext).map { $0.conforms(to: .image) || !$0.isDeclared } ?? true
    }

    /// A content type that says nothing about the content.
    private static func isGeneric(_ type: String) -> Bool { type.isEmpty || type == "application/octet-stream" }

    static func contentID(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }

    /// Asked of every item when its body loads; only meeting requests return them (checked on the real server).
    static let inviteProps = ["calendar:Start", "calendar:End", "calendar:Location", "calendar:IsAllDayEvent",
                              "calendar:Organizer", "calendar:RequiredAttendees", "calendar:OptionalAttendees"]
        .map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        Self.parseEvents(try await client.call(Self.calendarViewRequest(from: from, to: to)))
    }

    static func calendarViewRequest(from: Date, to: Date) -> String {
        let f = ISO8601DateFormatter()
        return "<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>"
            + ["item:Subject", "calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:LegacyFreeBusyStatus"]
                .map { "<t:FieldURI FieldURI=\"\($0)\"/>" }.joined()
            + "</t:AdditionalProperties></m:ItemShape>"
            + "<m:CalendarView StartDate=\"\(f.string(from: from))\" EndDate=\"\(f.string(from: to))\"/>"
            + "<m:ParentFolderIds><t:DistinguishedFolderId Id=\"calendar\"/></m:ParentFolderIds></m:FindItem>"
    }

    static func parseEvents(_ doc: XMLDocument) -> [CalendarEvent] {
        (doc.first("Items")?.elementChildren ?? []).compactMap { e in
            guard let start = e.text("Start").flatMap(isoDate), let end = e.text("End").flatMap(isoDate) else { return nil }
            let busy: BusyStatus = switch e.text("LegacyFreeBusyStatus") {
            case "Free": .free
            case "Tentative": .tentative
            case "Busy": .busy
            case "OOF", "WorkingElsewhere": .away
            default: .unknown
            }
            return CalendarEvent(subject: e.child("Subject")?.stringValue ?? "", start: start, end: end,
                                 isAllDay: e.text("IsAllDayEvent") == "true", busy: busy)
        }
    }

    static func parseInvite(_ item: XMLNode) -> Invite? {
        guard let start = item.child("Start")?.stringValue.flatMap(isoDate),
              let end = item.child("End")?.stringValue.flatMap(isoDate) else { return nil }
        let attendees = { (tag: String) in (item.child(tag)?.children("Attendee") ?? []).compactMap { $0.child("Mailbox").map(contact) } }
        return Invite(start: start, end: end, location: item.child("Location")?.stringValue ?? "",
                      isAllDay: item.child("IsAllDayEvent")?.stringValue == "true",
                      organizer: item.child("Organizer")?.child("Mailbox").map(contact),
                      required: attendees("RequiredAttendees"), optional: attendees("OptionalAttendees"),
                      isCancellation: item.localName == "MeetingCancellation")
    }

    // MARK: Write-back

    public func respond(_ remoteID: String, _ reply: InviteReply) async throws {
        _ = try await client.call(Self.respondRequest(remoteID, reply))
    }

    /// Schema order: Body, ReferenceItemId, ProposedStart, ProposedEnd (proposals need Exchange 2013).
    /// Not sending uses SaveOnly, as the EWS Managed API's `Accept(false)` does.
    static func respondRequest(_ id: String, _ reply: InviteReply) -> String {
        let tag = switch reply.response {
        case .accept: "AcceptItem"
        case .tentative: "TentativelyAcceptItem"
        case .decline: "DeclineItem"
        }
        let f = ISO8601DateFormatter()
        var inner = reply.comment.map { "<t:Body BodyType=\"Text\">\(xmlEscape($0))</t:Body>" } ?? ""
        inner += "<t:ReferenceItemId Id=\"\(xmlEscape(id))\"/>"
        if let s = reply.proposedStart, let e = reply.proposedEnd {
            inner += "<t:ProposedStart>\(f.string(from: s))</t:ProposedStart><t:ProposedEnd>\(f.string(from: e))</t:ProposedEnd>"
        }
        return "<m:CreateItem MessageDisposition=\"\(reply.send ? "SendAndSaveCopy" : "SaveOnly")\"><m:Items>"
            + "<t:\(tag)>\(inner)</t:\(tag)></m:Items></m:CreateItem>"
    }

    public func removeFromCalendar(_ remoteID: String) async throws {
        _ = try await client.call(Self.removeFromCalendarRequest(remoteID))
    }

    /// Outlook's Remove from Calendar for a cancellation: takes the meeting off the calendar, tells no one.
    static func removeFromCalendarRequest(_ id: String) -> String {
        "<m:CreateItem MessageDisposition=\"SaveOnly\"><m:Items>"
            + "<t:RemoveItem><t:ReferenceItemId Id=\"\(xmlEscape(id))\"/></t:RemoveItem></m:Items></m:CreateItem>"
    }

    public func setRead(_ ids: [String], _ read: Bool) async throws {
        _ = try Self.checkBatch(await client.call(Self.updateRequest(ids, field: "message:IsRead", value: "<t:IsRead>\(read)</t:IsRead>"),
                                                  strict: false), ids: ids)
    }

    public func setFlagged(_ ids: [String], _ flagged: Bool) async throws {
        _ = try Self.checkBatch(await client.call(Self.flagRequest(ids, flagged: flagged), strict: false), ids: ids)
    }

    public func move(_ ids: [String], to folder: RemoteFolder) async throws -> [String: String] {
        try Self.checkBatch(await client.call(Self.moveRequest(ids, to: folder.id), strict: false), ids: ids)
    }

    /// An item that is already gone counts as erased.
    public func delete(_ ids: [String]) async throws {
        _ = try Self.checkBatch(await client.call(Self.deleteRequest(ids), strict: false), ids: ids, done: ["ErrorItemNotFound"])
    }

    /// Exchange answers a batch with one response message per item, in request order, and changes each item on its
    /// own. Returns the new IDs of moved items (old → new). Refused items are thrown as `PartlyRefused`, together
    /// with the new IDs of those that moved. Codes in `done` count as success.
    static func checkBatch(_ doc: XMLDocument, ids: [String], done: Set<String> = []) throws -> [String: String] {
        let replies = doc.first("ResponseMessages")?.elementChildren ?? []
        guard replies.count == ids.count else {
            throw EWSError(code: "ErrorInvalidResponse", message: "Exchange answered \(replies.count) of \(ids.count) items")
        }
        var moved: [String: String] = [:], refused: [String: String] = [:]
        for (id, reply) in zip(ids, replies) {
            let code = reply.child("ResponseCode")?.stringValue ?? ""
            if code == "NoError" || done.contains(code) {
                if let new = reply.first("ItemId")?.attr("Id") { moved[id] = new }
            } else {
                refused[id] = "\(reply.child("MessageText")?.stringValue ?? "Request failed") (\(code))"
            }
        }
        if !refused.isEmpty { throw PartlyRefused(refused: refused, moved: moved) }
        return moved
    }

    public func send(_ draft: Draft) async throws {
        guard !draft.attachments.isEmpty else { return _ = try await client.call(Self.createRequest(draft, send: true)) }
        let item = try await saveWithAttachments(draft)
        do { try await client.call(Self.sendItemRequest(item)) } catch {
            // The app keeps the message in Drafts on this Mac; don't leave a second copy in Exchange's Drafts.
            // If it did go out, the item is in Sent Items under a new ID and this delete misses it.
            try await deleteOrHandBack(item.id, after: error)
        }
    }

    public func saveDraft(_ draft: Draft) async throws {
        guard !draft.attachments.isEmpty else { return _ = try await client.call(Self.createRequest(draft, send: false)) }
        _ = try await saveWithAttachments(draft)
    }

    /// The documented EWS order for files: create the message in Drafts, then add them.
    /// Returns the item with the change key it has after the files were added.
    private func saveWithAttachments(_ draft: Draft) async throws -> ItemRef {
        let ids = Self.contentIDs(draft)
        guard let item = Self.parseCreatedItem(try await client.call(Self.createRequest(draft, send: false, contentIDs: ids))) else {
            throw EWSError(code: "ErrorItemNotCreated", message: "Exchange didn't return the new message")
        }
        do {
            guard let root = Self.parseRootItem(try await client.call(Self.createAttachmentRequest(parentID: item.id, draft.attachments, contentIDs: ids)))
            else { throw EWSError(code: "ErrorAttachmentNotCreated", message: "Exchange didn't take the attachments") }
            return root
        } catch {
            try await deleteOrHandBack(item.id, after: error)  // no half message in Exchange's Drafts
        }
    }

    /// Removes an item created for a send or save that then failed, and throws `failure`. If the removal fails too,
    /// throws `LeftOnServer`, so the item is erased later.
    private func deleteOrHandBack(_ id: String, after failure: Error) async throws -> Never {
        do { try await delete([id]) } catch { throw LeftOnServer(remoteID: id, error: failure) }
        throw failure
    }

    public func maxMessageSize(from address: String) async throws -> Int? {
        Self.parseMaxMessageSize(try await client.call(Self.mailTipsRequest(from: address)))
    }

    /// MailTips, as Outlook uses them: the sender's own MaxMessageSize (Exchange 2010 and later).
    static func mailTipsRequest(from address: String) -> String {
        let me = "<t:EmailAddress>\(xmlEscape(address))</t:EmailAddress>"
        return "<m:GetMailTips><m:SendingAs>\(me)</m:SendingAs><m:Recipients><t:Mailbox>\(me)</t:Mailbox></m:Recipients>"
            + "<m:MailTipsRequested>MaxMessageSize</m:MailTipsRequested></m:GetMailTips>"
    }

    static func parseMaxMessageSize(_ doc: XMLDocument) -> Int? { doc.text("MaxMessageSize").flatMap { Int($0) } }

    struct ItemRef: Equatable { let id: String, changeKey: String }

    static func parseCreatedItem(_ doc: XMLDocument) -> ItemRef? {
        guard let i = doc.first("ItemId"), let id = i.attr("Id"), let ck = i.attr("ChangeKey") else { return nil }
        return ItemRef(id: id, changeKey: ck)
    }

    /// The item's change key after the last attachment was added.
    static func parseRootItem(_ doc: XMLDocument) -> ItemRef? {
        guard let a = doc.all("AttachmentId").last, let id = a.attr("RootItemId"), let ck = a.attr("RootItemChangeKey")
        else { return nil }
        return ItemRef(id: id, changeKey: ck)
    }

    /// A content ID per picture placed in the text, for the HTML body to point at.
    static func contentIDs(_ d: Draft) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: d.placedPictures.map { ($0, UUID().uuidString) })
    }

    /// Files in `contentIDs` are inline: shown in the HTML body where it references them, not in the list.
    static func createAttachmentRequest(parentID: String, _ files: [DraftAttachment], contentIDs: [Int: String] = [:]) -> String {
        "<m:CreateAttachment><m:ParentItemId Id=\"\(xmlEscape(parentID))\"/><m:Attachments>"
            + files.enumerated().map { i, f in
                "<t:FileAttachment><t:Name>\(xmlEscape(f.name))</t:Name>"
                    + "<t:ContentType>\(xmlEscape(f.contentType ?? "application/octet-stream"))</t:ContentType>"
                    + (contentIDs[i].map { "<t:ContentId>\(xmlEscape($0))</t:ContentId><t:IsInline>true</t:IsInline>" } ?? "")
                    + "<t:Content>\(f.data.base64EncodedString())</t:Content></t:FileAttachment>"
            }.joined()
            + "</m:Attachments></m:CreateAttachment>"
    }

    /// Sends the saved item and keeps a copy in Sent Items.
    static func sendItemRequest(_ item: ItemRef) -> String {
        "<m:SendItem SaveItemToFolder=\"true\"><m:ItemIds><t:ItemId Id=\"\(xmlEscape(item.id))\" "
            + "ChangeKey=\"\(xmlEscape(item.changeKey))\"/></m:ItemIds>"
            + "<m:SavedItemFolderId><t:DistinguishedFolderId Id=\"sentitems\"/></m:SavedItemFolderId></m:SendItem>"
    }

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

    /// With content IDs (pictures placed in the text) the body goes as HTML that shows them in their place.
    static func createRequest(_ d: Draft, send: Bool, contentIDs: [Int: String] = [:]) -> String {
        func recipients(_ tag: String, _ list: String) -> String {
            let boxes = Contact.parseList(list).map {
                "<t:Mailbox><t:Name>\(xmlEscape($0.name))</t:Name><t:EmailAddress>\(xmlEscape($0.email))</t:EmailAddress></t:Mailbox>"
            }
            return boxes.isEmpty ? "" : "<t:\(tag)>\(boxes.joined())</t:\(tag)>"
        }
        let disposition = send ? "SendAndSaveCopy" : "SaveOnly"
        return "<m:CreateItem MessageDisposition=\"\(disposition)\"><m:SavedItemFolderId>"
            + "<t:DistinguishedFolderId Id=\"\(send ? "sentitems" : "drafts")\"/></m:SavedItemFolderId><m:Items><t:Message>"
            + "<t:Subject>\(xmlEscape(d.subject))</t:Subject>"
            + (contentIDs.isEmpty ? "<t:Body BodyType=\"Text\">\(xmlEscape(d.text))</t:Body>"
                : "<t:Body BodyType=\"HTML\">\(xmlEscape(d.html { contentIDs[$0] }))</t:Body>")
            + recipients("ToRecipients", d.to) + recipients("CcRecipients", d.cc)
            + "</t:Message></m:Items></m:CreateItem>"
    }

    // MARK: Parsing

    static let countProp = "<t:AdditionalProperties><t:FieldURI FieldURI=\"folder:TotalCount\"/></t:AdditionalProperties>"

    static func parseGetFolder(_ doc: XMLDocument) -> [RemoteFolder] {
        let replies = doc.all("GetFolderResponseMessage")
        return zip(distinguished, replies).compactMap { pair, reply in
            guard reply.attr("ResponseClass") == "Success", let id = reply.first("FolderId")?.attr("Id") else { return nil }
            return RemoteFolder(role: pair.0, id: id, totalCount: Int(reply.text("TotalCount") ?? "") ?? 0)
        }
    }

    /// One page of every folder below the mailbox root. Exchange returns at most 1000 per call.
    static func findFoldersRequest(offset: Int) -> String {
        """
        <m:FindFolder Traversal="Deep"><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape>\
        <t:AdditionalProperties><t:FieldURI FieldURI="folder:DisplayName"/><t:FieldURI FieldURI="folder:TotalCount"/>\
        <t:FieldURI FieldURI="folder:ParentFolderId"/><t:FieldURI FieldURI="folder:FolderClass"/>\
        <t:ExtendedFieldURI PropertyTag="0x10F4" PropertyType="Boolean"/>\
        </t:AdditionalProperties></m:FolderShape>\
        <m:IndexedPageFolderView MaxEntriesReturned="1000" Offset="\(offset)" BasePoint="Beginning"/>\
        <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds></m:FindFolder>
        """
    }

    /// Where the next FindFolder page starts, or nil after the last one.
    static func nextFolderOffset(_ doc: XMLDocument) -> Int? {
        guard let root = doc.first("RootFolder"), root.attr("IncludesLastItemInRange") == "false" else { return nil }
        return Int(root.attr("IndexedPagingOffset") ?? "")
    }

    /// A top-level folder named Archive; Outlook creates it under the mailbox root, not in the Inbox. A nested
    /// one (in a project folder, or a deleted one in Deleted Items) is an ordinary folder.
    static func archiveFolder(_ folders: [XMLNode]) -> RemoteFolder? {
        let names: Set<String> = ["archive", "archiv"]
        let ids = Set(folders.compactMap { $0.child("FolderId")?.attr("Id") })
        let matches = folders.filter { names.contains(($0.text("DisplayName") ?? "").lowercased()) }
        let topLevel = matches.first { !ids.contains($0.child("ParentFolderId")?.attr("Id") ?? "") }
        guard let f = topLevel, let id = f.child("FolderId")?.attr("Id") else { return nil }
        return RemoteFolder(role: .archive, id: id, totalCount: Int(f.text("TotalCount") ?? "") ?? 0)
    }

    /// The user's own mail folders from a deep FindFolder, each with its parent. Calendar, contacts and other
    /// non-mail folders, hidden folders and `skip` (with everything under them) are left out; `known` folders
    /// keep their standard role. A parent that isn't in the result is the mailbox root: the folder is top-level.
    static func folderTree(_ folders: [XMLNode], known: [RemoteFolder], skip: Set<String>) -> [RemoteFolder] {
        struct F { let id: String, parent: String, name: String, count: Int, mail: Bool }
        // `Folder` elements only: CalendarFolder, ContactsFolder, TasksFolder and SearchFolder are other tags.
        let all = folders.compactMap { f -> F? in
            guard let id = f.child("FolderId")?.attr("Id") else { return nil }
            let cls = f.text("FolderClass")
            let hidden = f.child("ExtendedProperty")?.text("Value")?.lowercased() == "true"
            return F(id: id, parent: f.child("ParentFolderId")?.attr("Id") ?? "", name: f.text("DisplayName") ?? "",
                     count: Int(f.text("TotalCount") ?? "") ?? 0, mail: !hidden && (cls == nil || cls == "IPF.Note"))
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let roles = Dictionary(known.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        // Shown only if it and every folder above it is a shown mail folder.
        func shown(_ f: F) -> Bool {
            var cur: F? = f, seen = Set<String>()
            while let c = cur, seen.insert(c.id).inserted {
                if !c.mail || skip.contains(c.id) { return false }
                cur = byID[c.parent]
            }
            return true
        }
        return all.filter { roles[$0.id] == nil && shown($0) }.map { f in
            let parent: MailboxKind? = byID[f.parent] == nil ? nil : roles[f.parent] ?? .folder(f.parent)
            return RemoteFolder(role: .folder(f.id), id: f.id, totalCount: f.count, name: f.name, parent: parent)
        }
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

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    /// An `xs:dateTime`: fractional seconds of any length are allowed, and a time without a zone is read as UTC,
    /// which EWS uses unless a request asks for another zone.
    static func isoDate(_ text: String) -> Date? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"(Z|[+-]\d\d:\d\d)$"#, options: .regularExpression) == nil { s += "Z" }
        var fraction = 0.0
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            fraction = Double("0" + s[r]) ?? 0
            s.removeSubrange(r)
        }
        return isoFormatter.date(from: s)?.addingTimeInterval(fraction)
    }

    /// A list summary: no body yet, recipients as display names only.
    static func message(_ item: XMLNode) -> Message? {
        guard let rid = item.child("ItemId")?.attr("Id") else { return nil }
        let from = item.child("From").map(contact) ?? Contact(name: "", email: "")
        var m = Message(accountID: UUID(), from: from, to: names(item.text("DisplayTo")), cc: names(item.text("DisplayCc")),
                       subject: item.child("Subject")?.stringValue ?? "",
                       body: "", date: item.text("DateTimeReceived").flatMap(isoDate) ?? .distantPast,
                       isRead: item.text("IsRead") == "true",
                       flag: item.child("Flag")?.text("FlagStatus") == "Flagged" ? .red : nil,
                       remoteID: rid, hasAttachments: item.text("HasAttachments") == "true",
                       serverPreview: item.child("Preview")?.stringValue ?? "", bodyLoaded: false,
                       isInvite: ["MeetingRequest", "MeetingCancellation"].contains(item.localName ?? ""))
        m.conversationID = item.child("ConversationId")?.attr("Id")
        return m
    }

    static func parseBody(_ item: XMLNode) -> MessageBody {
        let attachments = listedAttachments(item).map(\.attachment)
        let body = item.child("Body")
        let html = body?.attr("BodyType") == "HTML" ? body?.stringValue : nil
        // An empty TextBody next to an HTML body says nothing: the text comes from the HTML then.
        let textBody = item.child("TextBody")?.stringValue.flatMap { $0.allSatisfy(\.isWhitespace) && html != nil ? nil : $0 }
        let text = textBody ?? html.map(plainText) ?? body?.stringValue ?? ""
        return MessageBody(text: text, attachments: attachments,
                           from: item.child("From").map(contact),
                           to: item.child("ToRecipients").map(mailboxes) ?? [],
                           cc: item.child("CcRecipients").map(mailboxes) ?? [], invite: parseInvite(item), html: html)
    }

    /// Rough text of an HTML body, used only if the server sends no `TextBody`. One pass, so an unclosed tag or
    /// comment can't make it slow: comments, head, style and script are dropped (an unclosed one to the end),
    /// `<br>` and the end of a block are line breaks, the end of a table cell a space, other tags go, and
    /// character references are decoded.
    static func plainText(_ html: String) -> String {
        let s = html as NSString, n = s.length
        var out = "", i = 0, textStart = 0
        func find(_ x: String, from: Int, _ options: NSString.CompareOptions = []) -> Int? {
            guard from <= n else { return nil }
            let r = s.range(of: x, options: options, range: NSRange(location: from, length: n - from))
            return r.location == NSNotFound ? nil : r.location
        }
        func flush(_ end: Int) {
            if end > textStart { out += decodeEntities(s.substring(with: NSRange(location: textStart, length: end - textStart))) }
        }
        while i < n {
            guard s.character(at: i) == 0x3C else { i += 1; continue }  // <
            flush(i)
            if find("<!--", from: i, .anchored) != nil {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                textStart = i
                continue
            }
            guard let gt = find(">", from: i + 1) else { textStart = i; break }  // not a tag: text to the end
            let tag = s.substring(with: NSRange(location: i + 1, length: gt - i - 1))
            i = gt + 1
            textStart = i
            let closing = tag.hasPrefix("/")
            let name = String(tag.drop { $0 == "/" }.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }).lowercased()
            if !closing, ["head", "style", "script"].contains(name) {
                i = find("</" + name, from: i, .caseInsensitive).map { find(">", from: $0).map { $0 + 1 } ?? n } ?? n
                textStart = i
            } else if name == "br" || closing && ["p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6"].contains(name) {
                out += "\n"
            } else if closing && (name == "td" || name == "th") {
                out += " "
            }
        }
        flush(n)
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// `&name;`, `&#nnn;` and `&#xhh;` decoded; a no-break space becomes a space. Unknown names stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = "", rest = text[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            guard let semi = rest.prefix(34).firstIndex(of: ";") else { out += "&"; rest = rest.dropFirst(); continue }
            let ref = rest[rest.index(after: amp)..<semi]
            var scalar: Unicode.Scalar?
            if ref.hasPrefix("#x") || ref.hasPrefix("#X") {
                scalar = UInt32(ref.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
            } else if ref.hasPrefix("#") {
                scalar = UInt32(ref.dropFirst()).flatMap(Unicode.Scalar.init)
            } else {
                scalar = namedEntities[String(ref)].flatMap(Unicode.Scalar.init)
            }
            guard let c = scalar, c.value != 0 else { out += "&"; rest = rest.dropFirst(); continue }
            out.unicodeScalars.append(c.value == 0xA0 ? " " : c)
            rest = rest[rest.index(after: semi)...]
        }
        return out + rest
    }

    /// HTML's Latin-1 names (U+00A0 to U+00FF, in order) and the common punctuation ones.
    static let namedEntities: [String: UInt32] = {
        let latin1 = """
            nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 \
            acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml \
            Aring AElig Ccedil Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde \
            Ouml times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig \
            ccedil egrave eacute ecirc euml igrave iacute icirc iuml eth ntilde ograve oacute ocirc otilde ouml divide \
            oslash ugrave uacute ucirc uuml yacute thorn yuml
            """.split(separator: " ")
        var map = Dictionary(uniqueKeysWithValues: latin1.enumerated().map { (String($0.element), UInt32(0xA0 + $0.offset)) })
        let more: [String: UInt32] = [
            "amp": 38, "lt": 60, "gt": 62, "quot": 34, "apos": 39, "OElig": 338, "oelig": 339, "Scaron": 352,
            "scaron": 353, "Yuml": 376, "ensp": 8194, "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205,
            "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217, "sbquo": 8218, "ldquo": 8220, "rdquo": 8221,
            "bdquo": 8222, "dagger": 8224, "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240,
            "lsaquo": 8249, "rsaquo": 8250, "euro": 8364, "trade": 8482,
        ]
        map.merge(more) { a, _ in a }
        return map
    }()

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
