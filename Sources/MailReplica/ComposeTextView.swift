import AppKit
import MailModel
import SwiftUI
import UniformTypeIdentifiers

/// The message text, with the files placed in it as in Mail: pictures shown in the text, other files as their
/// icon and name. They can be dragged to another place, cut and pasted, or deleted like a character.
/// `body` keeps a U+FFFC per file and `attachments` the files in that order (see `Draft.fileMark`).
/// Files added elsewhere (Attach, the original's files) arrive in `attachments` without a mark and are put
/// in at the insertion point, the original's at the end.
struct ComposeTextView: NSViewRepresentable {
    /// Only `body` and `attachments` are read and written.
    @Binding var draft: Draft
    /// Reads dropped files; nil where files can't be added (an invite answer).
    let files: (([URL]) -> [DraftAttachment])?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        // TextKit 1, so the attachment cell below draws the files.
        let view = DropTextView(usingTextLayoutManager: false)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isRichText = true  // attachments need it; the text itself stays plain (see `plain`)
        view.importsGraphics = files != nil
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.typingAttributes = DropTextView.plain
        view.files = files
        view.load(body: draft.body, attachments: draft.attachments)
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? DropTextView else { return }
        view.files = files
        view.importsGraphics = files != nil
        context.coordinator.updating = true
        view.sync(draft.attachments)
        context.coordinator.updating = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        var updating = false
        init(_ parent: ComposeTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let v = note.object as? DropTextView else { return }
            v.normalize()
            let (body, files) = v.content()
            // One write for both, so the view never sees the files without their marks. An edit made while
            // SwiftUI updates the view is written back after it.
            let write = { [parent] in parent.draft.body = body; parent.draft.attachments = files }
            if updating { DispatchQueue.main.async(execute: write) } else { write() }
        }
    }
}

/// An attachment that knows its file. Pasted or moved ones come back from RTFD as plain `NSTextAttachment`s
/// and are turned into these again.
final class FileAttachment: NSTextAttachment {
    let file: DraftAttachment
    private let picture: NSImage
    private let size: CGSize

