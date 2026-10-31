import SwiftUI
import Combine

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var menu = MenuController.shared
    @State private var search = ""

    private var filtered: [Channel] {
        guard !search.isEmpty else { return radio.channels }
        return radio.channels.filter { ch in
            let np = radio.nowPlaying[ch.id]
            let xtraTerms = ch.xtraID != nil ? "Music Xtra" : ""
            return [ch.id, ch.name, ch.category, xtraTerms, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    /// Torn off only: double-click the tear-off area to roll the panel up to just that area.
    private var shaded: Bool { menu.detached && menu.shaded }

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
                .simultaneousGesture(TapGesture(count: 2).onEnded { if menu.detached { menu.shaded.toggle() } })
                if !shaded {
                    TextField("Search channels, artists, songs", text: $search)
                        .textFieldStyle(.roundedBorder)
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

    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// Drag the header to pull the panel off the menu bar; let go far enough away and the same
    /// panel stays where it was dropped (torn off). Once torn off, dragging just moves it.
    private var tearOff: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                guard let panel = menu.panel else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
                guard let start = dragStart else { return }
                panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                             y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in
                guard let start = dragStart else { return }
                dragStart = nil
                guard !menu.detached else { return }
                let frame = menu.panel.frame
                if hypot(frame.minX - start.origin.x, frame.minY - start.origin.y) > 40 {
                    menu.detach()
                } else {
                    menu.panel.setFrameOrigin(start.origin)
                }
            }
    }



    private var nowPlaying: some View {
        HStack(spacing: 10) {
            let np = radio.current.flatMap { radio.nowPlaying[$0.id] }
            AsyncImage(url: URL(string: (np?.image.isEmpty == false ? np?.image : radio.current?.imageURL) ?? "")) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "radio").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

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

    /// Icon click: open under the menu bar, close if open there, or call a torn-off panel back.
    @objc private func statusItemClicked() {
        if panel.isVisible && !detached { hide(); return }
        detached = false
        shaded = false
        if let button = statusItem.button?.window?.frame {
            let screen = statusItem.button?.window?.screen?.visibleFrame ?? .infinite
            let x = min(button.minX, screen.maxX - panel.frame.width)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: button.minY - 4))
        }
        // Like MenuBarExtra: the app becomes active (controls draw active, not greyed) and
        // the menu bar icon stays highlighted while the panel hangs under it.
        NSApp.activate(ignoringOtherApps: true)
        statusItem.button?.highlight(true)
        panel.makeKeyAndOrderFront(nil)
        // Under the menu bar it behaves like a menu: a click in another app closes it.
        if outsideClick == nil {
            outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.hide() }
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