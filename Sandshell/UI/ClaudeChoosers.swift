import AppKit
import Combine

/// The Claude model and effort pull-downs: the model from the live catalog
/// (Default, current models, an "Older" submenu, then "Other model id…" for
/// anything the list lacks), the effort from Claude Code's levels. The
/// composer shows them; one look and one way to pick.
@MainActor
final class ClaudeChoosers: NSObject {
    /// Fired with the chosen model id (`nil` = Claude's default).
    var onModelPicked: ((String?) -> Void)?
    /// Fired with the chosen effort level (`nil` = Claude's default).
    var onEffortPicked: ((String?) -> Void)?
    /// The id "Other model id…" starts from.
    var currentModelID: () -> String? = { nil }

    let modelButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let effortButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let font: NSFont
    private var cancellables: Set<AnyCancellable> = []
    /// The model `showModel` last drew, to redraw it when the catalog changes.
    private var shownModel: (title: String, id: String?, color: NSColor)?

    init(font: NSFont = ChoicePopUp.titleFont) {
        self.font = font
        super.init()
        for b in [modelButton, effortButton] {
            ChoicePopUp.style(b, font: font)
            b.target = self
        }
        modelButton.action = #selector(modelChanged(_:))
        modelButton.toolTip = "Claude model. A chat relaunches on it, keeping the conversation; new sessions use it too."
        modelButton.setAccessibilityLabel("Model")
        effortButton.action = #selector(effortChanged(_:))
        effortButton.toolTip = "Claude effort level. New sessions use it too."
        effortButton.setAccessibilityLabel("Effort")
        fillModels()
        ChoicePopUp.fill(effortButton, with: ClaudeEffortChoice.catalog.map { ChoicePopUp.Choice(id: $0.id, title: $0.title) })
        ClaudeModelCatalog.shared.$menu.dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.catalogChanged() } }
            .store(in: &cancellables)
    }

    private static let otherModelTag = 1

    private func fillModels() {
        let menu = ClaudeModelCatalog.shared.menu
        ChoicePopUp.fill(modelButton, with: ([ClaudeModelChoice.systemDefault] + menu.current)
            .map { ChoicePopUp.Choice(id: $0.id, title: $0.title) })
        if !menu.older.isEmpty {
            // Submenu picks don't go through the pop-up's own action.
            modelButton.menu?.addItem(NSMenuItem("Older", submenu: menu.older.map { choice in
                let item = NSMenuItem(choice.title, action: #selector(olderModelChosen(_:)), target: self, object: choice.id)
                item.toolTip = choice.id
                return item
            }))
        }
        modelButton.menu?.addItem(.separator())
        modelButton.addItem(withTitle: "Other model id…")
        modelButton.lastItem?.tag = Self.otherModelTag
        for item in modelButton.itemArray.dropFirst() where item.toolTip == nil {
            item.toolTip = item.representedObject as? String
        }
    }

    private func catalogChanged() {
        fillModels()
        if let m = shownModel { showModel(title: m.title, id: m.id, color: m.color) }
    }

    /// The model's visible title and its checkmark. Live ids can carry Claude
    /// Code's "[1m]" suffix; menu ids don't.
    func showModel(title: String, id: String?, color: NSColor) {
        ChoicePopUp.show(modelButton, title: title, current: id, color: color, font: font,
                         skipTag: Self.otherModelTag, normalize: ClaudePriceBook.normalize)
        shownModel = (title, id, color)
    }

    func showEffort(title: String, id: String?, color: NSColor) {
        ChoicePopUp.show(effortButton, title: title, current: id, color: color, font: font)
    }

    @objc private func modelChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, sender.indexOfSelectedItem > 0 else { return }
        if item.tag == Self.otherModelTag { promptForModelID(); return }
        onModelPicked?(item.representedObject as? String)
    }

    @objc private func olderModelChosen(_ sender: NSMenuItem) {
        onModelPicked?(sender.representedObject as? String)
    }

    @objc private func effortChanged(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, sender.indexOfSelectedItem > 0 else { return }
        onEffortPicked?(item.representedObject as? String)
    }

    /// Free-form id for a model the catalog doesn't list yet (or a gateway
    /// alias); remembered so it stays in the chooser.
    private func promptForModelID() {
        let alert = NSAlert()
        alert.messageText = "Use another Claude model"
        alert.informativeText = "Enter a model id as `claude --model` accepts it, e.g. claude-sonnet-5-5. "
            + "The sandbox's Claude Code must be new enough to know the model."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "claude-…"
        field.stringValue = currentModelID().map(ClaudePriceBook.normalize) ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Use Model")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        guard !id.contains(where: \.isWhitespace) else {
            Alerts.inform("Invalid Model ID", "A model id can’t contain spaces.", style: .warning,
                          in: modelButton.window)
            return
        }
        ClaudeModelCatalog.shared.addCustom(id)
        onModelPicked?(id)
    }
}
