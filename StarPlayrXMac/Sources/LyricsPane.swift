//
//  LyricsPane.swift
//  StarPlayrXMac
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The lyrics view on the Mac. The model, store and search (LyricLine, Lyrics, LyricsStore,
//  LyricsEngine) live in StarPlayrKit's Lyrics.swift.
//

import SwiftUI
import StarPlayrKit

// MARK: Pane

/// Lies over the channel list and fills its area, so the panel doesn't change size.
struct LyricsPane: View {
    @EnvironmentObject var radio: Radio
    @ObservedObject private var menu = MenuController.shared
    @ObservedObject private var store = LyricsStore.shared
    /// The line being sung, by id; only changes when the singing moves on to the next line.
    @State private var current: Int?
    /// The line last clicked, standing in for `current` while the song's position is unknown.
    @State private var tapped: Int?
    /// The bubble after a click: "position set" when it pins timed lyrics, or a note that plain
    /// lyrics can't be timed. A newer click restarts its timer.
    @State private var bubble: String?
    @State private var bubbleTask: Task<Void, Never>?

    private func showBubble(_ text: String) {
        bubbleTask?.cancel()
        // The bubble is a passing label VoiceOver never lands on, so say it out loud instead (as BubblePopup does).
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { bubble = text }
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { bubble = nil }
        }
    }

    /// The song the pane is about: what's coming out of the speakers, else what the row shows.
    private var showing: NowPlaying? { radio.lyricsSong }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.zIndex(1)   // over the lines fading out behind it
            if let lyrics = store.lyrics {
                lines(lyrics)
            } else {
                VStack {
                    Spacer()
                    Text(store.status).font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Follows the song: a new title (or opening the pane) starts the fetch.
        .task(id: "\(showing?.artist ?? "")|\(showing?.song ?? "")") {
            store.show(artist: showing?.artist ?? "", song: showing?.song ?? "", duration: radio.trackDuration)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Lyrics").font(.headline)
                // Plain lyrics say so in place of the title: nothing will scroll, and that's why.
                Text(store.lyrics.map { $0.synced ? "\($0.song) · \($0.artist)"
                                                  : "Text only lyrics - sync not available" }
                     ?? "LRCLIB · NetEase · QQ · Kugou")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .frame(height: 22)
    }

    /// Synced lyrics scroll themselves and dim every line but the one being sung; plain lyrics
    /// are just a scrolling block of text. Either way the lines are grouped into sections, so
    /// verses and the chorus read apart instead of as one wall of text.
    ///
    /// The song's position is checked 4 times a second, but the lines are only rebuilt when the
    /// line being sung changes (every few seconds). Rebuilding every line of the song on each
    /// check, as a `TimelineView` did, cost ~7% CPU with the lyrics open.
    private func lines(_ lyrics: Lyrics) -> some View {
        let id = "\(lyrics.artist)|\(lyrics.song)|\(lyrics.lines.count)|\(lyrics.synced)"
        return ScrollViewReader { proxy in
            ScrollView {
                LyricLines(id: id, lyrics: lyrics, current: current) { line in
                    if let message = LyricsLayout.tap(line, in: lyrics) { showBubble(message) }
                    // Light the clicked line straight away, even when the song's position isn't
                    // known yet (or never turns up): until it is, the click is the best guess.
                    if lyrics.synced {
                        tapped = line.id
                        current = line.id
                    }
                }
                .equatable()
                .padding(.trailing, 12)
                // Room for the reach below, so at rest the first and last lines sit inside the field.
                .padding(.top, 22).padding(.bottom, 22)
                // Timed lyrics scroll themselves: no scroller flashing on every line change.
                .background(Group { if !lyrics.synced { SkinnyScrollers().frame(width: 0, height: 0) } })
            }
            .scrollIndicators(lyrics.synced ? .hidden : .automatic)
            .frame(maxHeight: .infinity)   // fills the channel list's area it lies over
            .padding(.trailing, -12)
            // Lines stay at full strength across the whole clear area, including the gaps up to
            // the header (8 pt) and down to the footer (10 pt), and only fade out (28 pt) once
            // they pass behind the header or the footer's buttons.
            // (A fade, not a blur: crisper, and cheap enough to redraw while the lyrics scroll.)
            // The mask goes on before the negative padding: negative padding doesn't grow the
            // view's bounds, so a mask after it would sit inside the field and fade there.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                }
            }
            .padding(.top, -18).padding(.bottom, -18)
            .overlay(alignment: .bottom) {
                if let bubble {
                    Text(bubble)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 4, y: 2)
                        .padding(.bottom, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .onValueChange(of: current) { line in
                guard let line else { return }
                // Next pass of the run loop: the new line turns bold (and may wrap) in this one, and
                // centering on its old frame can leave it near or past the edge of the pane.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
                }
            }
        }
        .task(id: id) {
            tapped = nil
            while !Task.isCancelled {
                let now = LyricsLayout.line(of: lyrics) ?? tapped
                if now != current { current = now }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    static var displayLead: TimeInterval { LyricsLayout.displayLead }

    static func sections(of lyrics: Lyrics) -> [[LyricLine]] { LyricsLayout.sections(of: lyrics) }

    static func isAdLib(_ text: String) -> Bool { LyricsLayout.isAdLib(text) }

    static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        LyricsLayout.line(of: lyrics, at: position)
    }
}

/// Every line of the song, grouped into sections. Equatable on the song and the line being sung,
/// so SwiftUI leaves it alone until one of them changes.
private struct LyricLines: View, Equatable {
    let id: String
    let lyrics: Lyrics
    let current: Int?
    let tap: (LyricLine) -> Void

    static func == (a: LyricLines, b: LyricLines) -> Bool { a.id == b.id && a.current == b.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(LyricsPane.sections(of: lyrics), id: \.first?.id) { section in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(section) { line in
                        let adLib = LyricsPane.isAdLib(line.text)
                        Text(line.text)
                            .font(line.id == current ? .body.bold() : adLib ? .callout : .body)
                            .foregroundStyle(!lyrics.synced || line.id == current ? .primary : .secondary)
                            .padding(.leading, adLib ? 14 : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Click a line to say that is what is being sung right now:
                            // the highlight moves there and the rest of the song follows
                            // from it. Only means anything on timed lyrics.
                            .contentShape(Rectangle())
                            .onTapGesture { tap(line) }
                            // VoiceOver says which line is being sung, and that pressing it sets it.
                            .accessibilityAddTraits(line.id == current ? .isSelected : [])
                            .accessibilityHint(lyrics.synced ? "Sets this as the line being sung" : "")
                            // VO-Space doesn't reliably reach a tap gesture: press does the same.
                            .accessibilityAction { tap(line) }
                            .id(line.id)
                    }
                }
            }
        }
    }
}

/// `onChange` that hands over just the new value. The one-parameter form is deprecated in
/// macOS 14 and the two-parameter one doesn't exist before it, and the app runs on macOS 13.
private extension View {
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { _, new in action(new) }
        } else {
            legacyOnChange(of: value, perform: action)
        }
    }

    /// Deprecated itself, so the macOS 13 fallback doesn't warn about the API it has to use.
    @available(macOS, deprecated: 14.0)
    func legacyOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onChange(of: value, perform: action)
    }
}

extension LyricsPane {
    /// The tests reach the aligner through the pane, which is where it is used.
    static func alignment(lineTimes: [Double], songStart: Date,
                          onsets: (start: Date, step: Double, values: [Float])) -> LyricAligner.Alignment? {
        LyricAligner.align(lineTimes: lineTimes, songStart: songStart, onsets: onsets)
    }
}
