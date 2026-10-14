import AppKit
import UniformTypeIdentifiers

/// The message composer: a real NSTextView, so the Cocoa text system supplies
/// emacs bindings (⌃A/E/K/Y/T, ⌥-word moves, ~/Library/KeyBindings), spelling,
/// substitutions, Writing Tools, dictation, Services and undo. Return sends;
/// Shift/Option-Return inserts a newline. Files, folders and images dropped or
/// pasted become attachment chips above the text. `/` at the start opens the
/// agent's commands; `@` opens the workspace's files (inserted as chips).
final class ChatComposerView: NSView, NSTextViewDelegate {
    var onSubmit: ((String, [ChatAttachment]) -> Void)?
    /// ⎋ in the composer; return true if handled (e.g. stopped a running turn).
    var onEscape: (() -> Bool)?
    /// Maps a file URL to one the sandbox can read (see ChatSessionView).
    var resolveFileURLs: (([URL]) -> [URL])?
    /// The agent's slash commands, for `/` completion.
    var commands: () -> [ChatSession.Command] = { [] }
    /// Workspace folder (host path) for `@` file completion.
    var fileRoot: String?

    private let completion = CompletionPanel()
    /// The `/…` or `@…` token being completed.
    private var completionRange: NSRange?
    private var completionGeneration = 0

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
        // Rich text only so `@file` chips (attachments) can live inline; pasted
        // text is still inserted plain (see ComposerTextView.paste).
        textView.isRichText = true
        textView.importsGraphics = false
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
        textView.placeholder = "Message Claude…   / for commands, @ for files"
        textView.onResign = { [weak self] in self?.completion.hide() }
        completion.onAccept = { [weak self] item in self?.accept(item) }

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

    /// Pre-fill the composer (Services / Shortcuts), caret at the end.
    func setDraft(_ text: String) {
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.needsDisplay = true
        resize()
    }

    func submitFromButton() { submit() }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if completion.isVisible {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): completion.move(1); return true
            case #selector(NSResponder.moveUp(_:)): completion.move(-1); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let item = completion.selected { accept(item) }
                return true
            case #selector(NSResponder.cancelOperation(_:)): completion.hide(); return true
            default: break
            }
        }
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

    func textDidChange(_ notification: Notification) {
        resize()
        updateCompletion()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if completion.isVisible { updateCompletion() }
    }

    // MARK: Completion

    /// Find the `/…` (at the very start) or `@…` token ending at the caret and
    /// show matching commands or files.
    private func updateCompletion() {
        let ns = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location <= ns.length else { return hideCompletion() }
        var start = caret.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 0xFFFC || CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(c) ?? " ") { break }
            start -= 1
        }
        let range = NSRange(location: start, length: caret.location - start)
        let token = ns.substring(with: range)
        completionGeneration += 1
        let generation = completionGeneration
        if token.hasPrefix("/"), start == 0 {
            let q = token.dropFirst().lowercased()
            let matches = commands()
                .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) || $0.name.lowercased().contains(q) }
                .sorted { ($0.name.lowercased().hasPrefix(q) ? 0 : 1, $0.name) < ($1.name.lowercased().hasPrefix(q) ? 0 : 1, $1.name) }
                .prefix(40)
                .map { cmd -> CompletionItem in
                    let detail = [cmd.hint ?? "", cmd.description].filter { !$0.isEmpty }.joined(separator: " — ")
                    return CompletionItem(kind: .command(name: cmd.name), title: "/" + cmd.name, detail: detail)
                }
            showCompletion(Array(matches), range: range)
        } else if token.hasPrefix("@"), let root = fileRoot {
            let q = String(token.dropFirst())
            Task { [weak self] in
                let files = await WorkspaceFileIndex.shared.files(under: root)
                let matches = WorkspaceFileIndex.match(files, query: q)
                guard let self, self.completionGeneration == generation else { return }
                self.showCompletion(matches.map { rel in
                    CompletionItem(kind: .file(URL(fileURLWithPath: root).appendingPathComponent(rel), relative: rel),
                                   title: (rel as NSString).lastPathComponent,
                                   detail: (rel as NSString).deletingLastPathComponent)
                }, range: range)
            }
        } else {
            hideCompletion()
        }
    }

    private func showCompletion(_ items: [CompletionItem], range: NSRange) {
        guard !items.isEmpty else { return hideCompletion() }
        completionRange = range
        let caret = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        completion.show(items, below: caret, parent: window)
    }

    private func hideCompletion() {
        completionRange = nil
        completion.hide()
    }

    private func accept(_ item: CompletionItem) {
        guard let range = completionRange else { return }
        switch item.kind {
        case .command(let name):
            textView.insertText("/\(name) ", replacementRange: range)
        case .file(let url, let relative):
            let chip = NSMutableAttributedString(attachment: MentionAttachment(url: url, relative: relative))
            chip.append(NSAttributedString(string: " ", attributes: textView.typingAttributes))
            textView.insertText(chip, replacementRange: range)
        }
        hideCompletion()
    }

    // MARK: Private

    private func submit() {
        hideCompletion()
        // `@file` chips become `@relative/path` in the text, plus the file itself.
        var text = ""
        var mentioned: [URL] = []
        if let storage = textView.textStorage {
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let mention = value as? MentionAttachment {
                    text += "@" + mention.relative
                    mentioned.append(mention.url)
                } else if value == nil {
                    text += (storage.string as NSString).substring(with: range)
                }
            }
        }
        let files = mentioned.map { url in
            ChatAttachment(kind: .file(resolveFileURLs?([url]).first ?? url))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else { return }
        onSubmit?(text, attachments + files)
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
            let name = NSButton(title: a.displayName, target: self, action: #selector(previewChip(_:)))
            name.tag = i
            name.bezelStyle = .inline
            name.controlSize = .small
            name.image = NSImage(systemSymbolName: { if case .image = a.kind { "photo" } else { "doc" } }(),
                                 accessibilityDescription: nil)
            name.imagePosition = .imageLeading
            name.toolTip = "Quick Look"
            let remove = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")!,
                                  target: self, action: #selector(removeChip(_:)))
            remove.tag = i
            remove.isBordered = false
            remove.contentTintColor = .secondaryLabelColor
            remove.toolTip = "Remove attachment"
            let chip = NSStackView(views: [name, remove])
            chip.spacing = 2
            chipRow.addArrangedSubview(chip)
        }
        chipRow.isHidden = attachments.isEmpty
    }

    @objc private func previewChip(_ sender: NSButton) {
        guard attachments.indices.contains(sender.tag) else { return }
        switch attachments[sender.tag].kind {
        case .file(let url): QuickLook.shared.show([url])
        case .image(let data, let mime, _):
            if let url = ImageAttachment(data: data, mimeType: mime).fileURL { QuickLook.shared.show([url]) }
        }
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
    var onResign: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func resignFirstResponder() -> Bool {
        onResign?()
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: inset.width + padding, y: inset.height),
                                       withAttributes: [.font: font ?? .systemFont(ofSize: 13.5),
                                                        .foregroundColor: NSColor.placeholderTextColor])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true   // placeholder appears/disappears
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func paste(_ sender: Any?) {
        if !takeAttachments(from: .general) { pasteAsPlainText(sender) }
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
