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
import os

let menuLog = Logger(subsystem: "com.starplayrx.mac", category: "menu")

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
    private var lit: Timer?
    private var playing: AnyCancellable?
    /// The mouse press that just closed the panel (on the icon or anywhere else) is still down:
    /// a session AppKit begins for that same press is its echo and is cancelled. Cleared when that
    /// press is released — not on a timer, so a quick next click opens again.
    private var closingPress = false
    private var closingPressAt = 0.0
    private var pressRelease: Any?

    func install() {
        _ = panel
        if #available(macOS 27, *) {
            // AppKit tracks the panel as this item's "expanded interface" and draws the real system
            // highlight capsule for as long as the session lasts. A highlight() set by hand is wiped
            // by the menu bar, so this is the only way it stays on. A left click sends no button
            // action once this is set.
            statusItem.expandedInterfaceDelegate = self
        } else {
            statusItem.button?.target = self
            statusItem.button?.action = #selector(statusItemClicked)
            statusItem.button?.sendAction(on: .leftMouseUp)
        }
        playing = Radio.shared.$isPlaying.sink { [weak self] on in
            self?.statusItem.button?.image = NSImage(systemSymbolName: on ? "dot.radiowaves.left.and.right" : "radio",
                                                      accessibilityDescription: "StarPlayrX")
        }
    }

    /// Ends `closingPress` once the press that closed the panel comes up.
    private func awaitPressRelease() {
        closingPress = true
        closingPressAt = CACurrentMediaTime()
        guard pressRelease == nil else { return }
        pressRelease = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let monitor = self.pressRelease { NSEvent.removeMonitor(monitor) }
                self.pressRelease = nil
                // AppKit may begin the echo session right on mouse-up; let that run first.
                DispatchQueue.main.async { self.closingPress = false }
            }
        }
    }

    /// Scripts and keyboard: open if hidden, close if visible.
    @objc func statusItemClicked() {
        if panel.isVisible { hide(); return }
        showUnderMenuBar()
    }

    /// Puts the panel under the menu bar — gliding it back first if it was torn off.
    private func showUnderMenuBar() {
        menuLog.log("show visible=\(self.panel.isVisible) detached=\(self.detached)")
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
        // Like MenuBarExtra: the app becomes active, so controls draw active rather than greyed.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // In a session AppKit draws the real highlight itself; only light it by hand without one.
        if #available(macOS 27, *), statusItem.expandedInterfaceSession != nil {} else { keepLit() }

        // Under the menu bar it behaves like a menu: any click outside the panel closes it. On
        // macOS 27 the menu bar belongs to MenuBarAgent, so a click on our own icon lands here too
        // (it is passed to no button action or delegate) — and closing is what it should do. The
        // session AppKit may begin for that same press is cancelled in didBegin.
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.panel.isVisible, !self.detached else { return }
                    self.awaitPressRelease()
                    self.hide()
                }
            }
        }
    }

    /// Torn off: the panel stays where it was dropped, until Close / Esc / the icon.
    func detach() {
        detached = true
        removeOutsideClick()
        endSession()
    }

    func hide() {
        menuLog.log("hide visible=\(self.panel.isVisible)")
        glide?.invalidate()
        glide = nil
        panel.orderOut(nil)
        detached = false
        shaded = false
        removeOutsideClick()

        endSession()
    }

    /// Clears the icon highlight and cancels any expanded interface session.
    /// The button un-highlights itself when its mouse tracking ends, which is after the click's
    /// action has run, so a one-time highlight() is wiped. Re-assert it while the panel hangs
    /// under the icon.
    private func keepLit() {
        lit?.invalidate()
        statusItem.button?.highlight(true)
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible, !self.detached else { return }
                if self.statusItem.button?.isHighlighted == false { self.statusItem.button?.highlight(true) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lit = timer
    }

    private func endSession() {
        lit?.invalidate()
        lit = nil
        statusItem.button?.highlight(false)
        if #available(macOS 27, *) { statusItem.expandedInterfaceSession?.cancel() }
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
    /// Clicking the song/artist in Now Playing puts the lyrics where the channel list was.
    @Published var lyrics = false

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

/// macOS 27: AppKit owns the show/hide of a status item's "expanded interface" (our panel), and in
/// return lights the icon with the genuine system highlight capsule and keeps keyboard navigation
/// and menu tracking working. We only open and close the panel when told to.
@available(macOS 27, *)
extension MenuController: @preconcurrency NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin session: NSStatusItemExpandedInterfaceSession) {
        menuLog.log("didBegin visible=\(self.panel.isVisible) detached=\(self.detached) closingPress=\(self.closingPress)")
        // The press that just closed the panel can also begin a session: cancel it, or the click
        // that closed the panel opens it straight back up. (If its mouse-up was somehow missed,
        // don't stay stuck: a press can't last that long.)
        if closingPress, CACurrentMediaTime() - closingPressAt < 2 {
            session.cancel()
            return
        }
        closingPress = false
        // Already open under the icon: this session is the highlight for it — keep it.
        if panel.isVisible, !detached { lit?.invalidate(); lit = nil; return }
        showUnderMenuBar()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        menuLog.log("didEnd visible=\(self.panel.isVisible) detached=\(self.detached)")
        // Torn off, it is no longer the icon's interface: it stays put and only the highlight ends.
        guard panel.isVisible, !detached else { return }
        hide()
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
