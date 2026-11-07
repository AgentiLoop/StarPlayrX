//
//  ContentView.swift
//  StarPlayrX (iOS / iPadOS)
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The iOS take on the Mac's menu panel (MenuView): now playing on top, then the channel list
//  or the lyrics. Sign-in comes first when there is no saved account.
//

import SwiftUI
import AVKit
import StarPlayrKit

struct ContentView: View {
    @EnvironmentObject var radio: Radio

    var body: some View {
        if radio.isLoggedIn { PlayerView() } else { SignInView() }
    }
}

// MARK: Sign in

struct SignInView: View {
    @EnvironmentObject var radio: Radio
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or email", text: $user, prompt: Text("Username or email").foregroundStyle(Color.primary), axis: .vertical)
                        .lineLimit(1...3)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $pass, prompt: Text("Password").foregroundStyle(Color.primary))
                        .textContentType(.password)
                        .onSubmit(signIn)
                    Toggle("Canada", isOn: Binding(get: { radio.localeIsCA }, set: { radio.setRegion(ca: $0) }))
                } header: {
                    Text("Sign in with your SiriusXM account")
                        .foregroundStyle(Color.primary)
                } footer: {
                    Text("Your username and password are kept only in this device's Keychain.")
                        .foregroundStyle(Color.primary)
                }
                Section {
                    // Not .disabled: its dimmed text fails contrast. signIn() ignores taps until ready.
                    Button(action: signIn) {
                        HStack {
                            Text(radio.isBusy ? "Signing in…" : "Sign In").foregroundStyle(Color.primary)
                            if radio.isBusy { Spacer(); ProgressView() }
                        }
                    }
                } footer: {
                    Text(radio.status)
                        .foregroundStyle(Color.primary)
                }
            }
            .navigationTitle("StarPlayrX")
            // Once, not on every init of this view (each Radio change re-creates it).
            .task { if user.isEmpty { user = Keychain.load()?.user ?? "" } }
        }
    }

    private func signIn() {
        guard !radio.isBusy, !user.isEmpty, !pass.isEmpty else { return }
        Task { _ = await radio.login(user: user, pass: pass) }
    }
}

// MARK: Player

