//
//  StarPlayrXMacTests.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/1/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import XCTest
@testable import StarPlayrX
@testable import StarPlayrKit

/// Pure logic: search matching, corner parking math, coordinate flips, four-char codes.
final class LogicTests: XCTestCase {
    private let channels = [
        Channel(id: "2", name: "Hits 1", category: "Pop", imageURL: ""),
        Channel(id: "20", name: "Classic Rewind", category: "Rock", imageURL: ""),
        Channel(id: "1000", name: "Indie Mix", category: "Alternative", imageURL: "", xtraID: "x1")]
    private let np = ["2": NowPlaying(artist: "Remi Wolf", song: "Champagne"),
                      "20": NowPlaying(artist: "Boston", song: "Foreplay")]

    func testEmptySearchShowsEverything() {
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "").map(\.id), ["2", "20", "1000"])
    }

    func testSearchMatchesNumberNameCategoryArtistSongAndXtra() {
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "20").map(\.id), ["20"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "hits").map(\.id), ["2"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "ROCK").map(\.id), ["20"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "remi").map(\.id), ["2"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "foreplay").map(\.id), ["20"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "music xtra").map(\.id), ["1000"])
        XCTAssertEqual(Channel.filter(channels, nowPlaying: np, search: "nothing like this").map(\.id), [])
    }

    func testParkedCorners() {
        let visible = NSRect(x: 0, y: 50, width: 1000, height: 700)   // maxX 1000, maxY 750
        let size = NSSize(width: 340, height: 200)
        XCTAssertEqual(MenuController.parkedTopLeft(.upperRight, size: size, in: visible), NSPoint(x: 652, y: 742))
        XCTAssertEqual(MenuController.parkedTopLeft(.upperLeft, size: size, in: visible), NSPoint(x: 8, y: 742))
        XCTAssertEqual(MenuController.parkedTopLeft(.lowerRight, size: size, in: visible), NSPoint(x: 652, y: 258))
        XCTAssertEqual(MenuController.parkedTopLeft(.lowerLeft, size: size, in: visible), NSPoint(x: 8, y: 258))
    }

    func testFlipYIsItsOwnInverse() {
        let p = NSPoint(x: 120, y: 30)
        let flipped = MenuController.flipY(p, mainScreenHeight: 900)
        XCTAssertEqual(flipped, NSPoint(x: 120, y: 870))
        XCTAssertEqual(MenuController.flipY(flipped, mainScreenHeight: 900), p)
    }

    func testFourCharCode() {
        XCTAssertEqual(SPXCommand.code("SPUR"), 0x5350_5552)
    }

    func testVersionOrdering() {
        XCTAssertTrue(Updater.isVersion("1.1.16", newerThan: "1.1.15"))
        XCTAssertTrue(Updater.isVersion("1.2", newerThan: "1.1.99"))
        XCTAssertTrue(Updater.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertFalse(Updater.isVersion("1.1.15", newerThan: "1.1.15"))
        XCTAssertFalse(Updater.isVersion("1.1.15", newerThan: "1.1.16"))
        XCTAssertFalse(Updater.isVersion("1.1.0", newerThan: "1.1"))
        XCTAssertFalse(Updater.isVersion("1.1.16-beta", newerThan: "1.1.15"))
    }

    func testPickNewestMacRelease() {
        let page = URL(string: "https://example.com/r")!
        let zip = URL(string: "https://example.com/StarPlayrX-Mac-x.zip")!
        let releases: [(tag: String, draft: Bool, prerelease: Bool, notes: String, page: URL, zip: URL?)] = [
            ("mac-1.1.16", false, false, "sixteen", page, zip),
            ("mac-1.1.18", false, true, "pre", page, zip),         // pre-release
            ("mac-1.1.17", false, false, "no zip yet", page, nil), // still uploading
            ("mac-1.1.19", true, false, "draft", page, zip),       // draft
            ("1.3.1", false, false, "old iOS tag", page, zip),
            ("mac-1.1.14", false, false, "older", page, zip)]
        XCTAssertEqual(Updater.pick(releases, newerThan: "1.1.15", prereleases: false)?.version, "1.1.16")
        XCTAssertEqual(Updater.pick(releases, newerThan: "1.1.15", prereleases: true)?.version, "1.1.18")
        XCTAssertNil(Updater.pick(releases, newerThan: "1.1.16", prereleases: false))
        XCTAssertEqual(Updater.pick(releases, newerThan: "1.1.15", prereleases: false)?.notes, "sixteen")
    }

    func testLyricSectionsSplitOnBlankLinesAndLongGaps() {
        // Plain lyrics: the blank line is the break, and it isn't shown as a line of its own.
        let plain = Lyrics(artist: "Kiiara", song: "Gold", lines: [
            LyricLine(id: 0, at: nil, text: "Roof was fallin'"),
            LyricLine(id: 1, at: nil, text: "(Gold up in my teeth)"),
            LyricLine(id: 2, at: nil, text: ""),
            LyricLine(id: 3, at: nil, text: "I missed you in the basement")], synced: false)
        let sections = LyricsPane.sections(of: plain)
        XCTAssertEqual(sections.map { $0.map(\.id) }, [[0, 1], [3]])

        // Synced lyrics: more than 4 s between two lines is a break too (an intro or a solo).
        let synced = Lyrics(artist: "a", song: "b", lines: [
            LyricLine(id: 0, at: 10, text: "one"),
            LyricLine(id: 1, at: 12, text: "two"),
            LyricLine(id: 2, at: 30, text: "after the solo"),
            LyricLine(id: 3, at: 33, text: "and on")], synced: true)
        XCTAssertEqual(LyricsPane.sections(of: synced).map { $0.map(\.id) }, [[0, 1], [2, 3]])
    }

    func testAdLibLinesAreTheOnesFullyInParentheses() {
        XCTAssertTrue(LyricsPane.isAdLib("(Gold up in my teeth)"))
        XCTAssertFalse(LyricsPane.isAdLib("Don't care what you say (to me)"))
        XCTAssertFalse(LyricsPane.isAdLib("()"))
        XCTAssertFalse(LyricsPane.isAdLib("I missed you in the basement"))
    }

    func testSearchDropsTheBracketsLiveTitlesCarry() {
        // The live channels tag titles with a decade; LRCLIB has no record under that name.
        XCTAssertEqual(LyricsEngine.withoutParentheses("Break Free (14)"), "Break Free")
        XCTAssertEqual(LyricsEngine.withoutParentheses("All She Wants To Do Is Dance (85)"), "All She Wants To Do Is Dance")
        XCTAssertEqual(LyricsEngine.withoutParentheses("Gold [Radio Edit]"), "Gold")
        XCTAssertEqual(LyricsEngine.withoutParentheses("I'm Good (Blue) (22)"), "I'm Good")
        // Nothing to drop.
        XCTAssertEqual(LyricsEngine.withoutParentheses("Mrs. Robinson"), "Mrs. Robinson")
        // Nothing but brackets: keep it, or there's nothing left to search for.
        XCTAssertEqual(LyricsEngine.withoutParentheses("(14)"), "(14)")
    }

    func testHighlightSkipsTheTimedGapsBetweenVerses() {
        // LRC files time the gap between verses as an empty line. The pane doesn't draw those, so
        // the highlight must stay on the last line that is drawn — scrolling to an id the list
        // hasn't got sends it to the bottom. Well into a long gap (an instrumental) it goes out.
        let lyrics = Lyrics(artist: "a", song: "b", lines: [
            LyricLine(id: 0, at: 10, text: "last line of the verse"),
            LyricLine(id: 1, at: 14, text: ""),
            LyricLine(id: 2, at: 25, text: "first line of the chorus")], synced: true)
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 12), 0)
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 13), 0)   // before the empty stamp: still the line
        XCTAssertNil(LyricsPane.line(of: lyrics, at: 16))        // past the empty stamp, 11 s to the next line: instrumental
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 26), 2)
        // Every id the highlight can return is one the pane draws.
        let drawn = Set(LyricsPane.sections(of: lyrics).flatMap { $0 }.map(\.id))
        for at in stride(from: 0.0, through: 60.0, by: 0.5) {
            if let line = LyricsPane.line(of: lyrics, at: at) { XCTAssertTrue(drawn.contains(line), "id \(line) at \(at)") }
        }
    }

    // MARK: Lyric alignment

    /// An onset curve with a spike wherever a line is really sung, `shift` seconds away from where
    /// the broadcast's stamp says it is, plus a steady background so the peak has to stand out.
    private func onsetCurve(lineTimes: [Double], shift: Double, step: Double = 1.0 / 86.0,
                            seconds: Double = 200, noise: Float = 0.2) -> [Float] {
        var values = [Float](repeating: noise, count: Int(seconds / step))
        for t in lineTimes {
            let index = Int((t + shift) / step)
            guard index >= 0, index < values.count else { continue }
            for k in -2...2 where index + k >= 0 && index + k < values.count {
                values[index + k] += 2 - Float(abs(k)) * 0.3
            }
        }
        return values
    }

    /// Real lyrics don't come at a steady beat; evenly spaced ones align just as well a line out,
    /// which is the ambiguity the margin test is there to refuse.
    private let songLines: [Double] = {
        var t = 11.4
        var out = [Double]()
        for gap in [3.1, 4.7, 2.6, 5.9, 3.4, 8.2, 2.9, 4.1, 6.3, 3.7, 2.8, 5.2, 4.4, 3.3, 7.1,
                    2.7, 4.9, 3.6, 5.5, 3.2, 6.8, 4.2, 3.9, 5.1] {
            out.append(t)
            t += gap
        }
        return out
    }()

    func testAlignerFindsTheShiftTheStationIsUsing() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Truths deliberately off the 0.1 s search grid: the arrival score peaks at the frame the
        // voice comes in, and the parabola through its neighbours reads between the steps, so the
        // answer has to land on the line itself — not a word or two of slack either side of it.
        for truth in [-4.0, -1.53, 0.0, 2.47, 5.06] {
            let curve = onsetCurve(lineTimes: lines, shift: truth)
            let found = LyricsPane.alignment(lineTimes: lines, songStart: start,
                                             onsets: (start, 1.0 / 86.0, curve))
            XCTAssertNotNil(found, "no alignment for \(truth)")
            XCTAssertEqual(found?.shift ?? 0, truth, accuracy: 0.15, "shift for \(truth)")   // a syllable, not a word
        }
    }

    /// Closer to what the equalizer really hands over: a backbeat thumping away all through the
    /// song, and a sung line as a run of syllables that keeps going for about a bar rather than one
    /// tidy spike. The backbeat is the thing that used to pull the answer off the line — a score
    /// that asks "is it loud here?" is happy anywhere in the bar, so the highlight came up a word
    /// or two early or late. Asking "did it get louder HERE, after a lull?" only fits the syllables.
    private func sungCurve(lineTimes: [Double], shift: Double, step: Double = 1.0 / 86.0,
                           seconds: Double = 240) -> [Float] {
        var values = [Float](repeating: 0.05, count: Int(seconds / step))
        func hit(_ at: Double, _ strength: Float, _ decay: Double) {
            let index = Int(at / step)
            guard index >= 0 else { return }
            for k in 0..<Int(decay / step) where index + k < values.count {
                values[index + k] += strength * Float(exp(-Double(k) * step / (decay / 3)))
            }
        }
        // The band: a kick every half second from the top of the song to the end of it.
        for beat in stride(from: 0.0, to: seconds, by: 0.5) { hit(beat, 0.8, 0.18) }
        // The voice: four syllables a line, each a softer attack than the drum behind it.
        for t in lineTimes {
            for syllable in 0..<4 { hit(t + shift + Double(syllable) * 0.28, 0.5, 0.22) }
        }
        return values
    }

    func testAlignerLandsOnTheVoiceNotTheBeat() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        for truth in [-3.37, -0.84, 1.26, 4.63] {
            let found = LyricsPane.alignment(lineTimes: lines, songStart: start,
                                             onsets: (start, 1.0 / 86.0,
                                                      sungCurve(lineTimes: lines, shift: truth)))
            XCTAssertNotNil(found, "no alignment for \(truth)")
            // Within a syllable of where the singer actually comes in, with a drum kit in the way.
            XCTAssertEqual(found?.shift ?? 0, truth, accuracy: 0.15, "shift for \(truth)")
        }
    }

    /// The lyrics we were handed belong to a different cut of the record — LRCLIB's "Wild Wild West
    /// (Album Version With Intro)" against the radio edit 90s on 9 plays — so every line is stamped
    /// most of half a minute out. The ordinary search can only look at the wrong half-minute and
    /// finds nothing; the wide look that follows it has to come back with the whole intro.
    func testAlignerCatchesTheWrongCutOfTheRecord() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        for truth in [-24.3, -21.4, 28.0] {
            let curve = sungCurve(lineTimes: lines, shift: truth, seconds: 300)
            XCTAssertNil(LyricAligner.align(lineTimes: lines, songStart: start,
                                            onsets: (start, 1.0 / 86.0, curve),
                                            over: LyricAligner.search),
                         "the ordinary search isn't supposed to reach \(truth)")
            let found = LyricsPane.alignment(lineTimes: lines, songStart: start,
                                             onsets: (start, 1.0 / 86.0, curve))
            XCTAssertNotNil(found, "no alignment for \(truth)")
            XCTAssertEqual(found?.shift ?? 0, truth, accuracy: 0.15, "shift for \(truth)")
        }
    }


    func testAlignerWalksAwayWhenTheAudioSaysNothing() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        // Flat: every shift scores the same, so there is nothing to find.
        let flat = [Float](repeating: 0.5, count: 86 * 200)
        XCTAssertNil(LyricsPane.alignment(lineTimes: lines, songStart: start, onsets: (start, 1.0 / 86.0, flat)))
        // Too few lines inside the audio we have.
        let curve = onsetCurve(lineTimes: lines, shift: 1)
        XCTAssertNil(LyricsPane.alignment(lineTimes: [12, 19], songStart: start, onsets: (start, 1.0 / 86.0, curve)))
        // Enough lines, but all inside one chorus: too narrow a spread to place the whole song.
        let huddled = stride(from: 40.0, to: 70.0, by: 2).map { $0 }
        XCTAssertNil(LyricsPane.alignment(lineTimes: huddled, songStart: start,
                                          onsets: (start, 1.0 / 86.0, onsetCurve(lineTimes: huddled, shift: 1))))
    }

    /// The lock the song already has is re-scored on the SAME audio as a rival candidate, so a
    /// highlight parked a line out can correct itself once enough audio has come in: a candidate
    /// within `agree` is always a refinement, a rival wins only when it scores higher on the
    /// audio just decoded.
    func testChooseReScoresBothLocksOnTheSameAudio() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        let onsets = (start, 1.0 / 86.0, sungCurve(lineTimes: lines, shift: 2.0, seconds: 240))
        let truth = 2.0
        // Within `agree`: a refinement, always taken.
        let held = LyricAligner.Alignment(shift: truth, confidence: 3.0, margin: 2.0, lines: 20)
        let near = LyricAligner.Alignment(shift: truth + 0.3, confidence: 1.0, margin: 1.0, lines: 20)
        XCTAssertEqual(LyricAligner.choose(held: held, heldShift: truth, candidate: near,
                                           lineTimes: lines, songStart: start, onsets: onsets, agree: 0.5).shift,
                       truth + 0.3)
        // A rival a line out: it wins only because it fits the audio better here (the curve was
        // sung at `truth`, so a rival at -2 does not).
        let rival = LyricAligner.Alignment(shift: truth - 4.0, confidence: 4.0, margin: 3.0, lines: 20)
        XCTAssertEqual(LyricAligner.choose(held: held, heldShift: truth, candidate: rival,
                                           lineTimes: lines, songStart: start, onsets: onsets, agree: 0.5).shift,
                       truth)
        // A rival that really does fit better (the audio was sung shifted to it) takes the lock,
        // whatever confidence the old one carried.
        let onsets2 = (start, 1.0 / 86.0, sungCurve(lineTimes: lines, shift: truth - 4.0, seconds: 240))
        XCTAssertEqual(LyricAligner.choose(held: held, heldShift: truth, candidate: rival,
                                           lineTimes: lines, songStart: start, onsets: onsets2, agree: 0.5).shift,
                       truth - 4.0)
    }

    /// `score(of:)` is the same measurement `align` makes of a whole range: the truth it was
    /// sung at scores best, a line away scores worse, and it is nil when too few lines fall
    /// inside the audio to say anything.
    func testScoreOfMatchesAlignsOwnMeasurement() {
        let lines = songLines
        let start = Date(timeIntervalSince1970: 1_000_000)
        let onsets = (start, 1.0 / 86.0, sungCurve(lineTimes: lines, shift: 1.5, seconds: 240))
        let at = LyricAligner.score(of: 1.5, lineTimes: lines, songStart: start, onsets: onsets)
        let out = LyricAligner.score(of: 1.5 - 4.0, lineTimes: lines, songStart: start, onsets: onsets)
        XCTAssertNotNil(at)
        XCTAssertGreaterThan(at ?? 0, out ?? 0)
        // Too few lines inside the audio: nothing to say about any shift.
        let short = [Float](repeating: 0.5, count: 86 * 30)
        XCTAssertNil(LyricAligner.score(of: 0, lineTimes: lines, songStart: start, onsets: (start, 1.0 / 86.0, short)))
    }

    func testCachedLinesSurviveTheRoundTrip() {
        let lines = [LyricLine(id: 0, at: 11.07, text: "We don't have to worry bout nothing"),
                     LyricLine(id: 1, at: nil, text: "(fire fire fire)"),
                     LyricLine(id: 2, at: 222.31, text: "")]
        let back = LyricsCache.lines(from: LyricsCache.json(from: lines))
        XCTAssertEqual(back.map(\.text), lines.map(\.text))
        XCTAssertEqual(back.map(\.at), lines.map(\.at))
        XCTAssertEqual(back.map(\.id), [0, 1, 2])
        // A miss is a row with no lines; it must come back as no lines, not as one empty line.
        XCTAssertTrue(LyricsCache.lines(from: LyricsCache.json(from: [])).isEmpty)
        XCTAssertTrue(LyricsCache.lines(from: "not json").isEmpty)
    }

    func testCurrentLineIsTheLastStampThatPassed() {
        let lyrics = Lyrics(artist: "a", song: "b", lines: [
            LyricLine(id: 0, at: 10, text: "one"),
            LyricLine(id: 1, at: 20, text: "two"),
            LyricLine(id: 2, at: 30, text: "three")], synced: true)
        XCTAssertNil(LyricsPane.line(of: lyrics, at: 9.9))
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 10), 0)
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 29.9), 1)
        XCTAssertEqual(LyricsPane.line(of: lyrics, at: 55), 2)       // still within 30 s of the last line
        XCTAssertNil(LyricsPane.line(of: lyrics, at: 400))          // long past it: nothing
        // Unsynced lyrics never highlight.
        XCTAssertNil(LyricsPane.line(of: Lyrics(artist: "a", song: "b", lines: lyrics.lines, synced: false), at: 15))
    }

    func testAlbumArtStaysUntilTheSongChanges() {
        let shown = NowPlaying(artist: "Boston", song: "Foreplay", image: "http://albumart.siriusxm.com/a_m.jpg")
        // Same song polled again without art: keep the album art.
        XCTAssertEqual(Radio.keepingArt(NowPlaying(artist: "Boston", song: "Foreplay"), of: shown), shown)
        // New art for the same song replaces it.
        let newer = NowPlaying(artist: "Boston", song: "Foreplay", image: "http://albumart.siriusxm.com/b_m.jpg")
        XCTAssertEqual(Radio.keepingArt(newer, of: shown), newer)
        // Another song: the old art is wrong, drop it.
        let next = NowPlaying(artist: "Boston", song: "Long Time")
        XCTAssertEqual(Radio.keepingArt(next, of: shown), next)
        XCTAssertEqual(Radio.keepingArt(next, of: nil), next)
    }
}