    init(_ file: DraftAttachment, width: CGFloat) {
        self.file = file
        if file.contentType?.hasPrefix("image/") == true, let p = NSImage(data: file.data), p.size.width > 0 {
            // Pictures in the text, scaled down to the width of the window, as Mail shows them.
            let scale = min(1, width / p.size.width)
            picture = p
            size = CGSize(width: p.size.width * scale, height: p.size.height * scale)
        } else {
            picture = Self.icon(file)
            size = picture.size
        }
        super.init(data: nil, ofType: nil)
        // The file goes to the pasteboard (RTFD) when the attachment is cut, copied or moved. Setting `image`
        // instead of drawing it here would put the picture there in place of the file.
        let wrapper = FileWrapper(regularFileWithContents: file.data)
        wrapper.preferredFilename = file.name
        fileWrapper = wrapper
        // Drawn by this cell; the file wrapper alone would draw the file's content (a PDF's page).
        let shown = picture.copy() as! NSImage
        shown.size = size
        attachmentCell = NSTextAttachmentCell(imageCell: shown)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The Finder icon with the name and size below, drawn when shown so it follows light and dark.
    static func icon(_ file: DraftAttachment) -> NSImage {
        let a = file.attachment
        let type = UTType(filenameExtension: (a.name as NSString).pathExtension) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        return NSImage(size: NSSize(width: 110, height: 100), flipped: true) { rect in
            icon.draw(in: NSRect(x: (rect.width - 56) / 2, y: 2, width: 56, height: 56))
            (a.name as NSString).draw(in: NSRect(x: 0, y: 62, width: rect.width, height: 17), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
            (size as NSString).draw(in: NSRect(x: 0, y: 80, width: rect.width, height: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
            return true
        }
    }
}

final class DropTextView: NSTextView {
    var files: (([URL]) -> [DraftAttachment])?
    /// Every file shown here so far: a file cut and pasted again is recognised, and keeps `fromOriginal`.
    private var known: [DraftAttachment] = []

    /// The mail goes out as plain text, so pasted text loses its fonts and colours.
    static let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]

    private var pictureWidth: CGFloat { max(100, (textContainer?.size.width ?? 500) - 20) }

    private func make(_ file: DraftAttachment) -> FileAttachment {
        if !known.contains(file) { known.append(file) }
        return FileAttachment(file, width: pictureWidth)
    }

    /// The text with a mark per file, and the files in order.
    func content() -> (String, [DraftAttachment]) {
        var found: [DraftAttachment] = []
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { value, _, _ in
            if let a = value as? FileAttachment { found.append(a.file) }
        }
        return (string, found)
    }

    func load(body: String, attachments: [DraftAttachment]) {
        let text = NSMutableAttributedString()
        var k = 0
        for c in body {
            if c == Draft.fileMark, attachments.indices.contains(k) {
                text.append(NSAttributedString(attachment: make(attachments[k])))
                k += 1
            } else if c != Draft.fileMark {
                text.append(NSAttributedString(string: String(c)))
            }
        }
        text.addAttributes(Self.plain, range: NSRange(location: 0, length: text.length))
        textStorage?.setAttributedString(text)
        if k < attachments.count { sync(attachments) }  // files without a place yet
    }

    /// Brings the text in line with files added or removed outside it (Attach, Include/Exclude Attachments).
    func sync(_ wanted: [DraftAttachment]) {
        var shown = content().1
        guard shown != wanted, let storage = textStorage else { return }
        // Removed: the last occurrences of files the draft no longer has.
        var extra = shown
        for f in wanted { if let i = extra.firstIndex(of: f) { extra.remove(at: i) } }
        if !extra.isEmpty {
            var ranges: [NSRange] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: .reverse) { value, range, _ in
                if let a = value as? FileAttachment, let i = extra.firstIndex(of: a.file) { extra.remove(at: i); ranges.append(range) }
            }
            for r in ranges { replace(r, with: NSAttributedString()) }
            shown = content().1
        }
        // Added: the original's files at the end, the others where the insertion point is.
        var missing = wanted
        for f in shown { if let i = missing.firstIndex(of: f) { missing.remove(at: i) } }
        for f in missing {
            if f.fromOriginal {
                let keep = selectedRange()  // the insertion point stays where the user had it
                insert([f], at: storage.length)
                setSelectedRange(keep)
            } else {
                insert([f], at: selectedRange().location)
            }
        }
    }

    /// Puts files in at `index`, as one undoable change, and leaves the insertion point after them.
    func insert(_ files: [DraftAttachment], at index: Int) {
        let text = NSMutableAttributedString()
        for f in files { text.append(NSAttributedString(attachment: make(f))) }
        text.addAttributes(Self.plain, range: NSRange(location: 0, length: text.length))
        let at = min(index, textStorage?.length ?? 0)
        replace(NSRange(location: at, length: 0), with: text)
        setSelectedRange(NSRange(location: at + text.length, length: 0))
    }

    private func replace(_ range: NSRange, with text: NSAttributedString) {
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
    }

    /// After a paste or a move: plain text again, and attachments that came back from RTFD know their file again.
    /// One that isn't a file (a pasted folder) is taken out: it would look attached and not be sent.
    func normalize() {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        var unusable: [NSRange] = []
        storage.beginEditing()
        storage.addAttributes(Self.plain, range: all)
        storage.removeAttribute(.backgroundColor, range: all)
        storage.removeAttribute(.link, range: all)
        storage.enumerateAttribute(.attachment, in: all) { value, range, _ in
            guard let a = value as? NSTextAttachment, !(a is FileAttachment) else { return }
            guard let w = a.fileWrapper, w.isRegularFile, let data = w.regularFileContents else { return unusable.append(range) }
            let name = w.preferredFilename ?? w.filename ?? "Attachment"
            let file = known.first { $0.name == name && $0.data == data }
                ?? DraftAttachment(name: name, contentType: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType,
                                   data: data)
            storage.addAttribute(.attachment, value: make(file), range: range)
        }
        for r in unusable.reversed() { storage.deleteCharacters(in: r) }
        storage.endEditing()
        if !unusable.isEmpty { undoManager?.removeAllActions() }
    }

    /// Files pasted from the Finder are attached like dropped ones (a folder as a zip).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type != .rtfd, type != NSPasteboard.PasteboardType("com.apple.flat-rtfd"), files != nil,
           pboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return attachFiles(from: pboard, at: selectedRange().location)
        }
        return super.readSelection(from: pboard, type: type)
    }

