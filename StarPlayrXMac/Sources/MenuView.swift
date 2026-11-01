import SwiftUI
import Combine

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
        VStack(alignment: .leading, spacing: 10) {
            if radio.isLoggedIn {
                // Tear-off / drag area: artwork, titles and the spectrum.
                VStack(alignment: .leading, spacing: 10) {
                    nowPlaying
                    if radio.isPlaying { SpectrumView() }
                }
                .contentShape(Rectangle())
                .gesture(tearOff)
                .simultaneousGesture(TapGesture(count: 2).onEnded { menu.shaded.toggle() })
                if !shaded {
                    SearchField(text: $menu.search, placeholder: "Search channels, artists, songs")
                    channelList
                }
            } else {
                Text(radio.status).foregroundStyle(.secondary)
                Button(radio.isBusy ? "Signing in…" : "Sign In…") {
                    Task { await CredentialPrompt.signIn() }
                }
                .disabled(radio.isBusy)
            }
            if !shaded {
                Divider()
                footer
            }
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
            let np = radio.current.flatMap { radio.nowPlaying[$0.id] }
            let isAlbumArt = np?.image.isEmpty == false
            CachedArt(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "") { art in
                if let art, isAlbumArt {
                    // Fill and overscale slightly so the white frame baked into some album art is cropped away.
                    Image(nsImage: art).resizable().scaledToFill().scaleEffect(1.1)
                } else if let art {
                    // Channel logos must stay whole; square channel art is enlarged to fill the squircle.
                    let logo = ChannelLogo(image: Image(nsImage: art))
                        .frame(width: 64, height: 64)
                    if #available(macOS 26.0, *) {
                        // Dark-tinted Liquid Glass tile behind the logo.
                        logo.glassEffect(.regular.tint(Color(white: 0.12).opacity(0.6)),
                                         in: RoundedRectangle(cornerRadius: 14.5, style: .continuous))
                    } else {
                        logo.background(Color(white: 0.12))   // dark tile so logos sit like album art
                    }
                } else {
                    // No channel art or logo (or not loaded yet): the StarPlayrX logo.
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFill()
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14.5, style: .continuous))   // squircle, app-icon ratio

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    Text("\(ch.id) · \(ch.name)").font(.caption).foregroundStyle(.secondary)
                    Text(np?.song ?? "").font(.headline).lineLimit(1)
                    Text(np?.artist ?? "").lineLimit(1)
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            Spacer()
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

    /// Non-lazy VStack: every row is built once when the menu opens, so scrolling never
    /// has to create rows on the fly (List creates them on first scroll, which stutters).
    private var channelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { ch in
                        Button {
                            radio.play(ch)
                        } label: {
                            ChannelRow(channel: ch, nowPlaying: radio.nowPlaying[ch.id],
                                       isCurrent: ch == radio.current,
                                       isPlaying: ch == radio.current && radio.isPlaying)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .id(ch.id)
                    }
                }
            }
            .frame(height: 360)
            .padding(.trailing, -12)   // scroll bar sits at the window's right edge
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Canada", isOn: Binding(get: { radio.localeIsCA }, set: { radio.setRegion(ca: $0) }))
                .toggleStyle(.checkbox)
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
            CachedArt(url: (albumArt ? nowPlaying?.image : channel.imageURL) ?? "") { art in
                if let art {
                    if albumArt {
                        Image(nsImage: art).resizable().scaledToFill().scaleEffect(1.1)
                    } else {
                        Image(nsImage: art).resizable().scaledToFit().padding(2).background(Color(white: 0.12))
                    }
                } else {
                    Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFill()
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7.25, style: .continuous))
            VStack(alignment: .leading) {
                Text(channel.name).fontWeight(isCurrent ? .bold : .regular).lineLimit(1)
                Text(nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
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
    private(set) var panel: MenuPanel!
    private var statusItem: NSStatusItem!
    private var outsideClick: Any?
    private var glide: Timer?
    private var playing: AnyCancellable?

    func install() {
        panel = MenuPanel.make()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        panel.contentViewController = NSHostingController(rootView: root)
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
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
    @State private var isSquare = false

    var body: some View {
        image.resizable().scaledToFit()
            .onGeometryChange(for: Bool.self) { abs($0.size.width - $0.size.height) < 2 } action: { isSquare = $0 }
            .scaleEffect(isSquare ? 1.12 : 1)
            .padding(isSquare ? 0 : 4)
    }
}

/// Channel logos and album art kept in memory once loaded. Nothing is fetched until it's shown,
/// and a URL that is already loading is shared instead of downloaded twice.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    private let images = NSCache<NSString, NSImage>()
    // Downloads hand back Data (Sendable); the NSImage is made here on the main actor, since
    // NSImage is only Sendable from macOS 14 and the app supports macOS 13.
    private var loading: [String: Task<Data?, Never>] = [:]

    func cached(_ url: String) -> NSImage? { images.object(forKey: url as NSString) }

    func image(_ url: String) async -> NSImage? {
        if let image = cached(url) { return image }
        guard !url.isEmpty, let address = URL(string: url) else { return nil }
        let task = loading[url] ?? Task<Data?, Never> {
            try? await URLSession.shared.data(from: address).0
        }
        loading[url] = task
        let data = await task.value
        loading[url] = nil
        if let image = cached(url) { return image }   // another caller already decoded it
        guard let data, let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: url as NSString)
        return image
    }
}

/// Shows the image at `url` from `ArtCache`, loading it lazily; `content` gets nil while it is
/// missing, loading or failed.
private struct CachedArt<Content: View>: View {
    let url: String
    @ViewBuilder let content: (NSImage?) -> Content
    @State private var loaded: (url: String, image: NSImage?)?

    var body: some View {
        content(loaded?.url == url ? loaded?.image : ArtCache.shared.cached(url))
            .task(id: url) {
                let image = await ArtCache.shared.image(url)
                if !Task.isCancelled { loaded = (url, image) }
            }
    }
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