struct PlayerView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = PlayerState.shared
    /// Regular width is the iPad and iPhone Duo's inner display; compact is every other iPhone and
    /// the Duo's outer display. The Duo changes it mid-session when it folds, so the layout follows
    /// the size class, never the idiom, the orientation or the screen.
    @Environment(\.horizontalSizeClass) private var hSize
    /// Compact height is a short, wide window: the Duo's top half when the app has only that
    /// (laptop pose), or a phone on its side. There's no room for a list under now playing, so
    /// it's just the player — the Mac panel rolled up to its window shade.
    @Environment(\.verticalSizeClass) private var vSize

    private var shaded: Bool { vSize == .compact }
    /// The wide layout with now playing and the list side by side (set from its geometry).
    @State private var sideBySide = false

    var body: some View {
        NavigationStack {
            Group {
                if shaded { shade } else if hSize == .regular { wide } else { narrow }
            }
            // No title anywhere: with the toolbar items down the side (iPhone Duo) the top bar is
            // then empty and collapses, so the content gets its height. Other iPhones keep the bar
            // for its buttons.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In the shade the bar items would be stacked down the camera's side (whichever
                // side that is), so there they're drawn along the bottom of the content instead.
                if !shaded {
                    ToolbarItem(placement: .topBarLeading) { accountMenu }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        AirPlayButton()
                        // Side by side the list is always showing, so the pane beside it
                        // switches between the art and the lyrics instead, and the star stays.
                        let pane = sideBySide && hSize == .regular
                        // Label, not a bare Image: on iOS 26 a bare image's tap region is just the
                        // glyph, though the whole glass pill lights up — taps on the pill's edge
                        // did nothing. A Label's region is the pill.
                        if !app.lyrics || pane {
                            Button { app.starsOnly.toggle() } label: {
                                Label(app.starsOnly ? "All Stars On" : "All Stars Off",
                                      systemImage: app.starsOnly ? "star.fill" : "star")
                            }
                        }
                        // One Label, not an
                        // if/else of two: the toolbar only gives a bare Label the whole glass pill
                        // as its tap region; wrapped in a condition only the glyph took taps.
                        Button { app.bigArt = false; app.lyrics.toggle() } label: {
                            Label(app.lyrics ? (pane ? "Art" : "Channels") : "Lyrics",
                                  systemImage: app.lyrics ? (pane ? "photo" : "list.bullet") : "quote.bubble")
                        }
                    }
                }
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            Text("StarPlayrX \(AppVersion.string)")
            Button("Sign Out", role: .destructive) { radio.signOut() }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account")
    }

    /// The window shade: the art filling the height on the left, the titles, controls and EQ
    /// laid out beside it, and the account and AirPlay buttons along the bottom edge. The Duo's
    /// laptop pose shows no status bar in this half, so the clock and date sit up in the bar's place.
    private var shade: some View {
        // The camera's side carries a safe-area inset along its whole edge, though the camera is
        // in one corner. The now-playing block spans the full width regardless; only the button
        // row keeps the inset, so a button never lands on the camera.
        GeometryReader { geo in
            // The header's art fills whatever height it gets, so it's handed a share of the
            // shade; the slack goes above and below it — centred between the clock and the buttons.
            NowPlayingHeader(spread: true)
                .frame(height: geo.size.height * 0.66)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 64)
                .padding(.bottom, 56)
                // The clock, drawn in the content and centred on the whole screen: a toolbar item
                // would be centred on the bar, which stops short of the camera's side.
                .overlay(alignment: .top) {
                    TimelineView(.everyMinute) { context in
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(context.date, format: .dateTime.hour().minute())
                                .font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                .font(.system(size: 26, weight: .regular, design: .rounded)).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, 14)
                }
                // "All Stars" in the top-right corner itself: the camera's corner is bottom-right or
                // top-left, so no inset here. With it on, ⏮ ⏭ skip through the starred channels only.
                .overlay(alignment: .topTrailing) {
                    Button { app.starsOnly.toggle() } label: {
                        Image(systemName: app.starsOnly ? "star.fill" : "star")
                    }
                    .accessibilityLabel(app.starsOnly ? "All Stars On" : "All Stars Off")
                    .font(.title2)
                    .glassButtons()
                    .padding(.trailing, 18)
                    .padding(.top, 18)
                }
                // Drawn in the content, not the toolbar (the bar would stack them down the camera's
                // side), so they need the toolbar's Liquid Glass look given by hand, 18 pt in from
                // the edges. Account bottom-left; AirPlay in whichever of the other two corners the
                // camera isn't: top-left when the camera is bottom-right (trailing inset), opposite
                // the star, and bottom-right when the camera is top-left.
                .overlay(alignment: .bottomLeading) {
                    accountMenu
                        .font(.title2)
                        .glassButtons()
                        .padding(.leading, 18)
                        .padding(.bottom, 18)
                }
                .overlay(alignment: geo.safeAreaInsets.trailing > geo.safeAreaInsets.leading ? .topLeading : .bottomTrailing) {
                    AirPlayButton()
                        .font(.title2)
                        .glassButtons()
                        .padding(.horizontal, 18)
                        .padding(.vertical, 18)
                }
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .toolbar(.hidden, for: .navigationBar)
    }




    /// Phones (and the Duo closed): now playing on top, then the channel list or the lyrics.
    private var narrow: some View {
        GeometryReader { geo in
            // iPhone Duo's outer display has the status bar and toolbar down the right edge (a wide
            // trailing inset) with dead space under them: the EQ goes there, on its side, centred.
            // Other iPhones (no inset) keep it under the controls as before.
            let side = geo.safeAreaInsets.trailing
            let sideEQ = side >= 44
            VStack(spacing: 0) {
                NowPlayingHeader(showsBars: !sideEQ)
                    .padding(.horizontal)
                    // The Duo's empty top bar (its buttons are down the side) leaves a ~25 pt
                    // inset; that goes, so the art starts 15 pt down — about the side padding.
                    // Other phones: 8, right under the toolbar, so the list gets more of the screen.
                    .padding(.top, sideEQ ? 15 : 8)
                    // The search field's own 8 above it makes 12 under the bars; no divider.
                    .padding(.bottom, 4)
                // Big art lies over the list or lyrics, as on the Mac.
                if app.bigArt, let url = radio.shownArtURL { BigArtView(url: url) }
                // The search and chips on one row, as on the Duo.
                else if app.lyrics { LyricsView() } else { ChannelList(inlineFilters: true) }
            }
            .ignoresSafeArea(.container, edges: sideEQ ? .top : [])
            .overlay(alignment: .bottomTrailing) {
                if sideEQ, radio.current != nil {
                    // Turned clockwise: the first (heaviest) bars at the top, each bar growing
                    // from the strip's left edge to the right. Half the height less two points per
                    // bar (the bars share the length, 2 pt apart), so each bar is 2 pt narrower;
                    // dropped halfway through the bottom safe-area inset, so it ends just short of
                    // the screen's rounded corner.
                    let length = geo.size.height * 0.5 - 2 * CGFloat(Visualizer.bandCount)
                    SpectrumBars(running: app.barsRunning)
                        .frame(width: length)
                        .rotationEffect(.degrees(90))
                        .frame(width: CGFloat(SpectrumRenderer.barHeight), height: length)
                        .frame(width: side)
                        .offset(x: side, y: geo.safeAreaInsets.bottom / 2)
                }
            }
        }
    }

    /// iPad and the Duo open: now playing with the art or the lyrics under it, and the channel
    /// list beside it. Taller than wide (the Duo set down like a laptop, its hinge across the
    /// middle) now playing takes the top half and the list the bottom half, so neither straddles
    /// the fold. Sized from the space the app has, not the screen.
    private var wide: some View {
        GeometryReader { geo in
            if geo.size.height > geo.size.width {
                // The art sets the now-playing section's height (10% under the width it could have),
                // so the search field and chips sit right under it, and the slack is left over the
                // fold rather than pushing them onto it.
                let art = (geo.size.width - 32) * 0.42 * 0.9
                // The fold is halfway down the whole window; this view starts under the navigation
                // bar, so the top half is that much shorter — the bottom half then begins at the fold.
                let fold = (geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom) / 2
                    - geo.safeAreaInsets.top
                VStack(spacing: 0) {
                    // Top half: now playing, then the search field and chips. The list or art fill
                    // the bottom half, so nothing straddles the fold. The lyrics have nothing above
                    // the fold to wait for, so they start right under now playing.
                    VStack(spacing: 0) {
                        NowPlayingHeader(spread: true)
                            .padding(.horizontal)
                            .padding(.vertical, 10)
                            .frame(height: art + 20)
                        // Right under now playing; the slack is left above the fold.
                        if !app.lyrics && !app.bigArt { ChannelFilters(keepSubRow: true, inline: true) }
                        Spacer(minLength: 0)
                        // The slack over the fold names what the list below shows.
                        if !app.lyrics && !app.bigArt { channelsHeader }
                    }
                    .frame(height: app.lyrics && !app.bigArt ? art + 20 : fold)
                    Divider()
                    if app.bigArt, let url = radio.shownArtURL { BigArtView(url: url) }
                    else if app.lyrics { LyricsView() } else { ChannelList(filters: false) }
                }
            } else {
                // Side by side, split down the middle: the fold is halfway across the whole window,
                // and this view is inset by the status bar and toolbar along the right edge, so the
                // left pane is that much less than half — the divider then lies on the fold.
                let fold = (geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing) / 2
                    - geo.safeAreaInsets.leading
                HStack(spacing: 0) {
                    nowPlayingPane.frame(width: fold)
                    Divider()
                    ChannelList(inlineFilters: true)
                }
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.size.width >= geo.size.height, initial: true) { sideBySide = $1 }
        })
    }

    /// "Rock" / "Starred" / "All Channels" and how many channels the list holds, over the list.
    private var channelsHeader: some View {
        let title = app.subcategory ?? app.category ?? (app.starsOnly ? "Starred" : "All Channels")
        let count = app.visibleChannels.count
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(.largeTitle.weight(.semibold))
            Spacer()
            Text("\(count) channel\(count == 1 ? "" : "s")").font(.title3).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var nowPlayingPane: some View {
        VStack(spacing: 0) {
            NowPlayingHeader()
                .padding(.horizontal)
                .padding(.vertical, 10)
            Divider()
            if app.bigArt, let url = radio.shownArtURL { BigArtView(url: url) }
            else if app.lyrics { LyricsView() }
            // With the list in its own pane there's nothing for the art to hide, so it's
            // always full size here.
            else if let url = radio.shownArtURL { BigArtView(url: url) }
            else { Spacer() }
        }
    }
}

