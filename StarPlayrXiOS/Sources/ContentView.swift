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
    @State private var user = Keychain.load()?.user ?? ""
    @State private var pass = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or email", text: $user)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $pass)
                        .textContentType(.password)
                        .onSubmit(signIn)
                    Toggle("Canada", isOn: Binding(get: { radio.localeIsCA }, set: { radio.setRegion(ca: $0) }))
                } header: {
                    Text("Sign in with your SiriusXM account")
                } footer: {
                    Text("Your username and password are kept only in this device's Keychain.")
                }
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text(radio.isBusy ? "Signing in…" : "Sign In")
                            if radio.isBusy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(radio.isBusy || user.isEmpty || pass.isEmpty)
                } footer: {
                    Text(radio.status)
                }
            }
            .navigationTitle("StarPlayrX")
        }
    }

    private func signIn() {
        guard !user.isEmpty, !pass.isEmpty else { return }
        Task { _ = await radio.login(user: user, pass: pass) }
    }
}

// MARK: Player

struct PlayerView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = AppState.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NowPlayingHeader()
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                Divider()
                // Big art lies over the list or lyrics, as on the Mac.
                if app.bigArt, let url = radio.shownArtURL { BigArtView(url: url) }
                else if app.lyrics { LyricsView() } else { ChannelList() }
            }
            .navigationTitle(app.lyrics ? "Lyrics" : "Channels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Text("StarPlayrX \(AppVersion.string)")
                        Button("Sign Out", role: .destructive) { radio.signOut() }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    AirPlayButton().frame(width: 28, height: 28)
                    if !app.lyrics {
                        Button { app.starsOnly.toggle() } label: {
                            Image(systemName: app.starsOnly ? "star.fill" : "star")
                        }
                        .accessibilityLabel(app.starsOnly ? "All Stars On" : "All Stars Off")
                    }
                    Button { app.bigArt = false; app.lyrics.toggle() } label: {
                        Image(systemName: app.lyrics ? "list.bullet" : "quote.bubble")
                    }
                    .accessibilityLabel(app.lyrics ? "Channels" : "Lyrics")
                }
            }
        }
    }
}

/// Art, channel, song and artist, play/pause and the star, with the equalizer under them —
/// the Mac panel's header.
struct NowPlayingHeader: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = AppState.shared

    var body: some View {
        VStack(spacing: 6) {
            row
            // Same bars as the Mac; before anything has played, keep their space so nothing jumps.
            if radio.current != nil { SpectrumBars() }
            else { Color.clear.frame(height: CGFloat(SpectrumRenderer.barHeight)) }
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            let np = radio.current.flatMap { radio.displayed($0.id) }
            let isAlbumArt = np?.image.isEmpty == false
            ArtTile(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: 72,
                    isAlbumArt: isAlbumArt, cornerRadius: 16)
                // Tap the art: full size first; while it's big, album art → channel logo → show art,
                // and with nothing to switch to it closes again (as on the Mac).
                .onTapGesture {
                    if !app.bigArt, radio.shownArtURL != nil { app.bigArt = true; return }
                    if let id = radio.current?.id, radio.cycleArt(id) { return }
                    app.bigArt = false
                }
                .task(id: radio.artCandidates.map(\.url)) {
                    for art in radio.artCandidates {
                        ArtCache.shared.prefetch(art.url, pixels: ArtCache.pixels(BigArtView.size), trimBorder: !art.isLogo)
                    }
                }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(isAlbumArt ? "Album art" : "Channel art")
                .accessibilityHint(app.bigArt ? "Switches between the album art, channel logo and show art"
                                              : "Shows the art full size")

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    MarqueeText(text: "\(ch.id) · \(ch.name)", font: .caption, secondary: true).id("\(ch.id) · \(ch.name)")
                    MarqueeText(text: np?.song ?? "", font: .headline).id(np?.song ?? "")
                    MarqueeText(text: np?.artist ?? "", font: .subheadline).id(np?.artist ?? "")
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tap the song/artist: the lyrics take the channel list's place, and back again.
            // Over big art it first just closes the art.
            .onTapGesture {
                if app.bigArt { app.bigArt = false; return }
                app.lyrics.toggle()
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(app.lyrics ? "Shows the channel list" : "Shows the song's lyrics")

            Button { radio.togglePlayPause() } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .disabled(radio.current == nil)
            .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")

            if let ch = radio.current {
                StarButton(isStarred: radio.presets.contains(ch.id)) { radio.togglePreset(ch.id) }
            }
        }
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
        .onTapGesture { AppState.shared.bigArt = false }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(isLogo ? "Channel art" : "Album art")
        .accessibilityHint(AppState.shared.lyrics ? "Shows the lyrics" : "Shows the channel list")
    }
}

