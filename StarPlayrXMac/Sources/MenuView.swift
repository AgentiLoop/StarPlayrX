import SwiftUI

struct MenuView: View {
    static let tornOffID = "player"

    @EnvironmentObject var radio: Radio
    @Environment(\.openWindow) private var openWindow
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
                if tornOff { nowPlaying } else { nowPlaying.gesture(tearOff) }
                if radio.isPlaying { SpectrumView() }
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
        .background(WindowReader { window in
            if tornOff { Self.present(window) } else { panel = window }
        })
    }

    /// Where the torn-off window's top-left corner should land (set at the end of the drag).
    private static var tearPoint: NSPoint?

    /// Called once the torn-off window exists: place it where the panel was dropped and bring
    /// it to the front (a menu-bar app isn't active, so a new window would open behind others).
    private static func present(_ window: NSWindow?) {
        guard let window else { return }
        if let point = tearPoint { window.setFrameTopLeftPoint(point) }
        tearPoint = nil
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()
    }

    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    /// Drag the now-playing header to pull the menu panel off the menu bar; let go far
    /// enough away and it becomes a regular window at that spot (like a detached popover).
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
                let frame = panel.frame
                panel.setFrameOrigin(start.origin)
                guard hypot(frame.minX - start.origin.x, frame.minY - start.origin.y) > 40 else { return }
                Self.tearPoint = NSPoint(x: frame.minX, y: frame.maxY)
                panel.orderOut(nil)
                openWindow(id: Self.tornOffID)
                // Window already open from an earlier tear-off: its view won't reappear, so front it here.
                if let window = NSApp.windows.first(where: {
                    $0.identifier?.rawValue.hasPrefix(Self.tornOffID) == true && $0.isVisible
                }) { Self.present(window) }
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
