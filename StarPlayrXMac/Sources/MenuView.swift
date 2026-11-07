//
//  MenuView.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import AVKit
import StarPlayrKit

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var menu = MenuController.shared

    private var filtered: [Channel] { menu.visibleChannels }

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
                        // Paused: the bars stay, frozen where the music stopped. Before anything has
                        // played, keep their space so the window doesn't change size.
                        Group {
                            if radio.current != nil { SpectrumView(running: PlayerState.shared.barsRunning) }
                            else { Color.clear.frame(height: CGFloat(SpectrumRenderer.barHeight)) }
                        }
                        .padding(.top, -5)
                    }
                    .contentShape(Rectangle())
                    .gesture(tearOff)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { menu.shaded.toggle() })
                    // The drag and the double-click are the only way to tear off, put back and roll
                    // up with a mouse; VoiceOver and the keyboard get the same moves as actions.
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Now Playing")
                    .accessibilityHint("Drag to tear off, double-click to roll up")
                    .modifier(PanelActions())
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
                    // Big album art lies over the list or lyrics (kept underneath so the panel doesn't resize).
                    let big = bigArtURL
                    VStack(alignment: .leading, spacing: 10) {
                        // The lyrics lie over the channel list too: the list (with its search and chip rows)
                        // always sets the height, so switching list, lyrics and art never resizes the window.
                        VStack(alignment: .leading, spacing: 10) {
                            // One row: the search field on the left, the category chips (as on iOS;
                            // StarPlayrKit's ChannelGroup) scrolling sideways beside it.
                            HStack(spacing: 6.75) {
                                SearchField(text: $menu.search, placeholder: "Search")
                                    .frame(width: 168)   // half the 336pt content width
                                    .padding(.leading, -2)
                                    .padding(.trailing, 2)
                                CategoryBar(titles: ChannelGroup.groups(radio.channels), all: "All Channels",
                                            selected: $menu.category, inset: 0)
                                    .padding(.vertical, -8)   // the chips' own padding; the search field sets the row height
                                    .padding(.trailing, -12)  // the chips scroll out to the panel's right edge
                            }
                            // A group opens a second row with its own chips (Sports → NFL, NBA, …).
                            // The list gives up that row's height, so the window doesn't grow.
                            if let group = menu.category,
                               case let subs = ChannelGroup.subs(of: group, in: radio.channels), subs.count > 1 {
                                CategoryBar(titles: subs, all: "All \(group)", selected: $menu.subcategory,
                                            small: true, inset: 7)   // inset scrolls with the chips, so they still run out to the edge
                                    .padding(.vertical, -4)
                                    .padding(.horizontal, -12)  // the small chips run edge to edge of the panel
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { subRowHeight = $0 }
                                    .onDisappear { subRowHeight = 0 }
                            }
                            channelList
                        }
                        .opacity(menu.lyrics ? 0 : 1)
                        .allowsHitTesting(!menu.lyrics)
                        .accessibilityHidden(menu.lyrics)
                        .overlay(alignment: .top) {
                            if menu.lyrics { LyricsPane() }
                        }
                    }
                    .opacity(big == nil ? 1 : 0)
                    .allowsHitTesting(big == nil)
                    .accessibilityHidden(big != nil)
                    .overlay {
                        if let big { bigArt(big) }
                    }
                    // The list height at which this area is square, so the big art fills it exactly.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width - $0.size.height } action: {
                        artFitHeight = menu.listHeight + $0
                    }
                }
                footer
            }
            .padding(.top, 10)
            .frame(height: shaded ? 0 : nil, alignment: .top)
            // Clip only vertically (for shading): the channel list reaches into the 12pt window padding,
            // and a plain .clipped() cut the playing row's squircle off at the content edges.
            .mask { Rectangle().padding(.horizontal, -12) }
            .opacity(shaded ? 0 : 1)
            .allowsHitTesting(!shaded)
            .accessibilityHidden(shaded)
        }
        .padding(12)
        .frame(width: 360)   // room for the star beside the play button
        // Drag the bottom edge to make the list (and lyrics) taller or shorter.
        .overlay(alignment: .bottom) {
            if radio.isLoggedIn && !shaded {
                Color.clear
                    .frame(height: 7)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { _ in menu.resize(snap: artFitHeight) }
                        .onEnded { _ in menu.endResize() })
                    .accessibilityElement()
                    .accessibilityLabel("Resize")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = direction == .increment ? 40 : -40
                        let range = MenuController.listHeightRange
                        menu.listHeight = min(max(menu.listHeight + step, range.lowerBound), range.upperBound)
                        menu.endResize()
                    }
            }
        }
    }

    @State private var dragMouseStart: NSPoint?
    /// List height where the big album art fits its area exactly (no bands above and below); the resize snaps to it.
    @State private var artFitHeight: CGFloat?
    /// Height of the sub-chip row (Sports → NFL, …), 0 when hidden; the channel list shrinks by it.
    @State private var subRowHeight: CGFloat = 0
    /// Shared by the Channels, Lyrics and Album Art buttons' selection bubble, so it slides between them.
    @Namespace private var modeBubble

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



    /// Art and titles on top; previous, play/pause and next centred under them (as on iOS).
    /// On the right, beside both rows: the "All Stars" glass button with the channel's star under it.
    /// The controls are centred on the whole width, as if that column weren't there; only the
    /// titles make room for it.
    private var nowPlaying: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                nowPlayingRow
                    .padding(.trailing, 34)   // the column's width (28) plus the gap (6)
                controls
            }
            VStack(spacing: 2) {
                starsButton
                channelStar
                    .padding(.top, 11)   // just under the glass button
            }
        }
    }

    /// Art, channel, song and artist, and the star — the titles get the whole width beside the art.
    private var nowPlayingRow: some View {
        HStack(spacing: 10) {
            let np = radio.current.flatMap { radio.displayed($0.id) }
            let isAlbumArt = np?.image.isEmpty == false
            CachedArt(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: 64, isAlbumArt: isAlbumArt) { art, isAlbumArt in
                if let art, isAlbumArt {
                    // Fill only: square art fits exactly; non-square art is enlarged just enough to cover the tile.
                    Image(nsImage: art).resizable().scaledToFill()
                } else if let art {
                    // Channel logos must stay whole; square channel art is enlarged to fill the squircle.
                    let logo = ChannelLogo(image: art)
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
            // Load the big album art, channel logo and show art ahead, so clicking shows them at once.
            .task(id: bigArtCandidates.map(\.url)) { prefetchBigArt() }
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(radio.current.map { isAlbumArt ? "Album art, \($0.name)" : "Channel art, \($0.name)" } ?? "StarPlayrX")
            .accessibilityHint(bigArtURL == nil ? (shownArtURL != nil ? "Shows the art full size" : "Shows the channel in the list")
                               : "Switches between the album art, channel logo and show art")
            .accessibilityAction { if !PlayerState.shared.tapArt() { revealCurrent() } }
            // Click the art: always full size over the list or lyrics first (album, channel or show art).
            // While it's big, each click steps album art → channel logo → show art, as the channel has
            // them (remembered per channel); with nothing to switch to it closes the big art again.
            // With no art at all it scrolls the list to the channel as before.
            // Same pattern as the EQ bars: an empty double-tap handler first makes the single tap
            // wait out the double-click time (so a double-click on the header, roll up, doesn't
            // also fire this), then the single-tap handler runs.
            .onTapGesture(count: 2) {}
            .onTapGesture { if !PlayerState.shared.tapArt() { revealCurrent() } }

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    // A marquee like the song and artist (as on iOS), so a long channel name scrolls too.
                    MarqueeText(text: "\(ch.id) · \(ch.name)", font: .caption, secondary: true).id("\(ch.id) · \(ch.name)")
                    MarqueeText(text: np?.song ?? "", font: .headline).id(np?.song ?? "")
                    MarqueeText(text: np?.artist ?? "", font: .body).id(np?.artist ?? "")
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Channel, song and artist read as one line, then what a click does.
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(bigArtURL != nil ? "Shows the \(menu.lyrics ? "lyrics" : "channel list") again"
                               : menu.lyrics ? "Shows the channel list" : "Shows the song's lyrics")
            .accessibilityAction { PlayerState.shared.tapTitles() }
            // Click the song/artist: the lyrics take the channel list's place, and back again.
            // Over big art it first just closes the art, so the user sees which view is underneath.
            // Same pattern as the EQ bars: the empty double-tap handler first makes the single tap
            // wait out the double-click time (so a double-click on the header, roll up, doesn't
            // also toggle the lyrics).
            .onTapGesture(count: 2) {}
            .onTapGesture { PlayerState.shared.tapTitles() }
        }
    }

    /// The current channel's star (in or out of the presets), top right of the panel.
    /// Same size as the row stars; its glyph lines up with the toolbar group's first glyph.
    @ViewBuilder private var channelStar: some View {
        if let ch = radio.current {
            let starred = radio.presets.contains(ch.id)
            Button { radio.togglePreset(ch.id) } label: {
                Image(starred ? "star_on" : "star_off")
                    .renderingMode(starred ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help(starred ? "Remove from stars" : "Add to stars")
            .accessibilityLabel(starred ? "Remove \(ch.name) from stars" : "Add \(ch.name) to stars")   // as on iOS
            .padding(.top, 2)
        }
    }

    /// The Channel List, Lyrics and Album Art buttons side by side on one Liquid Glass capsule where
    /// the system has it (a grouped toolbar), bottom left of the window.
    @ViewBuilder private var glassButtons: some View {
        // The mode showing now, highlighted on its button.
        let artMode = bigArtURL != nil
        // The channel list, from the lyrics or big art.
        let list = glassButton("list.bullet", help: "Show the channel list", label: "Channels",
                               selected: !artMode && !menu.lyrics) {
            menu.bigArt = false
            menu.lyrics = false
        }
        // The lyrics in the channel list's place.
        let lyrics = glassButton("quote.bubble", help: "Show the song's lyrics", label: "Lyrics",
                                 selected: !artMode && menu.lyrics) {
            menu.bigArt = false
            menu.lyrics = true
        }
        // The art full size over the list or lyrics.
        let art = glassButton("photo", help: "Show the art full size", label: "Album Art", selected: artMode) {
            menu.bigArt = true
        }
        .disabled(shownArtURL == nil)
        // Which button is lit, so the bubble slides from one to the next when it changes.
        let mode = artMode ? 2 : (menu.lyrics ? 1 : 0)
        if #available(macOS 26.0, *) {
            HStack(spacing: 0) { list; lyrics; art }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            HStack(spacing: 0) { list; lyrics; art }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
        }

    }

    /// The "All Stars" filter star on its own Liquid Glass circle, above the channel's star.
    /// Clicking it also brings the channel list back over the lyrics or big art, so the change shows.
    @ViewBuilder private var starsButton: some View {
        let stars = Button { PlayerState.shared.tapStars() } label: {
            Image(menu.starsOnly ? "star_on" : "star_off")
                .renderingMode(menu.starsOnly ? .original : .template)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.secondary)
                .padding(7)   // same on every side, so the glass is a circle
        }
        .buttonStyle(.plain)
        .help(menu.starsOnly ? "Show every channel" : "Show only starred channels")
        .accessibilityLabel(menu.starsOnly ? "All Stars On" : "All Stars Off")
        if #available(macOS 26.0, *) {
            stars
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            stars
        }
    }

    /// One of the glass circle buttons: an SF Symbol sized like the star glyph, so the circles match.
    /// The selected one (the mode showing now) is drawn in the accent colour on a soft capsule.
    private func glassButton(_ symbol: String, help: String, label: String, selected: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background {
                    // One bubble shared by the three buttons: it slides to whichever is selected.
                    if selected {
                        Capsule().fill(Color.primary.opacity(0.12))
                            .matchedGeometryEffect(id: "modeBubble", in: modeBubble)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Previous, play/pause and next, centred on their own row under the titles (as on iOS).
    private var controls: some View {
        HStack(spacing: 36) {
            // Previous / next: StarPlayrKit's playAdjacent, the same the iOS lock screen's ⏮ ⏭ send.
            Button { radio.playAdjacent(-1) } label: {
                Image(systemName: "backward.fill").font(.system(size: 16))
            }
            .help("Previous")
            .accessibilityLabel("Previous")

            Button { radio.togglePlayPause() } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
            }
            .help(radio.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")

            Button { radio.playAdjacent(1) } label: {
                Image(systemName: "forward.fill").font(.system(size: 16))
            }
            .help("Next")
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .disabled(radio.current == nil)
        .frame(maxWidth: .infinity)
    }


    /// Single click on the now-playing art or titles: bring the current channel's row into view.
    private func revealCurrent() {
        if let id = radio.current?.id { menu.reveal(id) }
    }

    /// The art the small tile shows now (album art, show art or the channel logo), nil when there is none.
    private var shownArtURL: String? { radio.shownArtURL }

    /// The art shown full size over the list or lyrics; nil when it's off or there is no art.
    private var bigArtURL: String? { menu.bigArt ? shownArtURL : nil }

    /// Points the big art is loaded at.
    private static let bigArtSize: CGFloat = 336

    /// Every art the current channel has, so the big versions are loaded before the user opens or cycles them.
    private var bigArtCandidates: [(url: String, isLogo: Bool)] { radio.artCandidates }

    private func prefetchBigArt() {
        for art in bigArtCandidates {
            ArtCache.shared.prefetch(art.url, pixels: ArtCache.pixels(Self.bigArtSize), trimBorder: !art.isLogo)
        }
    }

    /// Full-size art, as wide as the panel's content; clicking it shows the list or lyrics again.
    private func bigArt(_ url: String) -> some View {
        let isLogo = radio.current.map { radio.shownArt($0.id) == .channel } ?? false
        return CachedArt(url: url, size: Self.bigArtSize, isAlbumArt: !isLogo) { art, _ in
            // Until the full size arrives, the small tile's bitmap stretched, so the big art appears at once.
            // Color.clear when there's neither: an empty view never runs CachedArt's .task, so nothing would load.
            if let art = ArtCache.shared.cached(url, pixels: ArtCache.pixels(Self.bigArtSize))
                ?? ArtCache.shared.cached(url, pixels: ArtCache.pixels(64)) ?? art {
                Image(nsImage: art).resizable().scaledToFit()
            } else { Color.clear }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { menu.bigArt = false }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isLogo ? "Channel art" : "Album art")
        .accessibilityHint(menu.lyrics ? "Shows the lyrics" : "Shows the channel list")
        .accessibilityAction { menu.bigArt = false }
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
                                       isPlaying: ch == radio.current && radio.isPlaying,
                                       isStarred: radio.presets.contains(ch.id))
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        // As on iOS: playing / current channel as the value, plus the selected trait.
                        .accessibilityValue(ch == radio.current && radio.isPlaying ? "Playing"
                                            : ch == radio.current ? "Current channel" : "")
                        .accessibilityAddTraits(ch == radio.current ? .isSelected : [])
                        .accessibilityHint("Plays this channel")
                        // The row is one element (its star is inside the button's label, so VoiceOver
                        // can't click it): offer the star as an action on the row instead.
                        .accessibilityAction(named: radio.presets.contains(ch.id) ? "Remove from stars" : "Add to stars") {
                            radio.togglePreset(ch.id)
                        }
                        .id(ch.id)
                        .onAppear { prefetchArt(around: index, in: list) }
                    }
                }
                // Keeps the scroll bar the same skinny width when the pointer grabs it.
                .background(SkinnyScrollers().frame(width: 0, height: 0))
            }
            // 11pt taller than the lyrics: down to where the divider above the footer used to be.
            // Shorter by the sub-chip row (and its 10pt spacing) while it shows.
            .frame(height: menu.listHeight + 11 - (subRowHeight > 0 ? subRowHeight + 10 : 0))
            // As on iOS: say why the list is empty instead of showing a blank area.
            .overlay {
                if list.isEmpty {
                    Text(menu.starsOnly && menu.search.isEmpty && menu.category == nil ? "No starred channels" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
            // The list reaches 8pt past the content area on the left (room for the playing row's squircle,
            // which sits 8pt from the window edge) and 12pt on the right (scroll bar at the window's edge).
            .padding(.leading, -8)
            .padding(.trailing, -12)
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

    /// "v1.1.8" from the bundle; Debug builds add "-dev" (StarPlayrKit's AppVersion).
    static let version = AppVersion.string

    private var footer: some View {
        HStack {
            if radio.isLoggedIn { glassButtons }
            Spacer()
            footerButtons
        }
        .overlay { WordMark().allowsHitTesting(false) }
    }

    /// AirPlay, Close and the account menu on one horizontal Liquid Glass capsule where the system
    /// has it (a grouped toolbar, like the Album Art and Lyrics one on the left).
    @ViewBuilder private var footerButtons: some View {
        let buttons = HStack(spacing: 0) {
            AirPlayButton()
                .frame(width: 28, height: 22)
                .help("AirPlay")
                .accessibilityLabel("AirPlay")
            // Close: under the menu bar it just hides the panel; torn off it closes the window.
            glassButton("xmark", help: "Close", label: "Close") { menu.hide() }
            accountMenu
        }
        if #available(macOS 26.0, *) {
            buttons
                .padding(.horizontal, 4)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            buttons
        }
    }

    /// Sign Out and Quit in a pop-up menu, as the iOS app's account menu has Sign Out.
    private var accountMenu: some View {
        Menu {
            Text("StarPlayrX \(Self.version)")
            if radio.isLoggedIn {
                Button("Sign Out", role: .destructive) { radio.signOut() }
            }
            Button("Quit StarPlayrX") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Account")
        .accessibilityLabel("Account")
    }
}

/// "StarPlayrX" centred in the footer: heavy rounded italic in a blue-violet gradient,
/// a soft glow, and a light sheen that sweeps across it every few seconds.
private struct WordMark: View {
    @State private var sweep = false

    var body: some View {
        let text = Text("StarPlayrX")
            .font(.system(size: 17, weight: .black, design: .rounded).italic())
            .kerning(0.5)
        text
            .foregroundStyle(LinearGradient(colors: [Color(red: 0.55, green: 0.80, blue: 1.0),
                                                     Color(red: 0.75, green: 0.60, blue: 1.0),
                                                     Color(red: 1.0, green: 0.55, blue: 0.85)],
                                            startPoint: .leading, endPoint: .trailing))
            .overlay {
                // The sheen: a white band sliding left to right, clipped to the letters.
                LinearGradient(colors: [.clear, .white.opacity(0.85), .clear],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 30)
                    .offset(x: sweep ? 80 : -80)
                    .mask(text)
            }
            .shadow(color: Color(red: 0.6, green: 0.6, blue: 1.0).opacity(0.7), radius: 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).delay(2).repeatForever(autoreverses: false)) {
                    sweep = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// The system AirPlay route picker (AVKit), for sending the audio to AirPlay speakers.
private struct AirPlayButton: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        return picker
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

/// Tear off, put back and roll up as VoiceOver actions on the header. The gestures that do the
/// same (drag, double-click) need a mouse, so these are the only way to get there with VoiceOver
/// or the keyboard (which also has ⌘T and ⌘R, see MenuPanel).
private struct PanelActions: ViewModifier {
    @ObservedObject private var menu = MenuController.shared
    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: menu.detached ? "Put Back Under the Menu Bar" : "Tear Off Into a Window") {
                if menu.detached { menu.hide(); menu.statusItemClicked() } else { menu.detach() }
            }
            .accessibilityAction(named: menu.shaded ? "Roll Down" : "Roll Up") { menu.shaded.toggle() }
    }
}
/// One channel row. Equatable so a now-playing update redraws only the row it changed,
/// and always two lines tall so the list never has to re-measure rows while scrolling.
private struct ChannelRow: View, Equatable {
    let channel: Channel
    let nowPlaying: NowPlaying?
    let isCurrent: Bool
    let isPlaying: Bool
    let isStarred: Bool

    var body: some View {
        HStack {
            Text(channel.id).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                .accessibilityLabel("Channel \(channel.id)")   // playing / current is the row button's value
            // Album art when the channel has it, else the channel logo, else the StarPlayrX logo.
            let albumArt = nowPlaying?.image.isEmpty == false
            CachedArt(url: (albumArt ? nowPlaying?.image : channel.imageURL) ?? "", size: 32, isAlbumArt: albumArt) { art, albumArt in
                if let art {
                    if albumArt {
                        Image(nsImage: art).resizable().scaledToFill()
                    } else {
                        // Same as the header: square channel art is enlarged to fill the squircle,
                        // on the same dark-tinted Liquid Glass tile (solid dark before macOS 26).
                        let logo = ChannelLogo(image: art, inset: 2)
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
            .accessibilityHidden(true)   // the row already says the channel, song and artist
            VStack(alignment: .leading) {
                // Same as Now Playing: text that doesn't fit scrolls instead of ending in "…".
                MarqueeText(text: channel.name, font: isCurrent ? .body.bold() : .body).id(channel.name)
                let line = nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " "
                MarqueeText(text: line, font: .caption, secondary: true).id(line)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Click the star to put the channel in the presets or take it out (the row itself plays it).
            Button { Radio.shared.togglePreset(channel.id) } label: {
                Image(isStarred ? "star_on" : "star_off")
                    .renderingMode(isStarred ? .original : .template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isStarred ? "Remove from stars" : "Add to stars")
            // Inside the row button's label, so VoiceOver reads it with the row but can't press it:
            // the row's "Add to stars" action does that.
            .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        // The squircle reaches further out on each side than the row's content (4pt from the window
        // edge, see channelList); the content itself keeps its place so the stars still line up.
        .padding(.trailing, 12)
        .padding(.leading, 8)     // half the former 16pt (12 + 4): content starts closer to the left edge

        .padding(.trailing, -6)   // stars sit close to the squircle's right edge, lined up with the header star
        // The playing channel's row sits on a Liquid Glass squircle (translucent tint before macOS 26):
        // white-based in dark mode, light gray in light mode.
        .background {
            if isPlaying {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if #available(macOS 26.0, *) {
                    Color.clear.glassEffect(.regular.tint(Self.highlight), in: shape)
                } else {
                    shape.fill(Self.highlight)
                }
                // Darkens toward the right so the blue star stands out against the highlight.
                shape.fill(LinearGradient(colors: [.clear, Self.shade],
                                          startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
        // Inset from the scroll view's edges so the squircle's corners are never clipped. The list
        // extends 8pt past the content area on the left and 12pt on the right (scroll bar at the
        // window edge), so the trailing inset is 4pt larger and the squircle ends 4pt from the
        // window edge on the right, 3pt on the left.
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .contentShape(Rectangle())
    }

    private static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0.75, alpha: 0.5)
    })

    /// Right end of the highlight's darkening gradient: 35% black in dark mode, 5% in light mode.
    private static let shade = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: 0, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.35 : 0.05)
    })
}

/// An overlay scroll bar normally fattens up the moment the pointer is over it or dragging it: a
/// thicker knob plus a visible track. The channel list's bar sits at the window's edge with no room
/// for that, so this one keeps the resting width and draws the same knob whether or not it's grabbed.
final class SkinnyScroller: NSScroller {
    private static let barWidth: CGFloat = 11      // stays skinny: a wider bar would push the knob inward
    private static let knobWidth: CGFloat = 5
    private static let knobInset: CGFloat = 2      // keeps the knob's ends off the bar's ends
    private static let edgeMargin: CGFloat = 3     // gap between the knob and the window's edge

    /// AppKit asks the class how wide to be, for the expanded state too, so one answer covers both.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { barWidth }

    /// Without this AppKit won't give a custom subclass the overlay (fades away) behaviour.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    /// The track is only drawn in the expanded state; skipping it is what keeps a grabbed bar skinny.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    /// Our own capsule. Its x comes from the scroller's own right edge, never from AppKit's knob rect:
    /// that rect gets inset in the expanded (grabbed) state, which is what walked the knob inward.
    override func drawKnob() {
        let knob = rect(for: .knob)
        let capsule = NSRect(x: bounds.maxX - Self.edgeMargin - Self.knobWidth,
                             y: knob.minY + Self.knobInset,
                             width: Self.knobWidth,
                             height: max(knob.height - Self.knobInset * 2, Self.knobWidth))
        (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.35) : NSColor(white: 0, alpha: 0.35)).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: Self.knobWidth / 2, yRadius: Self.knobWidth / 2).fill()
    }

}

/// Puts a `SkinnyScroller` on the NSScrollView SwiftUI makes for the channel list. Lives inside the
/// `ScrollView`'s content, which is where `enclosingScrollView` can reach it, and re-applies itself
/// if SwiftUI ever rebuilds the scroll view (the scroller it made would be AppKit's again).
struct SkinnyScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true   // nothing to draw and nothing to click: it's only here to find the scroll view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Next pass of the run loop: during `updateNSView` the view isn't in the hierarchy yet.
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView,
                  !(scrollView.verticalScroller is SkinnyScroller) else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller = SkinnyScroller()
            scrollView.hasVerticalScroller = true
        }
    }
}
