import AppKit
import MailModel
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The attachments below a message, as in Mail: pictures and PDFs shown in place, other files as their Finder icon.
/// Double-click opens, Space shows Quick Look, drag saves to the Finder, Control-click has Mail's menu.
struct AttachmentsView: View {
    @Environment(MailStore.self) private var store
    let message: Message
    @State private var selected: Int?
    /// Pictures the user switched to an icon (View as Icon).
    @State private var asIcon: Set<Int> = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { i, a in
                if a.showsInPlace && !asIcon.contains(i) {
                    // A picture that can't be loaded goes to the icons: it can still be opened (trying again) or saved.
                    AttachmentPicture(message: message, index: i, selected: selected == i) { asIcon.insert(i) }
                        .modifier(AttachmentActions(message: message, index: i, asIcon: $asIcon, selected: $selected))
                }
            }
            let icons = message.attachments.indices.filter { !message.attachments[$0].showsInPlace || asIcon.contains($0) }
            if !icons.isEmpty {
                FlowRow(spacing: 14) {
                    ForEach(icons, id: \.self) { i in
                        AttachmentIcon(attachment: message.attachments[i], selected: selected == i)
                            .modifier(AttachmentActions(message: message, index: i, asIcon: $asIcon, selected: $selected))
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard let i = selected else { return .ignored }
            Task { await store.quickLookAttachments(of: message.id, at: i) }
            return .handled
        }
        .onChange(of: selected) { if selected != nil { focused = true } }
        .onChange(of: message.id) { selected = nil; asIcon = [] }
    }
}

extension Attachment {
    var type: UTType? {
        contentType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (name as NSString).pathExtension)
    }

    /// Pictures are shown in place, as Mail does.
    var isPicture: Bool { type?.conforms(to: .image) == true }

    /// Pictures and PDFs (every page) are shown in place, as Mail does.
    var showsInPlace: Bool { isPicture || type?.conforms(to: .pdf) == true }

    /// "Report.pdf (1.2 MB)", Mail's AttachmentNameAndSizeFormat.
    var nameAndSize: String {
        guard let size else { return name }
        return "\(name) (\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))"
    }
}

/// A file as its Finder icon with the name and size below.
struct AttachmentIcon: View {
    let attachment: Attachment
    let selected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(for: attachment.type ?? .data))
                .resizable().frame(width: 48, height: 48)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.secondary.opacity(0.2) : .clear))
            Text(attachment.name)
                .font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                .padding(.horizontal, 3)
                .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? .white : .primary)
            if let size = attachment.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 96)
        .help(attachment.nameAndSize)
    }
}

/// A picture, or each page of a PDF, shown in place, at most as wide as the message.
private struct AttachmentPicture: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let index: Int
    let selected: Bool
    /// The file couldn't be had or isn't a picture NSImage can draw: no endless spinner.
    let failed: () -> Void
    @State private var images: [NSImage]?
    private var isPDF: Bool { message.attachments[index].type?.conforms(to: .pdf) == true }

    var body: some View {
        Group {
            if let images {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(images.indices, id: \.self) { i in
                        Image(nsImage: images[i]).resizable().aspectRatio(contentMode: .fit)
                            // A white PDF page on the white message: a hairline and a soft shadow show where it ends.
                            .overlay { if isPDF { Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 1) } }
                            .shadow(color: .black.opacity(isPDF ? 0.15 : 0), radius: 3, y: 1)
                            .frame(maxWidth: min(images[i].size.width, 640), alignment: .leading)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1))
                    .frame(width: 240, height: 160).overlay(ProgressView().controlSize(.small))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.accentColor, lineWidth: selected ? 3 : 0))
        .help(message.attachments[index].nameAndSize)
        .task(id: message.id) {
            images = nil
            let url = await store.attachmentFile(index, of: message.id)
            if Task.isCancelled { return }  // another message was selected: nothing failed
            if let pictures = url.flatMap({ Self.pictures($0, pdf: isPDF) }) { images = pictures } else { failed() }
        }
    }

    /// The picture, or each page of a PDF drawn as it is printed (vector, so it stays sharp at any size).
    private static func pictures(_ url: URL, pdf: Bool) -> [NSImage]? {
        guard pdf else { return NSImage(contentsOf: url).map { [$0] } }
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return nil }
        return (0..<doc.pageCount).compactMap(doc.page).map { page in
            var size = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
            return NSImage(size: size, flipped: false) { r in
                guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                NSColor.white.setFill()
                r.fill()
                page.draw(with: .cropBox, to: ctx)
                return true
            }
        }
    }
}