/// Art, channel, song and artist, play/pause and the star, with the equalizer under them —
/// the Mac panel's header.
struct NowPlayingHeader: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = PlayerState.shared
    /// The Duo's top half (wide and short): the art fills the height on the left, and the titles,
    /// controls and EQ stack beside it. Off, everything sits in three rows, as on a phone.
    var spread = false
    /// Off, the EQ bars are left out (the Duo's outer display draws them down its side strip).
    var showsBars = true

    var body: some View {
        if spread { wide } else { stacked }
    }

    private var stacked: some View {
        VStack(spacing: 0) {
            row
            controls().padding(.top, 6)
            // The bars grow up from the bottom of their 48 pt strip, so the strip's own headroom
            // is the air under the controls; no spacing on top of it.
            if showsBars { bars }
        }
    }

    /// Big art on the left; on the right the titles up top, the controls in the middle and the
    /// EQ along the bottom edge — a landscape now-playing screen.
    private var wide: some View {
        GeometryReader { geo in
            // The art fills the height (the Duo's laptop layout hands in the height it wants,
            // PlayerView.wide); in a wide window it's capped so the titles keep enough room.
            let size = min(geo.size.height, geo.size.width * 0.5)
            HStack(alignment: .top, spacing: 32) {
                art(size: size, cornerRadius: size / 5)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
                // The column takes all the width left and the art's height, so the titles,
                // controls and bars spread over the whole space beside it.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        titles(large: true)
                        star
                    }
                    Spacer(minLength: 8)
                    controls(large: true)
                    Spacer(minLength: 8)
                    bars.frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
                .frame(height: size)
            }
            // Centred in the space, as a player screen.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    /// Same bars as the Mac; before anything has played, keep their space so nothing jumps.
    @ViewBuilder private var bars: some View {
        if radio.current != nil { SpectrumBars(running: app.barsRunning) }
        else { Color.clear.frame(height: CGFloat(SpectrumRenderer.barHeight)) }
    }

    /// Art, channel, song and artist, and the star — the titles get the whole width beside the art.
    private var row: some View {
        HStack(spacing: 12) {
            art(size: 72, cornerRadius: 16)
            titles(large: false)
            star
        }
    }

    private func art(size: CGFloat, cornerRadius: CGFloat) -> some View {
        let np = radio.current.flatMap { radio.displayed($0.id) }
        let isAlbumArt = np?.image.isEmpty == false
        return ArtTile(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: size,
                       isAlbumArt: isAlbumArt, cornerRadius: cornerRadius)
            // Tap the art: full size first; while it's big, album art → channel logo → show art,
            // and with nothing to switch to it closes again (as on the Mac). The tile is the tap
            // region (not the image, which may be scaled past it or not loaded yet).
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onTapGesture { app.tapArt() }
            .task(id: radio.artCandidates.map(\.url)) {
                for art in radio.artCandidates {
                    ArtCache.shared.prefetch(art.url, pixels: ArtCache.pixels(BigArtView.size), trimBorder: !art.isLogo)
                }
            }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(radio.current.map { isAlbumArt ? "Album art, \($0.name)" : "Channel art, \($0.name)" } ?? "StarPlayrX")
            .accessibilityHint(app.bigArt ? "Switches between the album art, channel logo and show art"
                                          : "Shows the art full size")
            .accessibilityAction { app.tapArt() }
    }

    /// Channel, song and artist; `large` is the Duo's top half, where there's room for bigger type.
    private func titles(large: Bool) -> some View {
        let np = radio.current.flatMap { radio.displayed($0.id) }
        return VStack(alignment: .leading, spacing: large ? 4 : 2) {
            if let ch = radio.current {
                MarqueeText(text: "\(ch.id) · \(ch.name)", font: large ? .headline : .caption, secondary: true).id("\(ch.id) · \(ch.name)")
                MarqueeText(text: np?.song ?? "", font: large ? .title.bold() : .headline).id(np?.song ?? "")
                MarqueeText(text: np?.artist ?? "", font: large ? .title2 : .subheadline).id(np?.artist ?? "")
            } else {
                Text("Pick a channel").font(large ? .title.bold() : .headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Tap the song/artist: the lyrics take the channel list's place, and back again.
        // Over big art it first just closes the art.
        .onTapGesture { app.tapTitles() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(app.bigArt ? "Shows the \(app.lyrics ? "lyrics" : "channel list") again"
                           : app.lyrics ? "Shows the channel list" : "Shows the song's lyrics")
        .accessibilityAction { app.tapTitles() }
    }

    @ViewBuilder private var star: some View {
        if let ch = radio.current {
            StarButton(isStarred: radio.presets.contains(ch.id), channel: ch.name) { radio.togglePreset(ch.id) }
        }
    }

    /// Previous, play/pause and next, centred on their own row under the titles; `large` is the
    /// wide layout, where they get the room of a full player screen.
    private func controls(large: Bool = false) -> some View {
        HStack(spacing: large ? 56 : 44) {
            // Previous / next: the same playAdjacent the lock screen's ⏮ ⏭ send (RadioSession.swift).
            Button { radio.playAdjacent(-1) } label: {
                Image(systemName: "backward.fill").font(.system(size: large ? 30 : 22))
            }
            .accessibilityLabel("Previous")

            Button { radio.togglePlayPause() } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: large ? 64 : 44))
            }
            .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")

            Button { radio.playAdjacent(1) } label: {
                Image(systemName: "forward.fill").font(.system(size: large ? 30 : 22))
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .disabled(radio.current == nil)
        .frame(maxWidth: .infinity)
    }
}

/// The current art full size in the list's place; tapping it shows the list or lyrics again.
struct BigArtView: View {
    static let size: CGFloat = 600
    @EnvironmentObject var radio: Radio
    let url: String

    var body: some View {
        let isLogo = radio.current.map { radio.shownArt($0.id) == .channel } ?? false
        CachedArt(url: url, size: Self.size, isAlbumArt: !isLogo) { art, _ in
            // Until the full size arrives, the header's bitmap stretched, so the big art appears at once.
            if let art = ArtCache.shared.cached(url, pixels: ArtCache.pixels(Self.size))
                ?? ArtCache.shared.cached(url, pixels: ArtCache.pixels(72)) ?? art {
                Image(platformImage: art).resizable().scaledToFit()
            } else { Color.clear }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { PlayerState.shared.bigArt = false }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isLogo ? "Channel art" : "Album art")
        .accessibilityHint(PlayerState.shared.lyrics ? "Shows the lyrics" : "Shows the channel list")
        .accessibilityAction { PlayerState.shared.bigArt = false }
    }
}

/// AirPlay / Bluetooth / speaker picker.
/// AirPlay / Bluetooth / speaker picker as a plain toolbar button, so the system lays it out with
/// the other items (under the status bar on iPhone Duo's side bar) rather than keeping a raw
/// AVRoutePickerView in the top bar. The picker view sits in the hierarchy, out of sight, and
/// its own button is pressed for it.
struct AirPlayButton: View {
    @State private var picker = AVRoutePickerView()

    var body: some View {
        Button {
            (picker.subviews.first { $0 is UIButton } as? UIControl)?.sendActions(for: .touchUpInside)
        } label: {
            Image(systemName: "airplay.audio")
        }
        .accessibilityLabel("AirPlay")
        .background(RoutePickerHost(picker: picker).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false))
    }
}

extension View {
    /// The toolbar's round Liquid Glass buttons, for buttons drawn in the content (iOS 26 and up;
    /// plain bordered circles before).
    @ViewBuilder func glassButtons() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large)
        }
    }
}

