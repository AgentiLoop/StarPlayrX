//
//  MenuView.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import Combine
import ImageIO

extension Channel {
    /// The search field's matching: number, name, category, "Music Xtra", artist and song.
    static func filter(_ channels: [Channel], nowPlaying: [String: NowPlaying], search: String) -> [Channel] {
        guard !search.isEmpty else { return channels }
        return channels.filter { ch in
            let np = nowPlaying[ch.id]
            let xtraTerms = ch.xtraID != nil ? "Music Xtra" : ""
            return [ch.id, ch.name, ch.category, xtraTerms, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }
}

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var menu = MenuController.shared

    private var filtered: [Channel] {
        Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: menu.search)
    }

    /// Double-click the tear-off area to roll the panel up to just that area (under the menu bar or torn off).
    private var shaded: Bool { menu.shaded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                if radio.isLoggedIn {
                    // Tear-off / drag area: artwork, titles and the spectrum.
                    VStack(alignment: .leading, spacing: 0) {
                        nowPlaying
                        // Tucked up under the artwork: the bar area is 40 pt tall but mostly empty when the
                        // music is quiet, so a full gap above it left a big hole. Loud bars may rise beside the art.
                        if radio.isPlaying { SpectrumView().padding(.top, -5) }
                    }
                    .contentShape(Rectangle())
                    .gesture(tearOff)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { menu.shaded.toggle() })
                } else {
                    Text(radio.status).foregroundStyle(.secondary)
                    Button(radio.isBusy ? "Signing in…" : "Sign In…") {
                        Task { await CredentialPrompt.signIn() }
                    }
                    .disabled(radio.isBusy)
                }
            }
            // Shading collapses this part instead of removing it: rebuilding the whole channel
            // list on unshade blocked the main thread and froze the equalizer.
            VStack(alignment: .leading, spacing: 10) {
                if radio.isLoggedIn {
                    SearchField(text: $menu.search, placeholder: "Search channels, artists, songs")
                    channelList
                }
                Divider()
                footer
            }
            .padding(.top, 10)
            .frame(height: shaded ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(shaded ? 0 : 1)
            .allowsHitTesting(!shaded)
            .accessibilityHidden(shaded)
        }
        .padding(12)
        .frame(width: 340)
    }

    @State private var dragMouseStart: NSPoint?

    /// Drag the header to pull the panel off the menu bar; let go far enough away and the same
    /// panel stays where it was dropped (torn off). Once torn off, dragging just moves it.
    private var tearOff: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation
                if dragMouseStart == nil {
                    dragMouseStart = mouse
                    menu.beginDrag()
                }
                guard let start = dragMouseStart else { return }
                menu.drag(by: CGSize(width: mouse.x - start.x, height: mouse.y - start.y))
            }
            .onEnded { _ in
                guard dragMouseStart != nil else { return }
                dragMouseStart = nil
                menu.endDrag()
            }
    }



    private var nowPlaying: some View {
        HStack(spacing: 10) {
            let np = radio.current.flatMap { radio.displayed($0.id) }
            let isAlbumArt = np?.image.isEmpty == false
            CachedArt(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: 64, isAlbumArt: isAlbumArt) { art, isAlbumArt in
                if let art, isAlbumArt {
                    // Fill only: square art fits exactly; non-square art is enlarged just enough to cover the tile.
                    Image(nsImage: art).resizable().scaledToFill()
                } else if let art {
                    // Channel logos must stay whole; square channel art is enlarged to fill the squircle.
                    let logo = ChannelLogo(image: Image(nsImage: art))
                        .frame(width: 64, height: 64)
                    if #available(macOS 26.0, *) {
                        // Dark-tinted Liquid Glass tile behind the logo.
                        // Glass only behind the logo, so the logo itself stays crisp (not lensed by the glass).
                        logo.background(Color.clear.glassEffect(.regular.tint(Color(white: 0.12).opacity(0.6)),
                                                                in: RoundedRectangle(cornerRadius: 14.5, style: .continuous)))
                    } else {
                        logo.background(Color(white: 0.12))   // dark tile so logos sit like album art
                    }
                } else {
                    // No channel art or logo (or not loaded yet): the StarPlayrX logo, enlarged past the
                    // icon's transparent margin (824pt body on a 1024pt canvas) so it fills the tile like art.
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFill().scaleEffect(1024 / 824)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14.5, style: .continuous))   // squircle, app-icon ratio
            .simultaneousGesture(TapGesture().onEnded {
                // Click the artwork: channel logo ⇄ show art, remembered per channel. When there's nothing
                // to switch (song art, or no show art) it scrolls the list to the channel as before.
                if let id = radio.current?.id, radio.toggleShowArt(id) { return }
                revealCurrent()
            })

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    Text("\(ch.id) · \(ch.name)").font(.caption).foregroundStyle(.secondary)
                    MarqueeText(text: np?.song ?? "", font: .headline).id(np?.song ?? "")
                    MarqueeText(text: np?.artist ?? "", font: .body).id(np?.artist ?? "")
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { revealCurrent() })
            Button {
                radio.togglePlayPause()
            } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .disabled(radio.current == nil)
        }
    }

    /// Single click on the now-playing art or titles: bring the current channel's row into view.
    private func revealCurrent() {
        if let id = radio.current?.id { menu.reveal(id) }
    }

    /// LazyVStack: only rows near the visible part of the list exist, so the hundreds of channels
    /// don't each keep a live view (and its art) in memory; rows that scroll away are freed.
    private var channelList: some View {
        let list = filtered
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, ch in
                        Button {
                            radio.play(ch)
                        } label: {
                            ChannelRow(channel: ch, nowPlaying: radio.displayed(ch.id),
                                       isCurrent: ch == radio.current,
                                       isPlaying: ch == radio.current && radio.isPlaying)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .id(ch.id)
                        .onAppear { prefetchArt(around: index, in: list) }
                    }
                }
            }
            .frame(height: CachedArt<EmptyView>.listHeight)
            .padding(.trailing, -12)   // scroll bar sits at the window's right edge
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    /// Look-ahead: when a row appears, start loading the art of the 10 rows above and below it,
    /// so it's usually already in `ArtCache` by the time those rows scroll into view.
    private func prefetchArt(around index: Int, in list: [Channel]) {
        for ch in list[max(0, index - 10)..<min(list.count, index + 11)] {
            let albumArt = (radio.displayed(ch.id)?.image).flatMap { $0.isEmpty ? nil : $0 }
            ArtCache.shared.prefetch(albumArt ?? ch.imageURL, pixels: ArtCache.pixels(32), trimBorder: albumArt != nil)
        }
    }

    /// "v1.1.8" from the bundle; Debug builds add "-dev".
    static let version: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if DEBUG
        return "v\(v)-dev"
        #else
        return "v\(v)"
        #endif
    }()

    private var footer: some View {
        HStack {
            // Click for the Modern API switch. Not offered after a modern sign-in: there is no
            // legacy session to switch to.
            if radio.modernLogin {
                Text(Self.version).font(.caption).foregroundStyle(.tertiary).offset(y: 2)
            } else {
                Menu {
                    Toggle("Modern API for live channels", isOn: Binding(
                        get: { radio.modernLive }, set: { radio.setModernLive($0) }))
                } label: {
                    Text(Self.version).font(.caption).foregroundStyle(.tertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .offset(y: 2)
            }
            Spacer()
            if radio.isLoggedIn {
                Button("Sign Out") { radio.signOut() }
            }
            if menu.detached {
                Button("Close") { menu.hide() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

/// One channel row. Equatable so a now-playing update redraws only the row it changed,
/// and always two lines tall so the list never has to re-measure rows while scrolling.
private struct ChannelRow: View, Equatable {
    let channel: Channel
    let nowPlaying: NowPlaying?
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack {
            Text(channel.id).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            // Album art when the channel has it, else the channel logo, else the StarPlayrX logo.
            let albumArt = nowPlaying?.image.isEmpty == false
            CachedArt(url: (albumArt ? nowPlaying?.image : channel.imageURL) ?? "", size: 32, isAlbumArt: albumArt) { art, albumArt in
                if let art {
                    if albumArt {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        // Same as the header: square channel art is enlarged to fill the squircle,
                        // on the same dark-tinted Liquid Glass tile (solid dark before macOS 26).
                        let logo = ChannelLogo(image: Image(nsImage: art), inset: 2)
                            .frame(width: 32, height: 32)
                        if #available(macOS 26.0, *) {
                            logo.background(Color.clear.glassEffect(.regular.tint(Color(white: 0.12).opacity(0.6)),
                                                                    in: RoundedRectangle(cornerRadius: 7.25, style: .continuous)))
                        } else {
                            logo.background(Color(white: 0.12))
                        }
                    }
                } else {
                    // Same as the header: enlarged past the icon's transparent margin so it fills like art.
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFill().scaleEffect(1024 / 824)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7.25, style: .continuous))
            VStack(alignment: .leading) {
                // Same as Now Playing: text that doesn't fit scrolls instead of ending in "…".
                MarqueeText(text: channel.name, font: isCurrent ? .body.bold() : .body).id(channel.name)
                let line = nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " "
                MarqueeText(text: line, font: .caption, secondary: true).id(line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
    }
}

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
        statusItem.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
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
        statusItem.button?.highlight(false)
        removeOutsideClick()
    }

    func hide() {
        glide?.invalidate()
        glide = nil
        panel.orderOut(nil)
        detached = false
        shaded = false
        statusItem.button?.highlight(false)
        removeOutsideClick()
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

    /// The channels the list shows right now (after the search field).
    var visibleChannels: [Channel] {
        Channel.filter(Radio.shared.channels, nowPlaying: Radio.shared.nowPlaying, search: search)
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
/// Channel art scaled to fit; when the art is square (it would fit the squircle but leave a margin
/// and show its own baked-in corners) it's enlarged to fill the squircle instead.
private struct ChannelLogo: View {
    let image: Image
    var inset: CGFloat = 4
    @State private var isSquare = false

    var body: some View {
        image.resizable().interpolation(.high).scaledToFit()
            .onGeometryChange(for: Bool.self) { abs($0.size.width - $0.size.height) < 2 } action: { isSquare = $0 }
            .scaleEffect(isSquare ? 1.12 : 1)
            .padding(isSquare ? 0 : inset)
    }
}

/// Channel logos and album art kept in memory once loaded. Nothing is fetched until it's shown or about to be (list look-ahead),
/// and a URL that is already loading is shared instead of downloaded twice. Each image is fetched
/// (where the server can resize) and decoded at 2x the points it is shown at, so the 32pt channel
/// rows and the 64pt Now Playing tile each get their own size, and the cache is bounded.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 200 * 192 * 192 * 4
        return cache
    }()
    /// Its own on-disk URL cache (small in memory), so art evicted from `images` or from a
    /// previous launch comes back from disk instead of the network.
    nonisolated private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024,
                                   directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                                       .appendingPathComponent(Bundle.main.bundleIdentifier ?? "StarPlayrX", isDirectory: true)
                                       .appendingPathComponent("ArtCache", isDirectory: true))
        config.requestCachePolicy = .returnCacheDataElseLoad   // art at a URL never changes
        return URLSession(configuration: config)
    }()
    // Download and decode run off the main actor so arriving art never stalls scrolling;
    // the NSImage is made here on the main actor, since NSImage is only Sendable from macOS 14.
    private var loading: [String: Task<Thumbnail?, Never>] = [:]
    /// `sized(_:pixels:)` results: it base64-decodes JSON, too slow to redo in every row's body.
    private var sizedURLs: [String: String] = [:]

    /// A decoded bitmap handed back from a background task.
    struct Thumbnail: @unchecked Sendable { let image: CGImage }

    /// Pixels for art shown at `points`: 3x, so square logos enlarged 1.12x to fill the squircle
    /// are still downscaled on a 2x display instead of stretched (which made them blurry).
    static let scale: CGFloat = 3
    static func pixels(_ points: CGFloat) -> Int { Int((points * scale).rounded(.up)) }

    // Keyed by pixels too: hosts with one size give the 32pt row and the 64pt header the same URL,
    // and the header must not get the row's small bitmap.
    func cached(_ url: String, pixels: Int) -> NSImage? {
        images.object(forKey: "\(pixels) \(sizedURL(url, pixels: pixels))" as NSString)
    }

    /// `trimBorder` (album art): a solid frame around the picture is cropped off, see `trimmedBorder`.
    func image(_ url: String, pixels: Int, trimBorder: Bool = false) async -> NSImage? {
        let url = sizedURL(url, pixels: pixels)
        let key = "\(pixels) \(url)"
        if let image = images.object(forKey: key as NSString) { return image }
        guard !url.isEmpty, let address = URL(string: url) else { return nil }
        let task = loading[key] ?? Task.detached(priority: .utility) {
            guard let data = try? await ArtCache.session.data(from: address).0,
                  let thumb = ArtCache.thumbnail(data, pixels: pixels, trimBorder: trimBorder) else { return nil }
            return Thumbnail(image: thumb)
        }
        loading[key] = task
        let thumb = await task.value?.image
        loading[key] = nil
        if let image = images.object(forKey: key as NSString) { return image }   // another caller already made it
        guard let thumb else { return nil }
        let image = NSImage(cgImage: thumb, size: NSSize(width: CGFloat(thumb.width) / Self.scale, height: CGFloat(thumb.height) / Self.scale))
        images.setObject(image, forKey: key as NSString, cost: thumb.bytesPerRow * thumb.height)
        return image
    }

    /// Starts loading art that isn't shown yet; `image` shares the download if a row asks for it meanwhile.
    func prefetch(_ url: String, pixels: Int, trimBorder: Bool = false) {
        guard !url.isEmpty, cached(url, pixels: pixels) == nil else { return }
        Task { _ = await image(url, pixels: pixels, trimBorder: trimBorder) }
    }

    private func sizedURL(_ url: String, pixels: Int) -> String {
        let key = "\(pixels) \(url)"
        if let sized = sizedURLs[key] { return sized }
        let sized = Self.sized(url, pixels: pixels)
        sizedURLs[key] = sized
        return sized
    }

    /// The same art at the smallest size the server offers that still covers `pixels`.
    /// Other hosts (live channel logos, Xtra track art) only have one size and are just decoded smaller.
    private static func sized(_ url: String, pixels: Int) -> String {
        // SiriusXM's image server (channel tiles): the resize is part of the base64 JSON path.
        let imageServer = "https://imgsrv-sxm-prod-device.streaming.siriusxm.com/"
        if url.hasPrefix(imageServer),
           let data = Data(base64Encoded: String(url.dropFirst(imageServer.count))),
           var spec = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            spec["edits"] = [["resize": ["width": pixels, "height": pixels]]]
            guard let json = try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return url }
            return imageServer + json.base64EncodedString()
        }
        // Live album art comes as _m (450px); _t is 75px and _s 170px.
        if url.hasPrefix("http://albumart.siriusxm.com/"), url.hasSuffix("_m.jpg") {
            let size = pixels <= 75 ? "_t" : pixels <= 170 ? "_s" : "_m"
            return url.dropLast("_m.jpg".count) + size + ".jpg"
        }
        return url
    }

    /// Decodes straight to a small bitmap, so neither the downloaded Data nor a full-size image is kept.
    nonisolated private static func thumbnail(_ data: Data, pixels: Int, trimBorder: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return trimBorder ? trimmedBorder(thumb) : thumb
    }

    /// Some album art is boxed in a solid frame (a white or black margin, or non-square art
    /// letterboxed to a square), and filling the squircle with it shows the frame instead of the
    /// picture. Scans in from each edge for rows/columns of one colour and crops them off, so
    /// `scaledToFill` zooms to the picture. Only a frame is cropped: the two sides of a pair
    /// (top/bottom, left/right) must be the same colour and about as deep, and end well inside
    /// the picture — a cover with a flat sky, or a flat background all the way to the middle, is
    /// not a frame and is left alone.
    nonisolated private static func trimmedBorder(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w >= 16, h >= 16,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // memory row 0 is the top row
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        typealias RGB = (Int, Int, Int)
        func pixel(_ x: Int, _ y: Int) -> RGB {
            let i = (y * w + x) * 4
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
        }
        // JPEG ringing and dithering within a flat colour; opposite sides of a frame drift further.
        func near(_ a: RGB, _ b: RGB, tolerance: Int = 28) -> Bool {
            abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
        }
        // How deep the frame is on one side: lines (rows or columns) from the edge inward, and the
        // colour of the outermost line. A frame is a band of one flat colour, which may carry a
        // title or logo (a sliver of other pixels, or a bold title with the band's colour back
        // after it) and may be followed by a thin band of another flat colour (double border,
        // hairline). It ends at a line that is mostly another colour: the picture's edge. Depth 0
        // when it isn't a frame: the band gave way gradually (a horse against a flat background of
        // the same colour); `limit` when it never ended (a flat background all the way in).
        func inset(upTo limit: Int, _ line: (Int) -> [RGB]) -> (depth: Int, color: RGB) {
            let count = line(0).count
            let allowed = count / 100        // stray pixels a flat line may have
            let thin = max(3, count / 12)    // an inner band deeper than this is the picture, not a border
            func mean(_ l: [RGB]) -> RGB {
                (l.map(\.0).reduce(0, +) / count, l.map(\.1).reduce(0, +) / count, l.map(\.2).reduce(0, +) / count)
            }
            func off(_ l: [RGB], _ c: RGB) -> Int { l.filter { !near($0, c) }.count }
            let outer = mean(line(0))
            var ref = outer          // colour of the band being scanned
            var bandStart = 0        // where that band began
            var lastFlat = -1        // last line that was flat in `ref`
            var edge: Int?           // the band ended here, on a line mostly another colour
            var n = 0
            while n < limit {
                let l = line(n), m = mean(l)
                let flat = off(l, m) <= allowed
                if let e = edge {
                    // Just past the band: a flat line of another colour within 2 lines (JPEG blurs
                    // the transition) is an inner border; the band's own colour again within 2
                    // thins means a title or hairline sat in the band. Otherwise the picture
                    // starts at the edge.
                    if flat, near(m, ref) {
                        edge = nil
                        lastFlat = n
                    } else if flat, n - e <= 2 {
                        ref = m; bandStart = e
                        edge = nil
                        lastFlat = n
                    } else if n - e >= 2 * thin {
                        return (e, outer)
                    }
                } else if bandStart > 0, n - bandStart > thin {
                    return (bandStart, outer)   // an inner band this deep is the picture (a flat sky)
                } else if flat, near(m, ref) {
                    lastFlat = n
                } else if off(l, ref) * 2 >= count {
                    // Gave way gradually: a subject against a flat background, not a frame. Inside
                    // an inner band that means the band was the picture.
                    if n - lastFlat > 3 { return (bandStart, outer) }
                    edge = n
                }
                n += 1
            }
            if let e = edge { return (e, outer) }
            return (bandStart > 0 ? bandStart : limit, outer)
        }
        // A pair of opposite sides is a frame when both are bands of the same colour that reached
        // the picture and are about as deep. On its own (a letterbox) the pair is nearly symmetric;
        // when all four sides are bands of one colour it is a full frame, and the side carrying the
        // title may be a good deal deeper. Each side loses its depth plus one line, where the
        // frame's edge bleeds into the picture.
        typealias Side = (depth: Int, color: RGB)
        func band(_ a: Side, _ b: Side, limit: Int) -> Bool {
            a.depth > 0 && b.depth > 0 && a.depth < limit && b.depth < limit && near(a.color, b.color, tolerance: 40)
        }
        func symmetric(_ a: Side, _ b: Side, within slack: Int) -> Bool { abs(a.depth - b.depth) <= max(3, slack) }
        // Letterboxed 2.35:1 art has bars of 29% a side, so look up to 30% in. Each line is read
        // over the middle 70% of its length only, so the frame along the other two sides (and a
        // hairline inside it) doesn't make the lines of an inner band look busy.
        let limitY = h * 3 / 10, limitX = w * 3 / 10
        let xs = (w * 3 / 20)..<(w * 17 / 20), ys = (h * 3 / 20)..<(h * 17 / 20)
        let t = inset(upTo: limitY) { y in xs.map { pixel($0, y) } }
        let b = inset(upTo: limitY) { y in xs.map { pixel($0, h - 1 - y) } }
        let l = inset(upTo: limitX) { x in ys.map { pixel(x, $0) } }
        let r = inset(upTo: limitX) { x in ys.map { pixel(w - 1 - x, $0) } }
        let rows = band(t, b, limit: limitY), cols = band(l, r, limit: limitX)
        let full = rows && cols && near(t.color, l.color, tolerance: 40)
            && symmetric(t, b, within: limitY / 3) && symmetric(l, r, within: limitX / 3)
        let (top, bottom) = full || (rows && symmetric(t, b, within: limitY / 5)) ? (t.depth + 1, b.depth + 1) : (0, 0)
        let (left, right) = full || (cols && symmetric(l, r, within: limitX / 5)) ? (l.depth + 1, r.depth + 1) : (0, 0)
        guard top + bottom + left + right > 0 else { return image }
        let rect = CGRect(x: left, y: top, width: w - left - right, height: h - top - bottom)
        return image.cropping(to: rect) ?? image
    }
}

/// Shows the image at `url` from `ArtCache`, loading it lazily at 2x `size` points. `content` gets
/// the image and whether it is album art (`isAlbumArt` belongs to `url`); nil when nothing is loaded.
private struct CachedArt<Content: View>: View {
    let url: String
    let size: CGFloat
    var isAlbumArt = false
    @ViewBuilder let content: (NSImage?, Bool) -> Content
    @State private var loaded: (url: String, image: NSImage?, isAlbumArt: Bool)?

    var body: some View {
        let pixels = ArtCache.pixels(size)
        let image = loaded?.url == url ? loaded?.image : ArtCache.shared.cached(url, pixels: pixels)
        // Until the new art arrives, keep showing the previous art as it was (album art stays album
        // art): no flash of the logo or the StarPlayrX icon in between, in the header or in a row.
        Group {
            if let image { content(image, isAlbumArt) } else { content(loaded?.image, loaded?.isAlbumArt ?? false) }
        }
        .task(id: url) {
            let image = await ArtCache.shared.image(url, pixels: pixels, trimBorder: isAlbumArt)
            if !Task.isCancelled { loaded = (url, image, isAlbumArt) }
        }
    }
}

extension CachedArt {
    nonisolated static var listHeight: CGFloat { 360 }
}

/// The channel search box. A plain AppKit search field with AutoFill, text completion and inline
/// predictions turned off: SwiftUI's TextField sometimes popped up an empty AutoFill list.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }   // e.g. set from AppleScript
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let editor = note.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            if #available(macOS 14.0, *) { editor.inlinePredictionType = .no }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

/// One line of text that never truncates: if it doesn't fit, it scrolls smoothly left in a loop
/// (pausing at the start of each pass); if it fits, it just sits still.
private struct MarqueeText: View {
    let text: String
    let font: Font
    var secondary = false
    @State private var textWidth: CGFloat = 0

    private let gap: CGFloat = 40      // space between the end of the text and its repeat
    private let speed: CGFloat = 30    // points per second
    private let pause: Double = 2      // seconds held at the start of each pass

    var body: some View {
        // Invisible line sets the height; the width comes from the parent.
        Text(" ").font(font).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                    })
            }
            .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    if textWidth <= geo.size.width {
                        Text(text).font(font).fixedSize().foregroundStyle(secondary ? .secondary : .primary)
                    } else {
                        // Drawn once, then moved by Core Animation in the render server: no per-frame work
                        // in the app. (A TimelineView rebuilt every scrolling line 60 times a second.)
                        ScrollingStrip(content: AnyView(
                            HStack(spacing: gap) {
                                Text(text).font(font).fixedSize()
                                Text(text).font(font).fixedSize()
                            }
                            .foregroundStyle(secondary ? .secondary : .primary)),
                            key: "\(text)|\(secondary)", width: 2 * textWidth + gap, cycle: textWidth + gap, speed: speed, pause: pause)
                    }
                }
                .clipped()
            }
    }
}

