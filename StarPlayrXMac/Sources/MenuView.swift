import SwiftUI

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @State private var search = ""
    @State private var panel: NSWindow?
    var tornOff = false

    private var filtered: [Channel] {
        guard !search.isEmpty else { return radio.channels }
        return radio.channels.filter { ch in
            let np = radio.nowPlaying[ch.id]
            let xtraTerms = ch.xtraID != nil ? "Music Xtra" : ""
            return [ch.id, ch.name, ch.category, xtraTerms, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

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
                TextField("Search channels, artists, songs", text: $search)
                    .textFieldStyle(.roundedBorder)
                channelList
            } else {
                Text(radio.status).foregroundStyle(.secondary)
                Button(radio.isBusy ? "Signing in…" : "Sign In…") {
                    Task { await CredentialPrompt.signIn() }
                }
                .disabled(radio.isBusy)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .background(WindowReader { panel = $0 })
        // Opening the menu bar menu again puts the torn-off panel away: back to one menu.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard !tornOff, let panel, note.object as? NSWindow === panel else { return }
            TornOffPanel.dismiss()
        }
    }

    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// Drag the header to pull the menu panel off the menu bar; let go far enough away and a
    /// detached panel in the same menu style appears at that spot. Once torn off, it just moves it.
    private var tearOff: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { _ in
                guard let panel else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil { dragStart = (mouse, panel.frame.origin) }
                guard let start = dragStart else { return }
                panel.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                             y: start.origin.y + mouse.y - start.mouse.y))
            }
            .onEnded { _ in
                guard let panel, let start = dragStart else { return }
                dragStart = nil
                guard !tornOff else { return }
                let frame = panel.frame
                panel.setFrameOrigin(start.origin)
                guard hypot(frame.minX - start.origin.x, frame.minY - start.origin.y) > 40 else { return }
                // Show the torn-off panel first: taking key closes the menu the normal way, so
                // MenuBarExtra knows it's closed and the next menu bar click opens it again.
                TornOffPanel.show(topLeft: NSPoint(x: frame.minX, y: frame.maxY))
                panel.orderOut(nil)
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
            if tornOff {
                Button("Close") { panel?.orderOut(nil) }
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

/// Torn-off copy of the menu: a borderless panel with the same translucent menu look,
/// rounded corners and shadow as the menu bar panel, instead of a titled window.
final class TornOffPanel: NSPanel {
    private static var shared: TornOffPanel?

    override var canBecomeKey: Bool { true }   // borderless panels can't otherwise take typing (search)
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc closes it

    static func show(topLeft: NSPoint) {
        let panel = shared ?? make()
        shared = panel
        panel.setFrameTopLeftPoint(topLeft)
        panel.makeKeyAndOrderFront(nil)
    }

    static func dismiss() { shared?.orderOut(nil) }

    private static func make() -> TornOffPanel {
        let panel = TornOffPanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let root = MenuView(tornOff: true)
            .environmentObject(Radio.shared)
            .background(MenuMaterial())
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A hosting controller sizes the panel to the view (and follows it when the
        // spectrum appears); a bare hosting view in a .zero rect leaves it 0×0 and invisible.
        panel.contentViewController = NSHostingController(rootView: root)
        panel.setContentSize(panel.contentViewController!.view.fittingSize)
        return panel
    }
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

/// Hands back the NSWindow hosting a SwiftUI view (here: the MenuBarExtra panel).
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