struct RoutePickerHost: UIViewRepresentable {
    let picker: AVRoutePickerView

    func makeUIView(context: Context) -> AVRoutePickerView {
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Channel art in a squircle: album art fills it, a logo sits whole on a dark tile.
struct ArtTile: View {
    let url: String
    let size: CGFloat
    var isAlbumArt = false
    var cornerRadius: CGFloat = 8

    var body: some View {
        CachedArt(url: url, size: size, isAlbumArt: isAlbumArt) { art, isAlbumArt in
            if let art, isAlbumArt {
                Image(platformImage: art).resizable().scaledToFill()
            } else if let art {
                ChannelLogo(image: art, inset: size / 16)
                    .frame(width: size, height: size)
                    .background(Color(white: 0.12))
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: size / 2.5))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(white: 0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct StarButton: View {
    let isStarred: Bool
    /// Named in the VoiceOver label, so a star is never just "Add to stars" without saying which channel.
    let channel: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isStarred ? "Remove \(channel) from stars" : "Add \(channel) to stars")
    }
}

// MARK: Channels

struct ChannelList: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = PlayerState.shared
    @Environment(\.colorScheme) private var scheme
    /// The search field and chips over the list; off when the layout puts them elsewhere
    /// (the Duo's top half).
    var filters = true
    /// The search field and main chips on one row (ChannelFilters.inline).
    var inlineFilters = false

    var body: some View {
        let list = app.visibleChannels
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                if filters { ChannelFilters(inline: inlineFilters) }
                List(list) { ch in
                    let isPlaying = ch == radio.current && radio.isPlaying
                    Button { radio.play(ch) } label: {
                        ChannelRow(channel: ch, nowPlaying: radio.displayed(ch.id), isCurrent: ch == radio.current)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isPlaying ? "Playing" : ch == radio.current ? "Current channel" : "")
                    .accessibilityAddTraits(ch == radio.current ? .isSelected : [])
                    .accessibilityHint("Plays this channel")
                    // The star is its own element too; as a row action it's one swipe away without leaving the row.
                    .accessibilityAction(named: radio.presets.contains(ch.id) ? "Remove from stars" : "Add to stars") {
                        radio.togglePreset(ch.id)
                    }
                    .overlay(alignment: .trailing) {
                        StarButton(isStarred: radio.presets.contains(ch.id), channel: ch.name) { radio.togglePreset(ch.id) }
                    }
                    // The playing channel's row sits on a Liquid Glass squircle (a translucent tint
                    // before iOS 26), as on the Mac: white-based in dark mode, light gray in light
                    // mode, darkening toward the star so the blue stands out. No separators.
                    .listRowBackground(Group {
                        if isPlaying {
                            let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                            let highlight = scheme == .dark ? Color(white: 1, opacity: 0.10) : Color(white: 0.75, opacity: 0.5)
                            ZStack {
                                if #available(iOS 26.0, *) {
                                    Color.clear.glassEffect(.regular.tint(highlight), in: shape)
                                } else {
                                    shape.fill(highlight)
                                }
                                shape.fill(LinearGradient(colors: [.clear, Color(white: 0, opacity: scheme == .dark ? 0.35 : 0.05)],
                                                          startPoint: .leading, endPoint: .trailing))
                            }
                            .padding(.horizontal, 8)
                        }
                    })
                    .listRowSeparator(.hidden)
                    // 7 pt less than the default 11 above and below: more channels on screen.
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .id(ch.id)
                }
                .listStyle(.plain)
                .scrollDismissesKeyboard(.immediately)
                .overlay {
                    if list.isEmpty {
                        Text(app.starsOnly && app.search.isEmpty && app.category == nil ? "No starred channels" : "No matches")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// The search field and the category chips, normally over the list; they stay put while it scrolls.
struct ChannelFilters: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = PlayerState.shared
    /// Keep the second row's space when there are no sub-chips (All Channels), so the layout
    /// above and below it never moves — the Duo's top half.
    var keepSubRow = false
    /// The search field and the main chips share one row (the Duo open, side by side: the list
    /// pane has the width, and every row it saves is another channel on screen).
    var inline = false

    var body: some View {
        VStack(spacing: 0) {
            let groups = CategoryBar(titles: ChannelGroup.groups(radio.channels), all: "All Channels", selected: $app.category,
                                     inset: inline ? 0 : 16)
            if inline {
                // The search field takes the left half, the chips the right.
                HStack(spacing: 0) {
                    SearchField(text: $app.search, prompt: "Search")
                        // Half the usual 16 from the screen edge: the field gets 8 pt more width.
                        .padding(.leading, 8)
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity)
                    groups
                        .frame(maxWidth: .infinity)
                }
                // With the chip bar's own 8: 10 above the chips, matching the 10 under the sub-chips.
                .padding(.top, 2)
            } else {
                // Under the header's EQ bars, over the chips.
                SearchField(text: $app.search, prompt: "Search channels, artists, songs")
                    .padding(.horizontal)
                    .padding(.top, 8)
                // The category chips (StarPlayrKit's ChannelGroup).
                groups
            }
            // Picking a group opens a second row with its detailed chips (Sports → NFL, NBA, …).
            if let group = app.category, case let subs = ChannelGroup.subs(of: group, in: radio.channels), subs.count > 1 {
                CategoryBar(titles: subs, all: "All \(group)", selected: $app.subcategory, small: true)
                    // With the bar's own 4: 10 under the sub-chips inline, the same as above the
                    // main ones; 7 on a phone, a little air over the list.
                    .padding(.bottom, inline ? 6 : 3)
            } else if keepSubRow {
                // An empty, invisible row of the same height holds the place.
                CategoryBar(titles: [], all: "All Channels", selected: .constant(nil), small: true).hidden()
            }
        }
    }
}

/// The search bar in the list's own column (`.searchable` would put it in the navigation bar,
/// above the now-playing header).
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .focused($focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { focused = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// One channel: number, art, name, and what it's playing.
struct ChannelRow: View, Equatable {
    let channel: Channel
    let nowPlaying: NowPlaying?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(channel.id).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 40, alignment: .trailing)
                .accessibilityLabel("Channel \(channel.id)")
            let albumArt = nowPlaying?.image.isEmpty == false
            ArtTile(url: (albumArt ? nowPlaying?.image : channel.imageURL) ?? "", size: 44, isAlbumArt: albumArt)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: channel.name, font: isCurrent ? .body.bold() : .body).id(channel.name)
                let line = nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " "
                MarqueeText(text: line, font: .caption, secondary: true).id(line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Room for the star laid over the row's end.
            Color.clear.frame(width: 28, height: 1)
        }
        .contentShape(Rectangle())
    }
}