/// AirPlay / Bluetooth / speaker picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
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
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isStarred ? "star.fill" : "star")
                .foregroundStyle(isStarred ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isStarred ? "Remove from stars" : "Add to stars")
    }
}

// MARK: Channels

struct ChannelList: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = AppState.shared

    var body: some View {
        let filtered = Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: app.search,
                                      stars: app.starsOnly ? radio.presets : nil)
        let list = filtered.filter { ch in
            let place = ChannelGroup.place(ch)
            return (app.category.map { place.group == $0 } ?? true) && (app.genre.map { place.sub == $0 } ?? true)
        }
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // The genre chips stay put over the list while it scrolls.
                CategoryBar(titles: groups, all: "All Channels", selected: $app.category)
                // Picking a group opens a second row with its detailed genres (Sports → NFL, NBA, …).
                if let group = app.category, genres(in: group).count > 1 {
                    CategoryBar(titles: genres(in: group), all: "All \(group)", selected: $app.genre, small: true)
                }
                List(list) { ch in
                    let isPlaying = ch == radio.current && radio.isPlaying
                    Button { radio.play(ch) } label: {
                        ChannelRow(channel: ch, nowPlaying: radio.displayed(ch.id), isCurrent: ch == radio.current)
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .trailing) {
                        StarButton(isStarred: radio.presets.contains(ch.id)) { radio.togglePreset(ch.id) }
                    }
                    .listRowBackground(isPlaying ? Color.accentColor.opacity(0.15) : nil)
                    .accessibilityHint("Plays this channel")
                    .id(ch.id)
                }
                .listStyle(.plain)
                .overlay {
                    if list.isEmpty {
                        Text(app.starsOnly && app.search.isEmpty && app.category == nil ? "No starred channels" : "No matches")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .searchable(text: $app.search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search channels, artists, songs")
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    /// The top-level groups that have channels, in ChannelGroup.order.
    private var groups: [String] {
        let present = Set(radio.channels.map { ChannelGroup.place($0).group })
        return ChannelGroup.order.map(\.group).filter(present.contains)
    }

    /// The second-row chips of one group that have channels, in ChannelGroup.order.
    private func genres(in group: String) -> [String] {
        let present = Set(radio.channels.map(ChannelGroup.place).filter { $0.group == group }.map(\.sub))
        return (ChannelGroup.order.first { $0.group == group }?.subs ?? []).filter(present.contains)
    }
}

/// A fixed, hand-made table from the API's genres (decorations.genre, audited Nov 2026: ~50 genres,
/// many with 1–5 channels) to five top-level chips and a few second-row chips each. Small genres are
/// folded into a neighbour so no chip is a lone channel; talk never lands in Music. Xtra channels
/// carry music genres and sit in Music with the live ones. Search still matches the API's own genre.
enum ChannelGroup {
    static let order: [(group: String, subs: [String])] = [
        ("Music", ["Pop", "Rock", "Hip-Hop & R&B", "Country", "Dance", "Latin & World", "Jazz & Classical",
                   "Christian", "Chill", "Kids", "Holiday"]),
        ("Sports", ["Sports Talk", "NFL", "MLB", "NBA", "NHL", "College", "Live Games"]),
        ("News", ["News", "Business"]),
        ("Talk", ["Entertainment", "Faith & Health"]),
        ("Comedy", []),
    ]

    private static let genres: [String: (group: String, sub: String)] = [
        "Pop": ("Music", "Pop"),
        "Rock": ("Music", "Rock"), "Classic Rock": ("Music", "Rock"),
        "Hard Rock & Metal": ("Music", "Rock"), "Alternative & Indie": ("Music", "Rock"),
        "Hip-Hop": ("Music", "Hip-Hop & R&B"), "R&B": ("Music", "Hip-Hop & R&B"),
        "Country": ("Music", "Country"),
        "Dance & Electronic": ("Music", "Dance"),
        "Latin": ("Music", "Latin & World"), "International": ("Music", "Latin & World"), "Reggae": ("Music", "Latin & World"),
        "Jazz": ("Music", "Jazz & Classical"), "Classical": ("Music", "Jazz & Classical"),
        "Standards": ("Music", "Jazz & Classical"), "Stage & Screen": ("Music", "Jazz & Classical"),
        "Christian": ("Music", "Christian"),
        "New Age & Ambient": ("Music", "Chill"),
        "Family & Kids": ("Music", "Kids"),
        "Holiday": ("Music", "Holiday"),
        "Sports Talk": ("Sports", "Sports Talk"),
        "Live Games": ("Sports", "Live Games"),
        "News & Politics": ("News", "News"),
        "Business": ("News", "Business"),
        "Pop Culture": ("Talk", "Entertainment"), "Society & Culture": ("Talk", "Entertainment"),
        "Fiction & Drama": ("Talk", "Entertainment"), "True Crime": ("Talk", "Entertainment"),
        "Religion": ("Talk", "Faith & Health"), "Lifestyle & Health": ("Talk", "Faith & Health"),
        "Health & Wellness": ("Talk", "Faith & Health"),
        "Comedy": ("Comedy", ""),
    ]

    /// Live channels the API sends with no genre (Howard 100, Road Dog, Holy Culture, …).
    private static let blankLive: [String: (group: String, sub: String)] = [
        "100": ("Talk", "Entertainment"), "142": ("Talk", "Entertainment"), "143": ("Talk", "Entertainment"),
        "159": ("Talk", "Entertainment"), "770": ("Talk", "Entertainment"), "790": ("Talk", "Entertainment"),
        "168": ("Music", "Christian"), "362": ("Music", "Hip-Hop & R&B"), "1999": ("Sports", "Live Games"),
    ]

    static func place(_ ch: Channel) -> (group: String, sub: String) {
        if ch.category == "Sports & Recreation" { return ("Sports", sport(ch.id)) }
        // College Sports Radio and SEC / Big Ten / ACC Radio come as "Sports Talk".
        if ["84", "256", "257", "258"].contains(ch.id) { return ("Sports", "College") }
        if let p = genres[ch.category] { return p }
        if let p = blankLive[ch.id] { return p }
        // Anything else: Xtra (always music; the blank ones are moods like Rainfall Radio, Lo-Fi Café)
        // goes to Chill, the Limited Edition pop-ups to Pop, and an unknown talk genre to Talk.
        if ch.xtraID != nil { return ("Music", "Chill") }
        if ch.category.isEmpty { return ("Music", "Pop") }
        return ("Talk", "Entertainment")
    }

    /// "Sports & Recreation" is the league talk channels (81–91) and every team's play-by-play,
    /// numbered in league blocks.
    private static func sport(_ id: String) -> String {
        switch Int(id) ?? 0 {
        case 800...832: return "NFL"
        case 840...871: return "MLB"
        case 880...909: return "NBA"
        case 920...951: return "NHL"
        case 952...962: return "College"
        case 963...: return "Live Games"
        default: return "Sports Talk"
        }
    }
}

/// An "All …" chip and one chip per title, scrolling sideways over the channel list.
struct CategoryBar: View {
    let titles: [String]
    let all: String
    @Binding var selected: String?
    var small = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(all, value: nil)
                ForEach(titles, id: \.self) { chip($0, value: $0) }
            }
            .padding(.horizontal)
            .padding(.vertical, small ? 4 : 8)
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let isOn = selected == value
        return Button { selected = value } label: {
            Text(title)
                .font(small ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 4 : 6)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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
