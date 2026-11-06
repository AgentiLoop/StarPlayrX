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
                    TextField("Username or email", text: $user, prompt: Text("Username or email").foregroundStyle(.primary), axis: .vertical)
                        .lineLimit(1...3)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $pass, prompt: Text("Password").foregroundStyle(.primary))
                        .textContentType(.password)
                        .onSubmit(signIn)
                    Toggle("Canada", isOn: Binding(get: { radio.localeIsCA }, set: { radio.setRegion(ca: $0) }))
                } header: {
                    Text("Sign in with your SiriusXM account")
                        .foregroundStyle(.primary)
                } footer: {
                    Text("Your username and password are kept only in this device's Keychain.")
                        .foregroundStyle(.primary)
                }
                Section {
                    // Not .disabled: its dimmed text fails contrast. signIn() ignores taps until ready.
                    Button(action: signIn) {
                        HStack {
                            Text(radio.isBusy ? "Signing in…" : "Sign In")
                            if radio.isBusy { Spacer(); ProgressView() }
                        }
                    }
                } footer: {
                    Text(radio.status)
                        .foregroundStyle(.primary)
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
    @ObservedObject private var app = PlayerState.shared

    var body: some View {
        VStack(spacing: 6) {
            row
            controls
            // Same bars as the Mac; before anything has played, keep their space so nothing jumps.
            if radio.current != nil { SpectrumBars(running: app.barsRunning) }
            else { Color.clear.frame(height: CGFloat(SpectrumRenderer.barHeight)) }
        }
    }

    /// Art, channel, song and artist, and the star — the titles get the whole width beside the art.
    private var row: some View {
        HStack(spacing: 12) {
            let np = radio.current.flatMap { radio.displayed($0.id) }
            let isAlbumArt = np?.image.isEmpty == false
            ArtTile(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: 72,
                    isAlbumArt: isAlbumArt, cornerRadius: 16)
                // Tap the art: full size first; while it's big, album art → channel logo → show art,
                // and with nothing to switch to it closes again (as on the Mac).
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
            .onTapGesture { app.tapTitles() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(app.bigArt ? "Shows the \(app.lyrics ? "lyrics" : "channel list") again"
                               : app.lyrics ? "Shows the channel list" : "Shows the song's lyrics")
            .accessibilityAction { app.tapTitles() }

            if let ch = radio.current {
                StarButton(isStarred: radio.presets.contains(ch.id), channel: ch.name) { radio.togglePreset(ch.id) }
            }
        }
    }

    /// Previous, play/pause and next, centred on their own row under the titles.
    private var controls: some View {
        HStack(spacing: 44) {
            // Previous / next: the same playAdjacent the lock screen's ⏮ ⏭ send (RadioSession.swift).
            Button { radio.playAdjacent(-1) } label: {
                Image(systemName: "backward.fill").font(.system(size: 22))
            }
            .accessibilityLabel("Previous")

            Button { radio.togglePlayPause() } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
            }
            .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")

            Button { radio.playAdjacent(1) } label: {
                Image(systemName: "forward.fill").font(.system(size: 22))
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

    var body: some View {
        let list = app.visibleChannels
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                // Under the header's EQ bars, over the chips; stays put while the list scrolls.
                SearchField(text: $app.search, prompt: "Search channels, artists, songs")
                    .padding(.horizontal)
                    .padding(.top, 8)
                // The category chips (StarPlayrKit's ChannelGroup) stay put over the list while it scrolls.
                CategoryBar(titles: ChannelGroup.groups(radio.channels), all: "All Channels", selected: $app.category)
                // Picking a group opens a second row with its detailed chips (Sports → NFL, NBA, …).
                if let group = app.category, case let subs = ChannelGroup.subs(of: group, in: radio.channels), subs.count > 1 {
                    CategoryBar(titles: subs, all: "All \(group)", selected: $app.subcategory, small: true)
                }
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
                    // A 15% tint all but vanishes on the black list in dark mode; there it's much stronger.
                    .listRowBackground(isPlaying ? Color.accentColor.opacity(scheme == .dark ? 0.4 : 0.15) : nil)
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
