//
//  DebugConstructionTape.swift
//
//  Drop-in DEBUG-build marker for macOS (AppKit) apps: a thin band of diagonal
//  yellow/black hazard stripes ("construction tape") drawn across the very top
//  of a window's titlebar, behind the toolbar items and traffic lights, so a
//  locally built debug instance is unmistakable next to an installed release
//  build. Optionally also washes the Dock icon red.
//
//  Everything in this file compiles to nothing in Release: the public entry
//  points are `#if DEBUG` no-ops, so call sites need no guards of their own.
//
//  Requirements: macOS 11+, AppKit. No assets, no dependencies.
//  Extracted from Sandshell (xmas-sandshell). Use freely.
//

import AppKit

// MARK: - Public API

public enum DebugConstructionTape {

    /// Height of the stripe band in points. 5pt reads as a hairline of tape;
    /// 12–16pt reads as a banner. Set before installing.
    public static var bandHeight: CGFloat = 5

    /// Install the tape on one window. Idempotent, safe on any window, and
    /// inserts nothing in Release builds.
    ///
    /// Call after the window's toolbar is attached and before it is shown, e.g.
    /// at the end of `NSWindowController.windowDidLoad()` or right after
    /// `window.toolbar = …`. Works with or without a toolbar; looks best with
    /// `window.titlebarAppearsTransparent = true`.
    public static func install(on window: NSWindow) {
        #if DEBUG
        // The titlebar view is the superview of the standard window buttons. A
        // subview inserted at the back of it shows through behind the toolbar
        // items and, when the titlebar is transparent, behind the toolbar chrome.
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        if titlebar.subviews.contains(where: { $0 is ConstructionTapeView }) { return }

        let stripe = ConstructionTapeView(frame: .zero)
        stripe.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(stripe, positioned: .below, relativeTo: nil)
        // Auto Layout so "top" is unambiguous regardless of the titlebar view's
        // coordinate flip; full width; fixed band height.
        NSLayoutConstraint.activate([
            stripe.topAnchor.constraint(equalTo: titlebar.topAnchor),
            stripe.leadingAnchor.constraint(equalTo: titlebar.leadingAnchor),
            stripe.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor),
            stripe.heightAnchor.constraint(equalToConstant: bandHeight),
        ])
        #endif
    }

    /// Install the tape on every titled window the app ever shows, including
    /// windows you do not create yourself (SwiftUI `WindowGroup`, document
    /// windows, etc.). Call once at launch, e.g. in
    /// `applicationDidFinishLaunching(_:)` or a SwiftUI `App.init()`.
    ///
    /// Tapes existing windows immediately and observes window notifications for
    /// windows created later. Panels and borderless windows are skipped.
    public static func installOnAllWindows() {
        #if DEBUG
        NSApp?.windows.forEach(tapeIfEligible)
        let center = NotificationCenter.default
        let handler: (Notification) -> Void = { note in
            guard let window = note.object as? NSWindow else { return }
            tapeIfEligible(window)
        }
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: nil, queue: .main, using: handler))
        observers.append(center.addObserver(forName: NSWindow.didUpdateNotification,
                                            object: nil, queue: .main, using: handler))
        #endif
    }

    /// Wash the app/Dock icon red: a translucent overlay over the icon's opaque
    /// pixels only, so transparent corners stay clear. Pairs with the tape so a
    /// dev build is obvious in the Dock and ⌘-Tab, not just in its windows.
    /// No-op in Release.
    public static func washDockIconRed(alpha: CGFloat = 0.45) {
        #if DEBUG
        let base = NSImage(named: NSImage.applicationIconName) ?? NSApp.applicationIconImage
        guard let base else { return }
        let size = NSSize(width: 512, height: 512)
        let rect = NSRect(origin: .zero, size: size)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        base.draw(in: rect, from: NSRect(origin: .zero, size: base.size),
                  operation: .copy, fraction: 1.0)
        // .sourceAtop paints only where the destination is already opaque.
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSColor.systemRed.withAlphaComponent(alpha).set()
        NSBezierPath(rect: rect).fill()
        tinted.unlockFocus()
        NSApp.applicationIconImage = tinted
        #endif
    }

    // MARK: Private

    #if DEBUG
    private static var observers: [NSObjectProtocol] = []

    private static func tapeIfEligible(_ window: NSWindow) {
        guard window.styleMask.contains(.titled),
              !(window is NSPanel),
              window.standardWindowButton(.closeButton) != nil else { return }
        install(on: window)
    }
    #endif
}

// MARK: - The view

/// Diagonal yellow/black hazard stripes. Draws itself; no assets. Click-through,
/// so it never intercepts titlebar clicks or window drags.
public final class ConstructionTapeView: NSView {

    /// Amber "safety yellow" and a warm near-black, both semi-transparent so the
    /// band reads as hazard striping without fighting the toolbar behind it.
    public var tapeYellow = NSColor(srgbRed: 0.97, green: 0.74, blue: 0.06, alpha: 0.55)
    public var tapeBlack  = NSColor(srgbRed: 0.11, green: 0.10, blue: 0.07, alpha: 0.55)

    /// Width of each black diagonal and of the yellow gap between them, in points.
    public var stripeWidth: CGFloat = 13
    public var gapWidth: CGFloat = 13

    public override var isOpaque: Bool { false }

    /// Click-through: the watermark sits behind the toolbar and must never eat
    /// clicks or window-drag from the titlebar.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        tapeYellow.setFill()
        bounds.fill()

        tapeBlack.setFill()
        let period = stripeWidth + gapWidth
        let h = bounds.height
        // 45° parallelograms marching left→right. Start off-screen left by `h`
        // so the slanted edges cover the whole band with no bald corners.
        var x = -h - period
        while x < bounds.width + h {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0))
            p.line(to: NSPoint(x: x + stripeWidth, y: 0))
            p.line(to: NSPoint(x: x + stripeWidth + h, y: h))
            p.line(to: NSPoint(x: x + h, y: h))
            p.close()
            p.fill()
            x += period
        }
    }
}