/// Hosts `content` once and slides it left by `cycle` points on a repeating Core Animation, holding
/// at the start for `pause` seconds each pass. The content must repeat after `cycle` points.
private struct ScrollingStrip: NSViewRepresentable {
    let content: AnyView
    let key: String
    let width: CGFloat   // of `content` (both copies and the gap), measured by MarqueeText
    let cycle: CGFloat, speed: CGFloat, pause: Double

    func makeNSView(context: Context) -> Strip { Strip() }

    func updateNSView(_ view: Strip, context: Context) {
        view.configure(content: content, key: key, width: width, cycle: cycle, speed: speed, pause: pause)
    }

    final class Strip: NSView {
        private let host = NSHostingView(rootView: AnyView(EmptyView()))
        private var key = ""
        private var width: CGFloat = 0, cycle: CGFloat = 0, speed: CGFloat = 30, pause: Double = 2

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            host.sizingOptions = []
            host.wantsLayer = true
            addSubview(host)
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the row

        func configure(content: AnyView, key: String, width: CGFloat, cycle: CGFloat, speed: CGFloat, pause: Double) {
            guard key != self.key || cycle != self.cycle || width != self.width else { return }
            self.key = key
            (self.width, self.cycle, self.speed, self.pause) = (width, cycle, speed, pause)
            host.rootView = content
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // Exactly the content's width (measured in SwiftUI; fittingSize isn't reliable here): any
            // wider and SwiftUI centers the two copies in it, so the text paused in from the left edge.
            let height = host.fittingSize.height > 0 ? host.fittingSize.height : bounds.height
            host.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
            startAnimation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { startAnimation() }
        }

        private func startAnimation() {
            guard let layer = host.layer, cycle > 0 else { return }
            let move = Double(cycle / speed)
            let period = move + pause
            let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
            anim.values = [0, 0, -cycle]
            anim.keyTimes = [0, NSNumber(value: pause / period), 1]
            anim.duration = period
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.removeAnimation(forKey: "marquee")
            layer.add(anim, forKey: "marquee")
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

