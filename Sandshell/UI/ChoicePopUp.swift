import AppKit

/// A borderless pull-down chooser — the title strip's model / effort and the
/// chat footer's mode / model: item 0 is the visible title, the rest are the
/// choices, the current one checked. One look and one way to fill it.
final class ChoicePopUp: NSPopUpButton {
    struct Choice { var id: String?; var title: String }
    static let titleFont = NSFont.role(.meta)

    /// The user picked a choice (its id).
    var onPick: ((String?) -> Void)?
    private(set) var choices: [Choice] = []

    init(tip: String) {
        super.init(frame: .zero, pullsDown: true)
        Self.style(self)
        toolTip = tip
        setAccessibilityLabel(tip)   // VoiceOver: "Model, Opus, pop-up button"
        target = self
        action = #selector(picked)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The shared look, for pull-downs built elsewhere.
    static func style(_ button: NSPopUpButton) {
        button.isBordered = false
        button.controlSize = .small
        button.font = titleFont
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    /// Item 0 (the title) plus `choices`.
    static func fill(_ button: NSPopUpButton, with choices: [Choice]) {
        button.removeAllItems()
        button.addItem(withTitle: "")
        for choice in choices {
            button.addItem(withTitle: choice.title)
            button.lastItem?.representedObject = choice.id
        }
    }

    /// The visible title, and the checkmark on the choice whose id is
    /// `current` (compared through `normalize`), submenus included.
    static func show(_ button: NSPopUpButton, title: String, current: String?, color: NSColor = .labelColor,
                     skipTag: Int? = nil, normalize: (String) -> String = { $0 }) {
        button.item(at: 0)?.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: color, .font: titleFont])
        let current = current.map(normalize)
        func mark(_ items: [NSMenuItem]) {
            for item in items {
                if let sub = item.submenu { mark(sub.items); continue }
                if item.isSeparatorItem || (skipTag != nil && item.tag == skipTag) { continue }
                item.state = (item.representedObject as? String).map(normalize) == current ? .on : .off
            }
        }
        mark(Array(button.itemArray.dropFirst()))
    }

    /// Fill with `choices` and show `current` (its title, checked); hidden
    /// when there's nothing to choose.
    func set(_ choices: [Choice], current: String?, color: NSColor = .labelColor) {
        self.choices = choices
        Self.fill(self, with: choices)
        let title = choices.first { $0.id == current }?.title ?? choices.first?.title ?? ""
        Self.show(self, title: title, current: current, color: color)
        isHidden = choices.isEmpty
    }

    @objc private func picked() {
        guard indexOfSelectedItem > 0, let item = selectedItem else { return }
        onPick?(item.representedObject as? String)
    }
}
