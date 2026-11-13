import AppKit
import SwiftUI

/// The focused session's sandbox, in the sidebar's header beside the folder's
/// name (there's no toolbar): a cube tinted by its state — running, being
/// built, failed, or grey when stopped or not made yet. Click: its menu
/// (Inspect, Folder Access, Start/Stop, Restart, Rebuild…).
@MainActor
final class SandboxStatusButton: NSControl {
    static let size = NSSize(width: 24, height: 24)

    /// The sandbox's menu, shown under the button.
    var sandboxMenu: (() -> NSMenu?)?
    private let icon = NSImageView()
    private var stateColor: NSColor?
    private var restingTint = NSColor.secondaryLabelColor
    private var hoverFill = NSColor.clear
    private var hovering = false { didSet { layer?.backgroundColor = hovering ? hoverFill.cgColor : nil } }
    private(set) var sandboxName: String?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 6
        icon.image = NSImage(systemSymbolName: "cube.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.role(.meta))
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.menuButton)
        setAccessibilityLabel("Sandbox")
        setAccessibilityIdentifier("sidebar-sandbox")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Tinted from the sidebar's palette (its own state colour wins).
    func apply(tint: NSColor, hover: NSColor) {
        restingTint = tint
        hoverFill = hover
        icon.contentTintColor = stateColor ?? tint
    }

    /// The focused session's sandbox: its name, state colour (nil: stopped
    /// or not made) and what to say about it. No sandbox: hidden.
    func setSandbox(name: String?, stateColor: NSColor?, tip: String?) {
        sandboxName = name
        isHidden = name == nil
        self.stateColor = stateColor
        icon.contentTintColor = stateColor ?? restingTint
        toolTip = tip
        setAccessibilityValue(tip)
    }

    /// What the sandbox can do with the folder, under the button.
    func showAccess(_ access: SandboxAccess) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.show(.hosting(SandboxAccessPopover(access: access)), relativeTo: bounds, of: self, preferredEdge: .minY)
        return popover
    }

    override func mouseDown(with event: NSEvent) {
        guard let menu = sandboxMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let menu = sandboxMenu?() else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY + 4), in: self)
        return true
    }

    override var isFlipped: Bool { true }

    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    #if DEBUG
    var debugScreenRect: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    #endif
}
