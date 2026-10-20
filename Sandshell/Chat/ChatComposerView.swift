import AppKit
import UniformTypeIdentifiers

/// The message composer: a real NSTextView, so the Cocoa text system supplies
/// emacs bindings (⌃A/E/K/Y/T, ⌥-word moves, ~/Library/KeyBindings), spelling,
/// substitutions, Writing Tools, dictation, Services and undo. Return sends;
/// Shift/Option-Return inserts a newline. Files, folders and images dropped or
/// pasted become attachment chips above the text. `/` at the start opens the
/// agent's commands (the rest of the highlighted one shows greyed after the
/// caret; Tab takes it); `@` opens the workspace's files (inserted as chips).
/// ↑ in an empty composer brings back what you sent (↑/↓ walk it, ⎋ puts
/// back the draft); a next message the agent suggests is the placeholder,
/// which Tab takes.
final class ChatComposerView: NSView, NSTextViewDelegate {
    /// Send (or queue) a message; false keeps the draft (nothing took it).
    var onSubmit: ((String, [ChatAttachment]) -> Bool)?
    /// Asked before sending; false keeps the draft (e.g. while it asks the user).
    var shouldSubmit: (() -> Bool)?
    /// ⎋ in the composer; return true if handled (e.g. stopped a running turn).
    var onEscape: (() -> Bool)?
    /// Maps a file URL to one the sandbox can read (see ChatSessionView).
    var resolveFileURLs: (([URL]) -> [URL])?
    /// The agent's slash commands, for `/` completion.
    var commands: () -> [ChatSession.Command] = { [] }
    /// Workspace folder (host path) for `@` file completion.
    var fileRoot: String?
    /// What this chat sent, oldest first, for ↑.
    var sentHistory: () -> [String] = { [] }
    /// The walk through `sentHistory` under way (↑ starts it; sending ends it).
    private var history: ComposerHistory?
    /// A next message the agent suggests: the placeholder, which Tab takes.
    var suggestion: String? {
        get { textView.suggestion }
        set { textView.suggestion = newValue?.isEmpty == false ? newValue : nil }
    }

    private let completion = CompletionPanel()
    /// The `/…` or `@…` token being completed.
    private var completionRange: NSRange?
    private var completionGeneration = 0

    private let scrollView = NSScrollView()
    private let textView = ComposerTextView()
    private let chipRow = NSStackView()
    private var heightConstraint: NSLayoutConstraint!
    private(set) var attachments: [ChatAttachment] = [] { didSet { rebuildChips() } }