/// The real panel in the test host: drag / tear off, park, shade, scroll, search, and the
/// AppleScript commands and properties going through Cocoa Scripting's own dispatch.
@MainActor
final class PanelTests: XCTestCase {
    private var menu: MenuController { MenuController.shared }
    private var panel: MenuPanel { MenuController.shared.panel }
    private let fake = (1...60).map { Channel(id: "\($0)", name: "Channel \($0)", category: $0 % 2 == 0 ? "Rock" : "Pop", imageURL: "") }

    override func setUp() async throws {
        Radio.shared.channels = fake
        Radio.shared.nowPlaying = ["7": NowPlaying(artist: "Remi Wolf", song: "Champagne")]
        Radio.shared.isLoggedIn = true
        Radio.shared.channelsLoaded = true
        menu.search = ""
        menu.hide()
        settle()
    }

    override func tearDown() async throws {
        menu.hide()
        menu.search = ""
        Radio.shared.isLoggedIn = false
        Radio.shared.channelsLoaded = false
        Radio.shared.channels = []
        Radio.shared.nowPlaying = [:]
    }

    /// Lets SwiftUI lay out and the hosting controller resize the panel.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private var visibleFrame: NSRect { (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero }

    /// Runs one of our AppleScript commands through the sdef's command description, as an Apple Event would.
    private func script(_ event: String, _ direct: Any? = nil, _ args: [String: Any] = [:]) -> Any? {
        let desc = NSScriptSuiteRegistry.shared()
            .commandDescription(withAppleEventClass: SPXCommand.code("SPrx"), andAppleEventCode: SPXCommand.code(event))
        XCTAssertNotNil(desc, "sdef has no command SPrx\(event)")
        guard let command = desc?.createCommandInstance() else { return nil }
        command.directParameter = direct
        command.arguments = args
        let result = command.execute()
        XCTAssertEqual(command.scriptErrorNumber, 0, command.scriptErrorString ?? "")
        return result
    }

