# Debug Construction Tape for macOS apps

A DEBUG-only visual marker for AppKit (and SwiftUI-on-AppKit) apps. It draws a
thin band of diagonal yellow/black hazard stripes across the very top of each
window's titlebar, behind the toolbar and the traffic lights, so a locally
built debug instance is unmistakable when it runs beside the installed release
build. An optional second helper washes the Dock icon red for the same reason.

Everything compiles out in Release. The call sites need no `#if DEBUG` guards.

## Files

- `DebugConstructionTape.swift`: the whole feature. One enum with three static
  functions plus the `ConstructionTapeView` that does the drawing.

## Instructions for an AI coding agent

You are adding this to an existing macOS app. Follow these steps exactly and
do not restyle or "improve" the drawing code; the colors, alpha and stripe
geometry were tuned by eye against real toolbars.

1. **Copy the file.** Put `DebugConstructionTape.swift` anywhere in the app
   target's sources. If the project is generated (XcodeGen, Tuist, SwiftPM),
   drop it into a directory that target already globs. Do not put it in a test
   target or a framework that ships to users.

2. **Confirm the `DEBUG` flag exists.** Xcode's default Debug configuration
   sets `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`. Check
   `project.yml`, `Project.swift` or the `.xcodeproj` build settings. If the
   project renamed or removed it, either add `DEBUG` back or change every
   `#if DEBUG` in the file to the project's own condition.

3. **Pick one install style.**

   - **The app builds its own `NSWindow` or `NSWindowController`.**
     Call `DebugConstructionTape.install(on: window)` once, after the toolbar
     is attached (`window.toolbar = …`) and before the window is shown. In an
     `NSWindowController` subclass the end of `windowDidLoad()` is right. The
     band sits behind toolbar items, so it must be added after the toolbar
     exists or it will land under an empty titlebar and later be covered.

   - **SwiftUI `App` / `WindowGroup`, or windows the app does not own.**
     Call `DebugConstructionTape.installOnAllWindows()` once at launch, in
     `applicationDidFinishLaunching(_:)` or the SwiftUI `App.init()`. It tapes
     current windows and observes `NSWindow` notifications so every later
     titled window is taped too. Panels and borderless windows are skipped.

4. **Optional Dock icon wash.** Call `DebugConstructionTape.washDockIconRed()`
   in `applicationDidFinishLaunching(_:)`. It overlays translucent red only on
   the icon's opaque pixels, so the rounded corners stay clear. Do this if the
   user wants the debug build to be distinguishable in the Dock and ⌘-Tab, not
   just in its windows.

5. **Tune, if asked.** `DebugConstructionTape.bandHeight` (default 5pt) is
   the only knob most apps need. 5pt is a hairline of tape; 12 to 16pt is a
   banner. Set it before the first `install` call. Stripe colors and widths are
   public properties on `ConstructionTapeView` for the rare case someone wants
   a different look.

6. **Verify.** Build Debug and Release. In Debug, every main window shows the
   stripe at the top edge of the titlebar and the traffic lights still work
   (the view is click-through). In Release, `nm` or a quick search of the
   binary for `ConstructionTapeView` shows only the type name if the class is
   still referenced, and no stripe appears. If the stripe is hidden behind an
   opaque titlebar, set `window.titlebarAppearsTransparent = true` or raise
   `bandHeight` so it peeks above the toolbar background.

## How it works

`NSWindow.standardWindowButton(.closeButton)?.superview` is the private
titlebar container view that AppKit uses for the traffic lights and toolbar.
Inserting a subview at the back of it (`positioned: .below, relativeTo: nil`)
puts the stripe under every toolbar item. Auto Layout pins it to the titlebar's
top, leading and trailing anchors with a fixed height, so it tracks resizes and
toolbar height changes. `hitTest` returns nil so clicks and window drags pass
through. The view draws 45° parallelograms with `NSBezierPath`, starting one
band-height off-screen to the left so the slanted edges never leave a bare
corner.

This relies on the titlebar view being the close button's superview, which has
held from macOS 10.10 through macOS 26. If Apple changes it, `install(on:)`
silently does nothing rather than crashing.

## Origin

Extracted from Sandshell (`xmas-sandshell`), where it lives as
`Sandshell/UI/ConstructionTapeView.swift` and the `installDebugTapeIfNeeded()`
and `applyDevIconWashIfDebug()` helpers.
