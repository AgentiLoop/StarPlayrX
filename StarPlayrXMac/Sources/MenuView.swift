//
//  MenuView.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
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
                        if menu.lyrics {
                            LyricsPane()
                        } else {
                            HStack(spacing: 13.5) {
                                SearchField(text: $menu.search, placeholder: "Search channels, artists, songs")
                                // "All Stars" (as on iOS): the list shows only the starred channels.
                                Button { menu.starsOnly.toggle() } label: {
                                    Image(menu.starsOnly ? "star_on" : "star_off")
                                        .renderingMode(menu.starsOnly ? .original : .template)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 16, height: 16)
                                        .foregroundStyle(Color.secondary)
                                }
                                .buttonStyle(.plain)
                                // Same size and trailing edge as the row stars: a row's star ends 2pt inside the
                                // content edge (12 outer trailing − 12 list overhang + 12 − 10 inner padding).
                                .padding(.trailing, 2)
                                .help(menu.starsOnly ? "Show every channel" : "Show only starred channels")
                                .accessibilityLabel(menu.starsOnly ? "All Stars On" : "All Stars Off")
                            }
                            // Category chips, as on iOS (StarPlayrKit's ChannelGroup); a group opens
                            // a second row with its own chips (Sports → NFL, NBA, …).
                            VStack(alignment: .leading, spacing: 0) {
                                CategoryBar(titles: ChannelGroup.groups(radio.channels), all: "All Channels",
                                            selected: $menu.category, inset: 0)
                                if let group = menu.category,
                                   case let subs = ChannelGroup.subs(of: group, in: radio.channels), subs.count > 1 {
                                    CategoryBar(titles: subs, all: "All \(group)", selected: $menu.subcategory,
                                                small: true, inset: 0)
                                }
                            }
                            .padding(.vertical, -6)
                            channelList
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
                Divider()
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



    /// Art, titles and star on top; previous, play/pause and next centred under them (as on iOS).
    private var nowPlaying: some View {
        VStack(spacing: 6) {
            nowPlayingRow
            controls
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
            // Click the song/artist: the lyrics take the channel list's place, and back again.
            // Over big art it first just closes the art, so the user sees which view is underneath.
            // Same pattern as the EQ bars: the empty double-tap handler first makes the single tap
            // wait out the double-click time (so a double-click on the header, roll up, doesn't
            // also toggle the lyrics).
            .onTapGesture(count: 2) {}
            .onTapGesture { PlayerState.shared.tapTitles() }
            // The star (as the iOS "All Star" button): the current channel in or out of the presets.
            // Same size and trailing edge as the search-bar and row stars.
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
                .padding(.trailing, 2)
                .help(starred ? "Remove from stars" : "Add to stars")
                .accessibilityLabel(starred ? "Preset On, Channel \(ch.name)" : "Preset Off, Channel \(ch.name)")
            }
        }
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
            .frame(height: menu.listHeight)
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
            Text(Self.version).font(.caption).foregroundStyle(.tertiary).offset(y: 2)
                .accessibilityLabel("Version \(Self.version.dropFirst())")
            Spacer()
            // Close: under the menu bar it just hides the panel; torn off it closes the window.
            Button("Close") { menu.hide() }
            if radio.isLoggedIn {
                Button("Sign Out") { radio.signOut() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
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
                .accessibilityLabel("Channel \(channel.id)" + (isPlaying ? ", playing" : isCurrent ? ", current channel" : ""))
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
            .accessibilityLabel(isStarred ? "Preset On, Channel \(channel.name)" : "Preset Off, Channel \(channel.name)")
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
        // window edge on both sides (half the former 8pt).
        .padding(.leading, 4)
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
