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

/// Takes the channel list's place, same height, so the panel doesn't change size.
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { bubble = text }
        bubbleTask = Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { bubble = nil }
        }
    }

    /// The song the pane is about: what's coming out of the speakers, else what the row shows.
    private var showing: NowPlaying? {
        radio.playingNow ?? radio.current.flatMap { radio.nowPlaying[$0.id] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let lyrics = store.lyrics {
                lines(lyrics)
            } else {
                VStack {
                    Spacer()
                    Text(store.status).font(.body).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 20)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: menu.listHeight)
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
            Button("Art") { menu.bigArt = true }
                .disabled(radio.current == nil)
                .help("Show the art full size")
            Button("Chs") { menu.lyrics = false }
                .help("Back to the channel list")
                .accessibilityLabel("Channels")
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
                    if !lyrics.synced {
                        showBubble("Text only lyrics, not timed")
                    } else if pin(line, in: lyrics, at: position) {
                        showBubble("Lyrics position set")
                    }
                    // Light the clicked line straight away, even when the song's position isn't
                    // known yet (or never turns up): until it is, the click is the best guess.
                    if lyrics.synced {
                        tapped = line.id
                        current = line.id
                    }
                }
                .equatable()
                .padding(.trailing, 12)
                // Timed lyrics scroll themselves: no scroller flashing on every line change.
                .background(Group { if !lyrics.synced { SkinnyScrollers().frame(width: 0, height: 0) } })
            }
            .scrollIndicators(lyrics.synced ? .hidden : .automatic)
            .frame(height: menu.listHeight)
            .padding(.trailing, -12)
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
                let now = position.flatMap { Self.line(of: lyrics, at: $0) } ?? tapped
                if now != current { current = now }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Where the pane treats the song as being: the track's position plus `displayLead`, so a line
    /// lights as its first word is sung rather than a word or two after (an LRC stamp is the
    /// first syllable, and the eye needs the line just before the voice reaches it). Kept small:
    /// with the position measured from the audio a large lead is what puts the highlight a word or
    /// two ahead of the singing.
    private var position: TimeInterval? { radio.trackPosition.map { $0 + Self.displayLead } }

    /// `defaults write com.starplayrx.mac lyricsDisplayLead -float 1.0` moves it without a rebuild.
    static var displayLead: TimeInterval {
        UserDefaults.standard.object(forKey: "lyricsDisplayLead") as? Double ?? 0.3
    }

    /// The line the user clicked is the line being sung: the shift that makes the song's position
    /// land on that line's timestamp replaces whatever the aligner had worked out, and nothing
    /// measured later overrules it while this song plays. Live channels remember it for next time —
    /// that is the same correction the aligner saves — an Xtra track's position is the file's own,
    /// so its pin lasts only as long as the track does.
    private func pin(_ line: LyricLine, in lyrics: Lyrics, at position: TimeInterval?) -> Bool {
        guard lyrics.synced, let target = line.at, let position, let np = showing else { return false }
        let live = radio.current?.xtraID == nil
        let key = LyricsStore.key(np.artist, np.song)
        let base = live ? (LyricSync.shared.shift(forKey: key) ?? Radio.liveLyricsLead)
                        : (LyricSync.shared.pinnedShift(forKey: key)
                           ?? radio.xtraNow.flatMap { LyricSync.shared.xtraShift(for: $0.file) } ?? 0)
        return LyricSync.shared.pin(shift: base + (target - position), forKey: key, remember: live)
    }


    /// The lines grouped into sections, keeping every line's id (the highlight and the auto-scroll
    /// go by id). Blank lines are the breaks LRCLIB ships and are dropped; on synced lyrics more
    /// than 4 seconds between two lines is a break too (an intro, a solo, the gap before a chorus).
    static func sections(of lyrics: Lyrics) -> [[LyricLine]] {
        var out = [[LyricLine]]()
        var section = [LyricLine]()
        var lastAt: TimeInterval?
        for line in lyrics.lines {
            let gap = line.at.flatMap { at in lastAt.map { at - $0 > 4 } } ?? false
            if (line.text.isEmpty || gap), !section.isEmpty {
                out.append(section)
                section = []
            }
            if let at = line.at { lastAt = at }
            guard !line.text.isEmpty else { continue }
            section.append(line)
        }
        if !section.isEmpty { out.append(section) }
        return out
    }

    /// `(Gold up in my teeth)` — a backing vocal, set apart from the line being sung.
    static func isAdLib(_ text: String) -> Bool {
        text.count > 2 && text.hasPrefix("(") && text.hasSuffix(")")
    }

    /// The last line whose timestamp has passed. Nothing is highlighted before the first line or
    /// once the song has run well past the last one (a radio edit, or the wrong record): parking
    /// on the final line for minutes looks broken and is worse than no highlight at all.
    static func line(of lyrics: Lyrics, at position: TimeInterval) -> Int? {
        guard lyrics.synced else { return nil }
        guard let last = lyrics.lines.last?.at, position < last + 30 else { return nil }
        var found: Int?
        for line in lyrics.lines {
            guard let at = line.at, at <= position else { break }
            // Only a line the pane actually draws. LRC files time the gaps between verses as empty
            // lines, and `sections(of:)` drops those: asking the scroll view for an id it hasn't
            // got sends it to the bottom of the lyrics instead of to the line being sung.
            if !line.text.isEmpty { found = line.id }
        }
        return found
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
