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
}
