//
//  LyricsView.swift
//  StarPlayrX (iOS / iPadOS)
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The Mac's LyricsPane for iPhone and iPad: timed lyrics follow the song and light the line
//  being sung; tapping a line says "this is what's being sung now" (see LyricsLayout.pin).
//

import SwiftUI
import StarPlayrKit

struct LyricsView: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var store = LyricsStore.shared
    /// The line being sung, by id.
    @State private var current: Int?
    /// The line last tapped, standing in for `current` while the song's position is unknown.
    @State private var tapped: Int?
    @State private var bubble: String?
    @State private var bubbleTask: Task<Void, Never>?

    /// The song the lyrics are for: what's coming out of the speakers, else what the row shows.
    private var showing: NowPlaying? { radio.lyricsSong }

    var body: some View {
        Group {
            if let lyrics = store.lyrics {
                lines(lyrics)
            } else {
                VStack {
                    Spacer()
                    Text(store.status).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(store.lyrics.map { $0.synced ? "\($0.song) · \($0.artist)" : "Text only lyrics - sync not available" }
                 ?? "LRCLIB · NetEase · QQ · Kugou")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(.bar)
        }
        // Follows the song: a new title (or opening the lyrics) starts the fetch.
        .task(id: "\(showing?.artist ?? "")|\(showing?.song ?? "")") {
            store.show(artist: showing?.artist ?? "", song: showing?.song ?? "", duration: radio.trackDuration)
        }
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        let id = "\(lyrics.artist)|\(lyrics.song)|\(lyrics.lines.count)|\(lyrics.synced)"
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(LyricsLayout.sections(of: lyrics), id: \.first?.id) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(section) { line in
                                let adLib = LyricsLayout.isAdLib(line.text)
                                Text(line.text)
                                    .font(line.id == current ? .title3.bold() : adLib ? .callout : .title3)
                                    .foregroundStyle(!lyrics.synced || line.id == current ? .primary : .secondary)
                                    .padding(.leading, adLib ? 16 : 0)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { tap(line, in: lyrics) }
                                    .id(line.id)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .bottom) {
                if let bubble {
                    Text(bubble)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .task(id: id) {
            tapped = nil
            while !Task.isCancelled {
                let now = LyricsLayout.position.flatMap { LyricsLayout.line(of: lyrics, at: $0) } ?? tapped
                if now != current { current = now }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func tap(_ line: LyricLine, in lyrics: Lyrics) {
        if let message = LyricsLayout.tap(line, in: lyrics) { showBubble(message) }
        guard lyrics.synced else { return }
        tapped = line.id
        current = line.id
    }

    private func showBubble(_ text: String) {
        bubbleTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { bubble = text }
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { bubble = nil }
        }
    }
}