/// Click, double-click, drag and the Control-click menu of one attachment.
private struct AttachmentActions: ViewModifier {
    @Environment(MailStore.self) private var store
    let message: Message
    let index: Int
    @Binding var asIcon: Set<Int>
    @Binding var selected: Int?

    private var attachment: Attachment { message.attachments[index] }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { open() }
            .onTapGesture { selected = index }
            .onDrag { dragItem() }
            .contextMenu { menu }
    }

    /// Items and order from Mail's ViewAttachmentContextMenu.nib.
    @ViewBuilder private var menu: some View {
        Button("Open Attachment") { open() }
        Menu("Open With") {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: attachment.type ?? .data)
            ForEach(apps, id: \.self) { app in
                Button(FileManager.default.displayName(atPath: app.path)) { open(with: app) }
            }
            if !apps.isEmpty { Divider() }
            Button("Other…") { chooseApp() }
        }
        Button("Quick Look Attachment") { Task { await store.quickLookAttachments(of: message.id, at: index) } }
        Divider()
        Button("Save Attachment…") { AttachmentPanels.save(index, of: message, store: store) }
        Button("Save to Downloads Folder") {
            Task { _ = await store.saveAttachment(index, of: message.id, to: AttachmentPanels.downloads) }
        }
        if attachment.showsInPlace {
            Divider()
            if asIcon.contains(index) {
                Button("View in Place") { asIcon.remove(index) }
            } else {
                Button("View as Icon") { asIcon.insert(index) }
            }
        }
    }

    private func open(with app: URL? = nil) {
        Task {
            guard let url = await store.attachmentFile(index, of: message.id) else { return }
            if let app {
                _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        if panel.runModal() == .OK, let app = panel.url { open(with: app) }
    }

    /// The Finder gets the file once it has been fetched, so dragging works before the attachment is downloaded.
    private func dragItem() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = attachment.fileName
        let (store, id, index) = (store, message.id, index)
        provider.registerFileRepresentation(forTypeIdentifier: (attachment.type ?? .data).identifier,
                                            fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = await store.originalAttachmentFile(index, of: id) { done(url, false, nil) } else {
                    done(nil, false, CocoaError(.fileReadUnknown))
                }
            }
            return nil
        }
        return provider
    }
}

/// Save panels for attachments, shared by the menus.
@MainActor
enum AttachmentPanels {
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    /// Save Attachment…: a save panel with the attachment's name.
    static func save(_ index: Int, of message: Message, store: MailStore) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = message.attachments[index].fileName
        panel.directoryURL = downloads
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let file = await store.originalAttachmentFile(index, of: message.id) else { return }
            try? FileManager.default.removeItem(at: url)  // the panel already asked about replacing it
            do { try FileManager.default.copyItem(at: file, to: url) } catch {
                store.status = "Couldn't save “\(url.lastPathComponent)”: \(error.localizedDescription)"
            }
        }
    }

    /// File ▸ Save Attachments…: asks for a folder, then saves every attachment there.
    static func saveAll(of message: Message, store: MailStore) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = downloads
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { _ = await store.saveAllAttachments(of: message.id, to: folder) }
    }
}

/// The header's attachment button: the count, and a menu to save one or all or look at them.
struct AttachmentButton: View {
    @Environment(MailStore.self) private var store
    let message: Message

    var body: some View {
        Menu {
            ForEach(Array(message.attachments.enumerated()), id: \.offset) { i, a in
                Button(a.nameAndSize) {
                    Task { _ = await store.saveAttachment(i, of: message.id, to: AttachmentPanels.downloads) }
                }
            }
            Divider()
            Button("Save All…") { AttachmentPanels.saveAll(of: message, store: store) }
            Button("Quick Look \(message.attachments.count) Attachment\(message.attachments.count == 1 ? "" : "s")") {
                Task { await store.quickLookAttachments(of: message.id) }
            }
        } label: {
            Label("\(message.attachments.count)", systemImage: "paperclip")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Lays the icons out left to right and wraps them, like Mail's attachment row.
struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (i, x) in row.items { subviews[i].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified) }
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [(Int, CGFloat)], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var items: [(Int, CGFloat)] = [], x: CGFloat = 0, y: CGFloat = 0, h: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                rows.append((items, y, x - spacing, h)); y += h + spacing; items = []; x = 0; h = 0
            }
            items.append((i, x)); x += s.width + spacing; h = max(h, s.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, h)) }
        return rows
    }
}