    /// Who the composer addresses ("Message Codex…").
    var agentName = "Claude" { didSet { textView.placeholder = Self.placeholder(agentName: agentName) } }
    private static func placeholder(agentName: String) -> String {
        "Message \(agentName)…   / for commands, @ for files"
    }

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
        textView.font = .role(.body)
        // One line sits centered in the 40 pt field (48 with the pill's own padding).
        textView.textContainerInset = NSSize(width: 0, height: 12)
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false   // prompts are often code
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onAttach = { [weak self] new in self?.attach(new) }
        textView.setAccessibilityIdentifier("chat-composer")
        textView.placeholder = Self.placeholder(agentName: "Claude")
        textView.onResign = { [weak self] in self?.completion.hide() }
        textView.usesFindBar = false
        completion.onAccept = { [weak self] item in self?.accept(item) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // A pill: white, a 1 pt border, fully rounded at its one-line height. No shadow.
        wantsLayer = true
        layer?.cornerRadius = Self.minHeight / 2
        layer?.borderWidth = 1

        sendButton.target = self
        sendButton.action = #selector(sendButtonClicked)

        addSubview(chipRow)
        addSubview(scrollView)
        addSubview(sendButton)
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: Self.minFieldHeight)
        // Text starts 20 pt in (the line fragment pads 5 of it); the round
        // button sits 14 pt from the right edge, centred on a one-line pill and
        // at the bottom as it grows.
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        scrollTopToPill = scrollView.topAnchor.constraint(equalTo: topAnchor, constant: Self.fieldInset)
        scrollTopToChips = scrollView.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: 2)
        let buttonInset = (Self.minHeight - ComposerSendButton.diameter) / 2
        NSLayoutConstraint.activate([
            chipRow.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            chipRow.trailingAnchor.constraint(lessThanOrEqualTo: sendButton.leadingAnchor, constant: -8),
            scrollTopToPill,
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20 - padding),
            scrollView.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -(10 - padding)),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.fieldInset),
            heightConstraint,
            sendButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(14 - 1)),
            sendButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonInset),
            sendButton.widthAnchor.constraint(equalToConstant: ComposerSendButton.diameter),
            sendButton.heightAnchor.constraint(equalToConstant: ComposerSendButton.diameter),
        ])
        rebuildChips()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pill's height with one line: 48 pt.
    static let minHeight: CGFloat = 48
    /// The field inside it: the pill less its padding above and below.
    private static let fieldInset: CGFloat = 4
    private static let minFieldHeight = minHeight - 2 * fieldInset
    private var scrollTopToPill: NSLayoutConstraint!
    private var scrollTopToChips: NSLayoutConstraint!

    /// Send while idle, Stop while a turn runs (the chat sets its mode).
    let sendButton = ComposerSendButton()
    /// The round button was clicked (Send, Stop or Reconnect: the chat decides).
    var onSendButton: (() -> Void)?
    @objc private func sendButtonClicked() { onSendButton?() }

    // Layer colors don't follow light/dark on their own; resolve them here.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.composerFill.cgColor
            layer?.borderColor = NSColor.composerBorder.cgColor
        }
    }

    /// A click in the pill's padding puts the caret in the field.
    override func mouseDown(with event: NSEvent) { focus() }

    func focus() { window?.makeFirstResponder(textView) }

    /// The `+` control's "Mention a File": an `@` at the caret, which opens
    /// the workspace's files (a space first if it would join a word).
    func startMention() {
        guard textView.isEditable else { return }
        focus()
        let caret = textView.selectedRange()
        let ns = textView.string as NSString
        let joins = caret.location > 0 && caret.location <= ns.length
            && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(ns.character(at: caret.location - 1)) ?? " ")
        textView.insertText(joins ? " @" : "@", replacementRange: caret)
    }

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

    func setEnabled(_ enabled: Bool) {
        textView.isEditable = enabled
        // The field dims; the round button keeps its own state (Reconnect).
        for v in [scrollView, chipRow] as [NSView] { v.alphaValue = enabled ? 1 : 0.55 }
    }
    var isEnabled: Bool { textView.isEditable }

    /// Where ⌘F/⌘G go while the composer has focus.
    var onFind: ((Any?) -> Void)? {
        get { textView.onFind }
        set { textView.onFind = newValue }
    }

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
            case #selector(NSResponder.moveDown(_:)): completion.move(1); updateGhost(); return true
            case #selector(NSResponder.moveUp(_:)): completion.move(-1); updateGhost(); return true
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                if let item = completion.selected { accept(item) }
                return true
            case #selector(NSResponder.cancelOperation(_:)): hideCompletion(); updateGhost(); return true
            default: break
            }
        }
        switch selector {
        case #selector(NSResponder.insertTab(_:)):
            return acceptGhostOrSuggestion()
        case #selector(NSResponder.moveUp(_:)):
            return recallOlder()
        case #selector(NSResponder.moveDown(_:)):
            return recallNewer()
        case #selector(NSResponder.cancelOperation(_:)):
            // Walking the history: back to the draft. Otherwise the chat's ⎋.
            if shownHistoryEntry != nil, var walk = history {
                show(walk.cancel() ?? "")
                history = walk
                return true
            }
            return onEscape?() ?? false
        default: break
        }
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
        updateGhost()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if completion.isVisible { updateCompletion() }
        updateGhost()
    }

    // MARK: Sent history (↑/↓)

    /// The recalled message the composer shows, as it was (nil once edited).
    private var shownHistoryEntry: String? {
        guard let history, history.isShowingEntry(textView.string) else { return nil }
        return textView.string
    }

    /// ↑: in an empty composer, the last message sent; on a recalled one
    /// (unchanged, caret on its first line), the one before. Otherwise the
    /// caret moves as usual.
    private func recallOlder() -> Bool {
        let text = textView.string
        var walk: ComposerHistory
        if text.isEmpty, attachments.isEmpty {
            walk = ComposerHistory(sent: sentHistory())
        } else if shownHistoryEntry != nil, let current = history,
                  ComposerHistory.caretOnFirstLine(of: text, caret: textView.selectedRange()) {
            walk = current
        } else {
            return false
        }
        // Nothing (further) back: the key does nothing.
        guard let older = walk.older(current: text) else { return true }
        history = walk
        show(older)
        return true
    }

    /// ↓ on a recalled message (unchanged, caret on its last line): the next
    /// one sent, or past the newest the draft from before.
    private func recallNewer() -> Bool {
        guard shownHistoryEntry != nil, var walk = history,
              ComposerHistory.caretOnLastLine(of: textView.string, caret: textView.selectedRange()),
              let newer = walk.newer() else { return false }
        history = walk
        show(newer)
        return true
    }

    /// Put `text` in the field for the history walk, caret at the end.
    private func show(_ text: String) {
        hideCompletion()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.needsDisplay = true
        resize()
        updateGhost()
    }

    // MARK: Ghost text and suggestions (Tab)

    /// The rest of the `/command` being typed, greyed after the caret: the
    /// completion list's highlighted one while it's open (Tab takes that
    /// either way), else the one it would list first.
    private func updateGhost() {
        let ns = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location == ns.length, ns.hasPrefix("/") else {
            textView.ghost = nil
            return
        }
        var selected: String?
        if completion.isVisible, case .command(let name)? = completion.selected?.kind { selected = name }
        textView.ghost = CommandGhost.suffix(for: textView.string, commands: commands().map(\.name), selected: selected)
    }

    /// Tab with the completion list closed: the ghost command, or the agent's
    /// suggestion in an empty composer. Otherwise a tab as usual.
    private func acceptGhostOrSuggestion() -> Bool {
        let length = (textView.string as NSString).length
        if let ghost = textView.ghost {
            // As picking it from the list does: the command and a space.
            textView.insertText("\(textView.string)\(ghost) ", replacementRange: NSRange(location: 0, length: length))
            hideCompletion()
            textView.ghost = nil
            return true
        }
        if length == 0, attachments.isEmpty, let suggestion {
            textView.insertText(suggestion, replacementRange: NSRange(location: 0, length: 0))
            return true
        }
        return false
    }

    // MARK: Queued messages

    /// A queued message's Edit: back into the composer (ahead of anything
    /// already typed), caret at the end. Sending it queues it again.
    func edit(_ queued: QueuedPrompt) {
        setDraft([queued.text, textView.string].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        attachments += queued.attachments
        history = nil
        focus()
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
                    CompletionItem(kind: .file(URL(filePath: root).appending(path: rel), relative: rel),
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty,
              shouldSubmit?() ?? true else { return }
        guard onSubmit?(text, attachments + files) == true else { return }
        textView.string = ""
        attachments = []
        history = nil
        textView.ghost = nil
        resize()
    }

    #if DEBUG
    /// Self-test: type `text` (replacing what's there) and the field's height.
    func debugType(_ text: String) { textView.string = text; resize() }
    var debugFieldHeight: CGFloat { heightConstraint.constant }
    var debugDraftIsEmpty: Bool { textView.string.isEmpty && attachments.isEmpty }
    var debugText: String { textView.string }
    var debugGhost: String? { textView.ghost }
    var debugPlaceholder: String { textView.shownPlaceholder }
    /// Self-test: type as the keyboard does (completion and ghost follow).
    func debugTypeKeys(_ text: String) {
        focus()
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
    /// Self-test: a key's command as the text system sends it (↑ moveUp:,
    /// ↓ moveDown:, ⇥ insertTab:, ⎋ cancelOperation:).
    func debugCommand(_ selector: Selector) {
        focus()
        textView.doCommand(by: selector)
    }
    #endif

    /// How tall the field may grow before it scrolls (the chat sets it to about
    /// half its height).
    var maximumHeight: CGFloat = 200 {
        didSet { if oldValue != maximumHeight { resize() } }
    }

    /// Grow with the text, from one line up to `maximumHeight`, then scroll.
    private func resize() {
        let used: CGFloat
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            used = tlm.usageBoundsForTextContainer.height
        } else if let layout = textView.layoutManager, let container = textView.textContainer {
            // TextKit 1: AppKit moves the field onto it (for the inline file
            // chips); measuring only through TextKit 2 left it one line tall.
            layout.ensureLayout(for: container)
            used = layout.usedRect(for: container).height
        } else {
            return
        }
        let floor = Self.minFieldHeight
        let h = min(max(used + textView.textContainerInset.height * 2, floor), max(maximumHeight, floor))
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
            let remove = NSButton.symbol("xmark.circle.fill", label: "Remove \(a.displayName)",
                                         pointSize: TypeRole.meta.symbolPointSize, weight: .regular,
                                         target: self, action: #selector(removeChip(_:)))

            remove.tag = i
            // Unlike the toolbar's, it can be tabbed to, like the chip's name.
            remove.refusesFirstResponder = false
            remove.focusRingType = .default
            let chip = NSStackView(views: [name, remove])
            chip.spacing = 2
            chipRow.addArrangedSubview(chip)
        }
        chipRow.isHidden = attachments.isEmpty
        // No chips: the field takes the pill's top too.
        let (on, off) = attachments.isEmpty ? (scrollTopToPill, scrollTopToChips) : (scrollTopToChips, scrollTopToPill)
        off?.isActive = false
        on?.isActive = true
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
    /// Find actions, which should search the transcript rather than the draft.
    var onFind: ((Any?) -> Void)?
    var placeholder = "" { didSet { placeholderChanged() } }
    /// The agent's suggested next message: shown in place of the placeholder.
    var suggestion: String? { didSet { if suggestion != oldValue { placeholderChanged() } } }
    /// Greyed text after the caret that Tab would add (a command's rest).
    var ghost: String? { didSet { if ghost != oldValue { needsDisplay = true } } }

    /// What an empty field shows.
    var shownPlaceholder: String { suggestion ?? placeholder }

    private func placeholderChanged() {
        setAccessibilityPlaceholderValue(shownPlaceholder)
        needsDisplay = true
    }

    override func performTextFinderAction(_ sender: Any?) {
        // "Use Selection for Find" keeps working on the draft's selection.
        if (sender as? NSMenuItem)?.tag == NSTextFinder.Action.setSearchString.rawValue || onFind == nil {
            return super.performTextFinderAction(sender)
        }
        onFind?(sender)
    }

    override func resignFirstResponder() -> Bool {
        onResign?()
        return super.resignFirstResponder()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let font = font ?? .role(.body)
        let grey: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.placeholderTextColor]
        if string.isEmpty, !shownPlaceholder.isEmpty {
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            // A suggestion can be long: one line, cut short at its end.
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let line = NSRect(x: inset.width + padding, y: inset.height,
                              width: max(bounds.width - 2 * (inset.width + padding), 0),
                              height: ceil(font.ascender - font.descender + font.leading))
            (shownPlaceholder as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                                attributes: grey.merging([.paragraphStyle: style]) { $1 })
        }
        // The ghost: right after the last character (it only shows with the caret there).
        if let ghost, !ghost.isEmpty, let window {
            let end = firstRect(forCharacterRange: NSRange(location: (string as NSString).length, length: 0), actualRange: nil)
            guard end != .zero else { return }
            let caret = convert(window.convertFromScreen(end), from: nil)
            (ghost as NSString).draw(at: NSPoint(x: caret.minX, y: caret.minY), withAttributes: grey)
        }
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