    // MARK: Dropping files

    /// Where dragged files would go, shown as a caret as in Mail. nil when nothing is dragged over the text.
    private(set) var dropIndex: Int? {
        didSet { if dropIndex != oldValue { needsDisplay = true } }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFileDrop(sender) else { return super.draggingEntered(sender) }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isFileDrop(sender) else { return super.draggingUpdated(sender) }
        guard files != nil else { return [] }
        showDrop(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndex = nil
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropIndex = nil
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isFileDrop(sender) else { return super.performDragOperation(sender) }
        let i = showDrop(at: convert(sender.draggingLocation, from: nil))
        dropIndex = nil
        window?.makeFirstResponder(self)
        return attachFiles(from: sender.draggingPasteboard, at: i)
    }

    /// Moves the drop caret to the place nearest `point` (in this view) and returns that character index.
    @discardableResult func showDrop(at point: NSPoint) -> Int {
        let i = characterIndexForInsertion(at: point)
        dropIndex = i
        return i
    }

    func hideDrop() { dropIndex = nil }

    /// The caret at character `index`: as tall as its line, at the left of that character (or after the last one).
    func caretRect(at index: Int) -> NSRect {
        let origin = textContainerOrigin
        let lineHeight = (layoutManager?.defaultLineHeight(for: Self.plain[.font] as! NSFont)) ?? 16
        guard let lm = layoutManager, let tc = textContainer, lm.numberOfGlyphs > 0 else {
            return NSRect(x: origin.x + (textContainer?.lineFragmentPadding ?? 5), y: origin.y, width: 2, height: lineHeight)
        }
        let length = textStorage?.length ?? 0
        var rect: NSRect
        if index >= length, !lm.extraLineFragmentRect.isEmpty {
            // After a final newline: the empty last line.
            rect = NSRect(x: lm.extraLineFragmentRect.minX + tc.lineFragmentPadding, y: lm.extraLineFragmentRect.minY,
                          width: 0, height: lm.extraLineFragmentRect.height)
        } else if index >= length {
            let g = lm.glyphIndexForCharacter(at: length - 1)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            let glyph = lm.boundingRect(forGlyphRange: NSRange(location: g, length: 1), in: tc)
            rect = NSRect(x: glyph.maxX, y: line.minY, width: 0, height: line.height)
        } else {
            let g = lm.glyphIndexForCharacter(at: index)
            let line = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
            rect = NSRect(x: line.minX + lm.location(forGlyphAt: g).x, y: line.minY, width: 0, height: line.height)
        }
        rect.origin.x += origin.x - 1
        rect.origin.y += origin.y
        rect.size.width = 2
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let dropIndex else { return }
        insertionPointColor.setFill()
        NSBezierPath(roundedRect: caretRect(at: dropIndex), xRadius: 1, yRadius: 1).fill()
    }

    /// Files from outside. A file moved within the text is the text view's own drag and stays a move.
    private func isFileDrop(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSTextView) !== self && sender.draggingPasteboard.canReadObject(
            forClasses: [NSFilePromiseReceiver.self, NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    /// File promises first: Photos also puts a URL on the pasteboard, but the promise gives the exported picture.
    @discardableResult func attachFiles(from pb: NSPasteboard, at index: Int) -> Bool {
        guard let files else { return false }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Mail Drops")
                .appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var at = index
            for p in promises {
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: .main) { [weak self] url, error in
                    guard error == nil, let self else { return }
                    let new = files([url])
                    self.insert(new, at: at)
                    at += new.count
                }
            }
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            insert(files(urls), at: index)
            return true
        }
        return false
    }
}
