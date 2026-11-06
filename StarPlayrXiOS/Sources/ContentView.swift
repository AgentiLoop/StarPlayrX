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
                if app.lyrics { LyricsView() } else { ChannelList() }
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
                    if !app.lyrics {
                        Button { app.starsOnly.toggle() } label: {
                            Image(systemName: app.starsOnly ? "star.fill" : "star")
                        }
                        .accessibilityLabel(app.starsOnly ? "All Stars On" : "All Stars Off")
                    }
                    Button { app.lyrics.toggle() } label: {
                        Image(systemName: app.lyrics ? "list.bullet" : "quote.bubble")
                    }
                    .accessibilityLabel(app.lyrics ? "Channels" : "Lyrics")
                }
            }
        }
    }
}

/// Art, channel, song and artist, play/pause and the star — the Mac panel's header.
struct NowPlayingHeader: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var app = AppState.shared

    var body: some View {
        HStack(spacing: 12) {
            let np = radio.current.flatMap { radio.displayed($0.id) }
            let isAlbumArt = np?.image.isEmpty == false
            ArtTile(url: (isAlbumArt ? np?.image : radio.current?.imageURL) ?? "", size: 72,
                    isAlbumArt: isAlbumArt, cornerRadius: 16)
                // Tap the art: album art → channel logo → show art, as the channel has them.
                .onTapGesture { if let id = radio.current?.id { radio.cycleArt(id) } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(isAlbumArt ? "Album art" : "Channel art")

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    Text("\(ch.id) · \(ch.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(np?.song ?? "").font(.headline).lineLimit(1)
                    Text(np?.artist ?? "").font(.subheadline).lineLimit(1)
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Tap the song/artist: the lyrics take the channel list's place, and back again.
            .onTapGesture { app.lyrics.toggle() }
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
        let list = Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: app.search,
                                  stars: app.starsOnly ? radio.presets : nil)
        ScrollViewReader { proxy in
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
            .searchable(text: $app.search, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search channels, artists, songs")
            .overlay {
                if list.isEmpty {
                    Text(app.starsOnly && app.search.isEmpty ? "No starred channels" : "No matches")
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// One channel: number, art, name, and what it's playing.
struct ChannelRow: View, Equatable {
    let channel: Channel
    let nowPlaying: NowPlaying?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(channel.id).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
            let albumArt = nowPlaying?.image.isEmpty == false
            ArtTile(url: (albumArt ? nowPlaying?.image : channel.imageURL) ?? "", size: 44, isAlbumArt: albumArt)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(isCurrent ? .body.bold() : .body).lineLimit(1)
                Text(nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Room for the star laid over the row's end.
            Color.clear.frame(width: 28, height: 1)
        }
        .contentShape(Rectangle())
    }
}
