import AppKit
import Quartz
import UniformTypeIdentifiers

/// Quick Look for chat images and attachments. Images that only exist as data
/// are written to a temp folder first (Quick Look and Finder need files).
@MainActor
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var urls: [URL] = []

    func show(_ urls: [URL]) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }

    /// A stable temp file for image data (same bytes → same file).
    nonisolated static func file(for data: Data, ext: String = "png") -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Sandshell Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = String(format: "Image %08x.%@", UInt32(truncatingIfNeeded: data.hashValue), ext)
        let url = dir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            do { try data.write(to: url) } catch { return nil }
        }
        return url
    }
}

/// An image in the transcript, keeping its original bytes for Quick Look,
/// drag-out and saving.
final class ImageAttachment: NSTextAttachment {
    let data: Data
    let mimeType: String

    init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType ?? Self.sniff(data)
        super.init(data: nil, ofType: nil)
        image = NSImage(data: data)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// MIME type from the leading bytes (agents rarely say).
    static func sniff(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if b.count >= 12, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        return "image/png"
    }

    var fileExtension: String { UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "png" }
    var fileURL: URL? { QuickLook.file(for: data, ext: fileExtension) }
}

/// The transcript's text view: images can be clicked (Quick Look), dragged out
/// as files (Finder, Mail, any app), and have Copy / Save / Open in Preview on
/// their context menu. Everything else is a normal read-only NSTextView.
final class TranscriptTextView: NSTextView {
    /// The image attachment under `point` (view coordinates), if any.
    private func image(at point: NSPoint) -> ImageAttachment? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = characterIndexForInsertion(at: point)
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            if let a = storage.attribute(.attachment, at: i, effectiveRange: nil) as? ImageAttachment {
                // Only when the click is within the image's horizontal extent.
                let x = point.x - textContainerInset.width - (textContainer?.lineFragmentPadding ?? 0)
                if x <= a.bounds.width + 4 { return a }
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let attachment = image(at: point) else { return super.mouseDown(with: event) }
        // Click → Quick Look; drag → the image as a file.
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if let url = attachment.fileURL { QuickLook.shared.show([url]) }
                return
            }
            let now = convert(next.locationInWindow, from: nil)
            if hypot(now.x - point.x, now.y - point.y) > 4 {
                beginImageDrag(attachment, event: event, at: point)
                return
            }
        }
    }

    private func beginImageDrag(_ attachment: ImageAttachment, event: NSEvent, at point: NSPoint) {
        guard let url = attachment.fileURL else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = attachment.bounds.size
        let thumb = NSSize(width: min(size.width, 240), height: min(size.width, 240) * size.height / max(size.width, 1))
        item.setDraggingFrame(NSRect(origin: NSPoint(x: point.x - thumb.width / 2, y: point.y - thumb.height / 2), size: thumb),
                              contents: attachment.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : [.copy, .generic]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        guard let attachment = image(at: convert(event.locationInWindow, from: nil)) else { return base }
        let menu = NSMenu()
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(ClosureMenuItem.run), keyEquivalent: "")
            let box = ClosureMenuItem(handler)
            item.target = box
            item.representedObject = box   // keep the target alive
            menu.addItem(item)
        }
        add("Quick Look") { if let url = attachment.fileURL { QuickLook.shared.show([url]) } }
        add("Open in Preview") {
            if let url = attachment.fileURL {
                NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                        configuration: NSWorkspace.OpenConfiguration())
            }
        }
        menu.addItem(.separator())
        add("Copy Image") {
            let pb = NSPasteboard.general
            pb.clearContents()
            if let image = attachment.image { pb.writeObjects([image]) }
            if let url = attachment.fileURL { pb.writeObjects([url as NSURL]) }
        }
        add("Save Image…") { [weak self] in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Image.\(attachment.fileExtension)"
            if let type = UTType(mimeType: attachment.mimeType) { panel.allowedContentTypes = [type] }
            guard let window = self?.window else { return }
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { try? attachment.data.write(to: url) }
            }
        }
        return menu
    }
}

/// Target/action shim for closure-based menu items.
final class ClosureMenuItem: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func run() { handler() }
}