    // MARK: Drag / tear off

    func testShortDragSnapsBackUnderMenuBar() {
        menu.ensureShown(); settle()
        let origin = panel.frame.origin
        menu.beginDrag()
        menu.drag(by: CGSize(width: 10, height: -10))
        XCTAssertEqual(panel.frame.origin, NSPoint(x: origin.x + 10, y: origin.y - 10))
        menu.endDrag()
        XCTAssertFalse(menu.detached)
        XCTAssertEqual(panel.frame.origin, origin)
    }

    func testLongDragTearsOff() {
        menu.ensureShown(); settle()
        let origin = panel.frame.origin
        menu.beginDrag()
        menu.drag(by: CGSize(width: -200, height: -150))
        menu.endDrag()
        XCTAssertTrue(menu.detached)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: origin.x - 200, y: origin.y - 150))
        XCTAssertTrue(panel.isVisible)
    }

    func testDraggingTornOffPanelJustMovesIt() {
        menu.park(.upperLeft); settle()
        let origin = panel.frame.origin
        menu.beginDrag()
        menu.drag(by: CGSize(width: 5, height: 5))
        menu.endDrag()
        XCTAssertTrue(menu.detached)
        XCTAssertEqual(panel.frame.origin, NSPoint(x: origin.x + 5, y: origin.y + 5))
    }

    // MARK: Park and shade

    func testParkUpperRightAndShade() {
        menu.park(.upperRight); settle()
        XCTAssertTrue(menu.detached)
        XCTAssertEqual(panel.frame.maxX, visibleFrame.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, visibleFrame.maxY - 8, accuracy: 0.5)
        let fullHeight = panel.frame.height

        menu.shaded = true; settle()
        XCTAssertLessThan(panel.frame.height, fullHeight - 100, "shading should roll the list and footer up")
        XCTAssertEqual(panel.frame.maxY, visibleFrame.maxY - 8, accuracy: 0.5, "top edge stays put")
        XCTAssertEqual(panel.frame.maxX, visibleFrame.maxX - 8, accuracy: 0.5)

        menu.shaded = false; settle()
        XCTAssertEqual(panel.frame.height, fullHeight, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, visibleFrame.maxY - 8, accuracy: 0.5)
    }

    func testHideClearsDetachedAndShaded() {
        menu.park(.lowerLeft)
        menu.shaded = true; settle()
        menu.hide()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(menu.detached)
        XCTAssertFalse(menu.shaded)
    }

    func testScriptPositionRoundTrips() {
        menu.scriptPosition = NSPoint(x: 200, y: 150); settle()
        XCTAssertTrue(menu.detached)
        XCTAssertEqual(menu.scriptPosition.x, 200, accuracy: 0.5)
        XCTAssertEqual(menu.scriptPosition.y, 150, accuracy: 0.5)
    }

    // MARK: Search and scroll

    func testSearchFiltersTheList() {
        menu.search = "rock"
        XCTAssertEqual(menu.visibleChannels.count, 30)
        XCTAssertTrue(menu.visibleChannels.allSatisfy { $0.category == "Rock" })
        menu.search = "remi"
        XCTAssertEqual(menu.visibleChannels.map(\.id), ["7"])
    }

    func testScrollToChannelAndBack() {
        menu.ensureShown(); settle()
        XCTAssertNotNil(menu.channelScrollView)
        XCTAssertGreaterThan(menu.rowHeight, 20)
        XCTAssertEqual(menu.topVisibleChannel?.id, "1")

        XCTAssertTrue(menu.scroll(to: "20")); settle(0.1)
        XCTAssertEqual(menu.topVisibleChannel?.id, "20")
        XCTAssertEqual(menu.scrollOffset, 19 * menu.rowHeight, accuracy: 1)

        menu.scrollOffset = 0; settle(0.1)
        XCTAssertEqual(menu.topVisibleChannel?.id, "1")

        menu.scrollOffset = 1_000_000; settle(0.1)   // clamped to the end
        XCTAssertLessThan(menu.scrollOffset, CGFloat(fake.count) * menu.rowHeight)
        XCTAssertFalse(menu.scroll(to: "nope"))
    }

    // MARK: AppleScript commands (through NSScriptCommand dispatch)

    func testScriptParkUpperRightShaded() {
        _ = script("Park", nil, ["corner": NSNumber(value: SPXCommand.code("SPUR")), "shaded": true]); settle()
        XCTAssertTrue(menu.detached)
        XCTAssertTrue(menu.shaded)
        XCTAssertEqual(panel.frame.maxX, visibleFrame.maxX - 8, accuracy: 0.5)
        XCTAssertEqual(panel.frame.maxY, visibleFrame.maxY - 8, accuracy: 0.5)
    }

    func testScriptDragMenu() {
        XCTAssertEqual(script("Drag", [NSNumber(value: 10), NSNumber(value: 10)]) as? Bool, false)
        XCTAssertEqual(script("Drag", [NSNumber(value: -300), NSNumber(value: 200)]) as? Bool, true)
    }

    func testScriptToggleShade() {
        XCTAssertEqual(script("Shad") as? Bool, true)
        XCTAssertTrue(menu.shaded)
        XCTAssertEqual(script("Shad") as? Bool, false)
        XCTAssertFalse(menu.shaded)
    }

    func testScriptScrollToChannel() {
        XCTAssertEqual(script("Scrl", "30") as? Bool, true); settle(0.1)
        XCTAssertEqual(menu.topVisibleChannel?.id, "30")
        XCTAssertEqual(script("Scrl", "999") as? Bool, false)
    }

    func testScriptSelectChannelOnlyFromVisibleRows() {
        menu.search = "rock"
        XCTAssertEqual(script("Selc", "3") as? Bool, false, "3 is Pop, not in the filtered list")
        XCTAssertNil(Radio.shared.current)
    }

    func testScriptSearchChannelsMatchesTheSearchField() {
        XCTAssertEqual(script("Srch", "remi") as? [String], ["7"])
    }

    func testScriptNowPlayingAndChannelInfo() {
        XCTAssertEqual(script("NowP", "7") as? String, "Remi Wolf – Champagne")
        XCTAssertEqual(script("Info", "7") as? String, "7\tChannel 7\tPop\tlive\tRemi Wolf\tChampagne")
        XCTAssertEqual(script("Info", "999") as? String, "")
    }

    func testScriptPlayUnknownChannelIsFalse() {
        XCTAssertEqual(script("Play", "999") as? Bool, false)
        XCTAssertEqual(script("Test", "999") as? String, "NO CHANNEL\t999")
    }

    func testScriptShowHideDetach() {
        _ = script("Show"); settle()
        XCTAssertTrue(panel.isVisible); XCTAssertFalse(menu.detached)
        _ = script("Dtch")
        XCTAssertTrue(menu.detached)
        _ = script("Hide")
        XCTAssertFalse(panel.isVisible)
    }

    // MARK: AppleScript properties (application KVC, as `get`/`set` uses them)

    func testScriptProperties() {
        NSApp.setValue("rock", forKey: "spSearchText")
        XCTAssertEqual(menu.search, "rock")
        XCTAssertEqual((NSApp.value(forKey: "spVisibleChannelNumbers") as? [String])?.count, 30)
        NSApp.setValue("", forKey: "spSearchText")

        NSApp.setValue(true, forKey: "spMenuShaded"); settle()
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(NSApp.value(forKey: "spMenuShaded") as? Bool, true)

        NSApp.setValue([300, 200], forKey: "spMenuPosition"); settle()
        XCTAssertEqual(NSApp.value(forKey: "spMenuPosition") as? [Int], [300, 200])
        XCTAssertEqual(NSApp.value(forKey: "spMenuDetached") as? Bool, true)
        XCTAssertEqual((NSApp.value(forKey: "spMenuSize") as? [Int])?.first, Int(panel.frame.width.rounded()))

        NSApp.setValue(false, forKey: "spMenuShaded"); settle()
        NSApp.setValue(0, forKey: "spScrollPosition"); settle(0.1)
        XCTAssertEqual(NSApp.value(forKey: "spTopVisibleChannel") as? String, "1")
        XCTAssertEqual((NSApp.value(forKey: "spChannelNumbers") as? [String])?.count, 60)
        XCTAssertEqual(NSApp.value(forKey: "spSignedIn") as? Bool, true)
    }

    func testScriptPanelView() {
        let view = { (NSApp.value(forKey: "spPanelView") as? NSNumber)?.uint32Value }
        XCTAssertEqual(view(), SPXCommand.code("SPV0"))
        NSApp.setValue(NSNumber(value: SPXCommand.code("SPV1")), forKey: "spPanelView")
        XCTAssertTrue(menu.lyrics)
        XCTAssertEqual(view(), SPXCommand.code("SPV1"))
        // No art for the (no) current channel: album art is refused, the lyrics stay.
        NSApp.setValue(NSNumber(value: SPXCommand.code("SPV2")), forKey: "spPanelView")
        XCTAssertEqual(view(), SPXCommand.code("SPV1"))
        NSApp.setValue(NSNumber(value: SPXCommand.code("SPV0")), forKey: "spPanelView")
        XCTAssertFalse(menu.lyrics)
        XCTAssertEqual(view(), SPXCommand.code("SPV0"))
    }

    func testScriptCategoryChips() {
        let chips = NSApp.value(forKey: "spCategoryChips") as? [String] ?? []
        XCTAssertFalse(chips.isEmpty)
        guard let chip = chips.first else { return }
        NSApp.setValue(chip.uppercased(), forKey: "spCategoryChip")   // matched case-insensitively
        XCTAssertEqual(NSApp.value(forKey: "spCategoryChip") as? String, chip)
        XCTAssertEqual(NSApp.value(forKey: "spVisibleChannelNumbers") as? [String],
                       ChannelGroup.filter(fake, group: chip, sub: nil).map(\.id))
        let subs = NSApp.value(forKey: "spSubcategoryChips") as? [String] ?? []
        if let sub = subs.first {
            NSApp.setValue(sub, forKey: "spSubcategoryChip")
            XCTAssertEqual(NSApp.value(forKey: "spSubcategoryChip") as? String, sub)
        }
        NSApp.setValue("no such chip", forKey: "spCategoryChip")      // ignored
        XCTAssertEqual(NSApp.value(forKey: "spCategoryChip") as? String, chip)
        NSApp.setValue("", forKey: "spCategoryChip")
        XCTAssertEqual(NSApp.value(forKey: "spCategoryChip") as? String, "")
        XCTAssertEqual(NSApp.value(forKey: "spSubcategoryChip") as? String, "")
        XCTAssertEqual((NSApp.value(forKey: "spVisibleChannelNumbers") as? [String])?.count, 60)
    }
}
