//
//  MenuView.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI

extension Channel {
    /// The search field's matching: number, name, category, "Music Xtra", artist and song.
    /// With `stars` the list is only those channels first (the "All Stars" filter).
    static func filter(_ channels: [Channel], nowPlaying: [String: NowPlaying], search: String, stars: Set<String>? = nil) -> [Channel] {
        let channels = stars.map { stars in channels.filter { stars.contains($0.id) } } ?? channels
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
        Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: menu.search,
                       stars: menu.starsOnly ? radio.presets : nil)
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
                    HStack(spacing: 6) {
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
                        // Same size and trailing edge as the row stars: a row's star ends 10pt from the
                        // content edge (16 outer trailing − 12 list overhang + 4 + 2 inner padding).
                        .padding(.trailing, 10)
                        .help(menu.starsOnly ? "Show every channel" : "Show only starred channels")
                        .accessibilityLabel(menu.starsOnly ? "All Stars On" : "All Stars Off")
                    }
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
        .frame(width: 360)   // room for the star beside the play button
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
            // The star (as the iOS "All Star" button): the current channel in or out of the presets.
            // Outside the play button, same size and trailing edge as the search-bar and row stars.
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
                .padding(.trailing, 10)
                .help(starred ? "Remove from stars" : "Add to stars")
                .accessibilityLabel(starred ? "Preset On, Channel \(ch.name)" : "Preset Off")
            }
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
                                       isPlaying: ch == radio.current && radio.isPlaying,
                                       isStarred: radio.presets.contains(ch.id))
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .id(ch.id)
                        .onAppear { prefetchArt(around: index, in: list) }
                    }
                }
            }
            .frame(height: CachedArt<EmptyView>.listHeight)
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
            // Torn off: Close sits left-most, like a window's close control.
            if menu.detached {
                Button("Close") { menu.hide() }
            }
            Text(Self.version).font(.caption).foregroundStyle(.tertiary).offset(y: 2)
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
    let isStarred: Bool

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
        // The squircle reaches 8pt further out on each side than the row's content (8pt from the window
        // edge, see channelList); the content itself keeps its place so the stars still line up.
        .padding(.horizontal, 12)
        .padding(.trailing, 2)   // a little more room between the star and the squircle's edge
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
            }
        }
        // Inset from the scroll view's edges so the squircle's corners are never clipped. The list
        // extends 8pt past the content area on the left and 12pt on the right (scroll bar at the
        // window edge), so the squircle ends 8pt from the window edge on both sides.
        .padding(.leading, 4)
        .padding(.trailing, 8)
        // so the trailing inset has to cover that plus the same 4pt margin as the leading side.
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
    }

    private static let highlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.10)
            : NSColor(white: 0.75, alpha: 0.5)
    })
}
