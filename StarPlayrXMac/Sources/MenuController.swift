//
//  MenuController.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import Combine

/// Owns the menu bar item and the one panel used both under the menu bar and torn off.
@MainActor
final class MenuController: NSObject, ObservableObject {
    static let shared = MenuController()

    @Published private(set) var detached = false
    @Published var shaded = false
    private(set) lazy var panel = MenuPanel.make()
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var outsideClick: Any?
    private var glide: Timer?
    private var playing: AnyCancellable?

    func install() {
        _ = panel
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        playing = Radio.shared.$isPlaying.sink { [weak self] on in
            self?.statusItem.button?.image = NSImage(systemSymbolName: on ? "dot.radiowaves.left.and.right" : "radio",
                                                      accessibilityDescription: "StarPlayrX")
        }
    }

    /// Icon click: open under the menu bar, close if open there, or move a torn-off panel back under it.
    @objc func statusItemClicked() {
        if panel.isVisible && !detached { hide(); return }
        // Shaded and torn off: glide back still rolled up, then unroll once in place.
        let unshade = panel.isVisible && detached && shaded
        if !unshade {
            detached = false
            shaded = false
        }
        if let button = statusItem.button?.window?.frame {
            let screen = statusItem.button?.window?.screen?.visibleFrame ?? .infinite
            let x = min(button.minX, screen.maxX - panel.frame.width)
            let top = NSPoint(x: x, y: button.minY - 4)
            if panel.isVisible {
                // Torn off: glide back under the menu bar instead of jumping. Stepped by hand
                // (top-left point per frame) so the unshade resize can't cut the animation short.
                let start = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
                let began = CACurrentMediaTime()
                let duration = 0.4
                glide?.invalidate()
                glide = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
                    Task { @MainActor in
                        guard let self else { timer.invalidate(); return }
                        let t = min((CACurrentMediaTime() - began) / duration, 1)
                        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2   // ease in-out
                        self.panel.setFrameTopLeftPoint(NSPoint(x: start.x + (top.x - start.x) * eased,
                                                                y: start.y + (top.y - start.y) * eased))
                        guard t >= 1 else { return }
                        timer.invalidate()
                        self.glide = nil
                        self.panel.refreshShadow()
                        if unshade {
                            // Same as the double-click unshade: the panel grows from its pinned top edge.
                            self.detached = false
                            self.shaded = false
                        }
                    }
                }
            } else {
                panel.setFrameTopLeftPoint(top)
            }
        }
        // Like MenuBarExtra: the app becomes active (controls draw active, not greyed) and
        // the menu bar icon stays highlighted while the panel hangs under it.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        light(true)
        // Under the menu bar it behaves like a menu: a click in another app closes it.
        // Clicks on our own icon are left to statusItemClicked, or the two would fight
        // (monitor hides, then the click reopens).
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in
                    guard let self, !(self.statusItem.button?.window?.frame.contains(point) ?? false) else { return }
                    self.hide()
                }
            }
        }
    }

    /// Torn off: the panel stays where it was dropped, until Close / Esc / the icon.
    func detach() {
        detached = true
        light(false)
        removeOutsideClick()
    }

    func hide() {
        glide?.invalidate()
        glide = nil
        panel.orderOut(nil)
        detached = false
        shaded = false
        light(false)
        removeOutsideClick()
    }

    /// The lit menu bar icon. AppKit clears a status button's highlight when the click that set it
    /// finishes (and when the panel takes key away from the status bar window), so the state is
    /// re-applied on the next pass of the run loop — unless it has since changed again.
    private var lit = false
    private func light(_ on: Bool) {
        lit = on
        statusItem.button?.highlight(on)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lit == on else { return }
            self.statusItem.button?.highlight(on)
        }
    }

    private func removeOutsideClick() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
    }

    /// Opens the panel under the menu bar unless it is already showing (anywhere).
    func ensureShown() {
        if !panel.isVisible { statusItemClicked() }
    }

    // MARK: Drag / tear off (header gesture and scripts)

    static let tearOffDistance: CGFloat = 40
    private var dragOrigin: NSPoint?

    func beginDrag() { dragOrigin = panel.frame.origin }

    /// `delta` is in screen points (Cocoa: y up) from where the drag began.
    func drag(by delta: CGSize) {
        guard let start = dragOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: start.x + delta.width, y: start.y + delta.height))
    }

    /// Let go far enough from the menu bar and it stays torn off; otherwise it snaps back.
    func endDrag() {
        guard let start = dragOrigin else { return }
        dragOrigin = nil
        defer { panel.refreshShadow() }
        guard !detached else { return }
        if hypot(panel.frame.minX - start.x, panel.frame.minY - start.y) > Self.tearOffDistance {
            detach()
        } else {
            panel.setFrameOrigin(start)
        }
    }

    // MARK: Position and parking

    enum Corner { case upperLeft, upperRight, lowerLeft, lowerRight }

    /// Top-left point that puts a panel of `size` in `corner` of `visible`, `margin` points in.
    nonisolated static func parkedTopLeft(_ corner: Corner, size: NSSize, in visible: NSRect, margin: CGFloat = 8) -> NSPoint {
        let left = corner == .upperLeft || corner == .lowerLeft
        let upper = corner == .upperLeft || corner == .upperRight
        return NSPoint(x: left ? visible.minX + margin : visible.maxX - size.width - margin,
                       y: upper ? visible.maxY - margin : visible.minY + size.height + margin)
    }

    /// Tears the panel off and moves it to a corner of its screen (below the menu bar, above the Dock).
    func park(_ corner: Corner) {
        ensureShown()
        detach()
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(Self.parkedTopLeft(corner, size: panel.frame.size, in: visible))
    }

    /// AppleScript screen coordinates have y going down from the top of the main screen; Cocoa's go up.
    /// The conversion is its own inverse.
    nonisolated static func flipY(_ p: NSPoint, mainScreenHeight h: CGFloat) -> NSPoint { NSPoint(x: p.x, y: h - p.y) }

    private var mainScreenHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// Top-left of the panel in AppleScript coordinates. Moving it tears it off, like dragging.
    var scriptPosition: NSPoint {
        get { Self.flipY(NSPoint(x: panel.frame.minX, y: panel.frame.maxY), mainScreenHeight: mainScreenHeight) }
        set {
            ensureShown()
            detach()
            panel.setFrameTopLeftPoint(Self.flipY(newValue, mainScreenHeight: mainScreenHeight))
        }
    }

    // MARK: Channel list (search and scrolling)

    @Published var search = ""
    /// The star beside the search field: only the starred channels are listed.
    @Published var starsOnly = false

    /// The channels the list shows right now (after the search field and the stars filter).
    var visibleChannels: [Channel] {
        Channel.filter(Radio.shared.channels, nowPlaying: Radio.shared.nowPlaying, search: search,
                       stars: starsOnly ? Radio.shared.presets : nil)
    }

    /// The channel list's NSScrollView (the SwiftUI ScrollView's backing view): the one with the tallest content.
    var channelScrollView: NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(all)
        }
        guard let root = panel.contentView else { return nil }
        return all(root).filter { $0.documentView != nil }
            .max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    /// Height of one channel row (rows are fixed height), 0 when the list isn't on screen.
    var rowHeight: CGFloat {
        let count = visibleChannels.count
        guard count > 0, let doc = channelScrollView?.documentView else { return 0 }
        return doc.frame.height / CGFloat(count)
    }

    /// How far the list is scrolled, in points from the top. Setting it scrolls (clamped to the list).
    var scrollOffset: CGFloat {
        get {
            guard let sv = channelScrollView, let doc = sv.documentView else { return 0 }
            let clip = sv.contentView.bounds
            return doc.isFlipped ? clip.minY : doc.frame.height - clip.maxY
        }
        set {
            guard let sv = channelScrollView, let doc = sv.documentView else { return }
            let clip = sv.contentView.bounds
            let offset = min(max(newValue, 0), max(doc.frame.height - clip.height, 0))
            let y = doc.isFlipped ? offset : doc.frame.height - clip.height - offset
            sv.contentView.scroll(to: NSPoint(x: clip.minX, y: y))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    /// The first channel row at the top of the scrolled list.
    var topVisibleChannel: Channel? {
        let rows = visibleChannels
        let h = rowHeight
        guard h > 0, !rows.isEmpty else { return nil }
        return rows[min(rows.count - 1, max(0, Int((scrollOffset + 1) / h)))]
    }

    /// Scrolls so the channel's row is at the top (or as far as the list goes). False if it isn't listed.
    @discardableResult
    func scroll(to id: String) -> Bool {
        guard let index = visibleChannels.firstIndex(where: { $0.id == id }), rowHeight > 0 else { return false }
        scrollOffset = CGFloat(index) * rowHeight
        return true
    }

    /// Centers the channel's row in the list, unless it's already fully in view.
    func reveal(_ id: String) {
        let h = rowHeight
        guard h > 0, let index = visibleChannels.firstIndex(where: { $0.id == id }),
              let clip = channelScrollView?.contentView.bounds.height else { return }
        let top = CGFloat(index) * h
        guard top < scrollOffset || top + h > scrollOffset + clip else { return }
        scrollOffset = top - (clip - h) / 2
    }
}

/// Borderless panel with the translucent menu look, rounded corners and shadow.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // borderless panels can't otherwise take typing (search)
    override func cancelOperation(_ sender: Any?) { MenuController.shared.hide() }   // Esc closes it

    /// ⌘T tears the panel off (or puts it back) and ⌘R rolls it up or down. The drag and the
    /// double-click that do the same need a mouse; these work from the keyboard and VoiceOver.
    /// A key equivalent, not `keyDown`: the search field is usually first responder and would eat it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let menu = MenuController.shared
        switch (event.modifierFlags.intersection(.deviceIndependentFlagsMask), event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "t"):
            if menu.detached { menu.hide(); menu.statusItemClicked() } else { menu.detach() }
            return true
        case (.command, "r"):
            menu.shaded.toggle()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Keep the top edge pinned when the content resizes (window shade), instead of the bottom.
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if isVisible, rect.size != frame.size {
            rect.origin = NSPoint(x: frame.minX, y: frame.maxY - rect.height)
        }
        super.setFrame(rect, display: flag)
        if isVisible { refreshShadow() }
    }

    /// A clear borderless window can leave its old shadow on screen after it moves or resizes
    /// (a ghost the compositor shows but screenshots don't). Rebuild the shadow from scratch.
    func refreshShadow() {
        hasShadow = false
        hasShadow = true
        invalidateShadow()
    }

    static func make() -> MenuPanel {
        let panel = MenuPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.title = "StarPlayrX"   // borderless: no title bar, but VoiceOver reads this
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let menu = MenuView().environmentObject(Radio.shared)
        let root: AnyView
        if #available(macOS 26, *) {
            // Same Liquid Glass look as a MenuBarExtra window. AppKit's NSGlassEffectView, not
            // SwiftUI's .glassEffect, which leaves a dark rim in a borderless clear window.
            root = AnyView(menu.background(MenuGlass())
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        } else {
            root = AnyView(menu.background(MenuMaterial())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)))
        }
        // A hosting controller sizes the panel to the view (and follows it when the
        // spectrum appears); a bare hosting view in a .zero rect leaves it 0×0 and invisible.
        let host = NSHostingController(rootView: root)
        panel.contentViewController = host
        panel.setContentSize(host.view.fittingSize)
        return panel
    }
}

/// Liquid Glass background (macOS 26+).
@available(macOS 26, *)
private struct MenuGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = 16
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {}
}

/// The blurred, behind-window material menu bar panels use.
private struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
