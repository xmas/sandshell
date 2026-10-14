import AppKit
import UniformTypeIdentifiers

/// The message composer: a real NSTextView, so the Cocoa text system supplies
/// emacs bindings (⌃A/E/K/Y/T, ⌥-word moves, ~/Library/KeyBindings), spelling,
/// substitutions, Writing Tools, dictation, Services and undo. Return sends;
/// Shift/Option-Return inserts a newline. Files, folders and images dropped or
/// pasted become attachment chips above the text.
final class ChatComposerView: NSView, NSTextViewDelegate {
    var onSubmit: ((String, [ChatAttachment]) -> Void)?
    /// ⎋ in the composer; return true if handled (e.g. stopped a running turn).
    var onEscape: (() -> Bool)?
    /// Maps a file URL to one the sandbox can read (see ChatSessionView).
    var resolveFileURLs: (([URL]) -> [URL])?

    private let scrollView = NSScrollView()
    private let textView = ComposerTextView()
    private let chipRow = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private(set) var attachments: [ChatAttachment] = [] { didSet { rebuildChips() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        chipRow.orientation = .horizontal
        chipRow.spacing = 6
        chipRow.translatesAutoresizingMaskIntoConstraints = false

        textView.delegate = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13.5)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false   // prompts are often code
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onAttach = { [weak self] new in self?.attach(new) }
        textView.setAccessibilityIdentifier("chat-composer")

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        addSubview(chipRow)
        addSubview(scrollView)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            chipRow.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chipRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 2),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightConstraint,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(textView) }

    func addAttachments(urls: [URL]) { attach(urls.map(ComposerTextView.attachment(for:))) }

    /// Files/images from a pasteboard (pane-level drops); false if none.
    func addAttachments(from pb: NSPasteboard) -> Bool { textView.takeAttachments(from: pb) }

    /// File attachments are re-pointed at sandbox-readable paths; images are inline data.
    private func attach(_ new: [ChatAttachment]) {
        attachments += new.map { a in
            guard case .file(let url) = a.kind, let resolved = resolveFileURLs?([url]).first else { return a }
            return ChatAttachment(kind: .file(resolved))
        }
    }

    func setEnabled(_ enabled: Bool) { textView.isEditable = enabled }

    func submitFromButton() { submit() }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { return onEscape?() ?? false }
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let mods = NSApp.currentEvent?.modifierFlags ?? []
        if mods.contains(.shift) || mods.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        submit()
        return true
    }

    func textDidChange(_ notification: Notification) { resize() }

    // MARK: Private

    private func submit() {
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        onSubmit?(text, attachments)
        textView.string = ""
        attachments = []
        resize()
    }

    /// Grow with the text, 1–10 lines, then scroll.
    private func resize() {
        guard let tlm = textView.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let used = tlm.usageBoundsForTextContainer.height
        let h = min(max(used + textView.textContainerInset.height * 2, 40), 200)
        if abs(heightConstraint.constant - h) > 0.5 { heightConstraint.constant = h }
    }

    private func rebuildChips() {
        chipRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in attachments.enumerated() {
            let chip = NSButton(title: "\(a.displayName)  ✕", target: self, action: #selector(removeChip(_:)))
            chip.tag = i
            chip.bezelStyle = .inline
            chip.controlSize = .small
            chip.toolTip = "Remove attachment"
            chipRow.addArrangedSubview(chip)
        }
        chipRow.isHidden = attachments.isEmpty
    }

    @objc private func removeChip(_ sender: NSButton) {
        guard attachments.indices.contains(sender.tag) else { return }
        attachments.remove(at: sender.tag)
    }
}

/// NSTextView that turns dropped/pasted files and images into attachments
/// instead of inserting them as text.
final class ComposerTextView: NSTextView {
    var onAttach: (([ChatAttachment]) -> Void)?

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if !takeAttachments(from: .general) { super.paste(sender) }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        takeAttachments(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    /// Files (incl. images on disk) → file attachments; raw image data → inline image.
    fileprivate func takeAttachments(from pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            onAttach?(urls.map(Self.attachment(for:)))
            return true
        }
        if pb.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pb), let png = image.pngData() {
            onAttach?([ChatAttachment(kind: .image(data: png, mimeType: "image/png", name: "Pasted image.png"))])
            return true
        }
        return false
    }

    /// Small images go inline (the agent sees them directly); everything else is
    /// a path reference — mounted host paths exist at the same path in the sandbox.
    static func attachment(for url: URL) -> ChatAttachment {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let mime = type.preferredMIMEType,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 5_000_000,
           let data = try? Data(contentsOf: url) {
            return ChatAttachment(kind: .image(data: data, mimeType: mime, name: url.lastPathComponent))
        }
        return ChatAttachment(kind: .file(url))
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
