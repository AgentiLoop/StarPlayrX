//
//  Scripting.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/1/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import AppKit

/// AppleScript (Cocoa Scripting) support. Terminology is in StarPlayrX.sdef, enabled by
/// NSAppleScriptEnabled + OSAScriptingDefinition in Info.plist. Application properties are
/// KVC keys handled by AppDelegate; every command is an SPXCommand, dispatched by name.
@MainActor
extension AppDelegate {
    private static let scriptingKeys: Set<String> = [
        "spSignedIn", "spBusy", "spPlaying", "spStatus", "spCanada",
        "spCurrentChannel", "spCurrentChannelName", "spCurrentXtra",
        "spShownArtist", "spShownSong", "spPlayingArtist", "spPlayingSong",
        "spChannelNumbers", "spXtraChannelNumbers", "spLiveChannelNumbers",
        "spMenuVisible", "spMenuDetached", "spMenuShaded",
        "spMenuPosition", "spMenuSize", "spSearchText", "spVisibleChannelNumbers",
        "spScrollPosition", "spTopVisibleChannel",
        "spVersion", "spChannelsLoaded", "spAudioStarted", "spCurrentChannelCategory", "spCategories",
        "spShownArtwork", "spCurrentChannelLogo", "spShowArt", "spBubbleMode", "spModernLive", "spModernSignIn",
        "spPreset", "spPresetChannelNumbers", "spStarsOnly"]

    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        Self.scriptingKeys.contains(key)
    }

    private var radio: Radio { Radio.shared }
    private var menu: MenuController { MenuController.shared }

    @objc var spSignedIn: Bool { radio.isLoggedIn }
    @objc var spBusy: Bool { radio.isBusy }
    @objc var spPlaying: Bool { radio.isPlaying }
    @objc var spStatus: String { radio.status }

    @objc var spCanada: Bool {
        get { radio.localeIsCA }
        set { radio.setRegion(ca: newValue) }
    }

    @objc var spCurrentChannel: String {
        get { radio.current?.id ?? "" }
        set { if let ch = radio.channels.first(where: { $0.id == newValue }) { radio.play(ch) } }
    }

    @objc var spCurrentChannelName: String { radio.current?.name ?? "" }
    @objc var spCurrentXtra: Bool { radio.current?.xtraID != nil }
    @objc var spShownArtist: String { radio.current.flatMap { radio.nowPlaying[$0.id] }?.artist ?? "" }
    @objc var spShownSong: String { radio.current.flatMap { radio.nowPlaying[$0.id] }?.song ?? "" }
    @objc var spPlayingArtist: String { radio.playingNow?.artist ?? "" }
    @objc var spPlayingSong: String { radio.playingNow?.song ?? "" }
    @objc var spChannelNumbers: [String] { radio.channels.map(\.id) }
    @objc var spXtraChannelNumbers: [String] { radio.channels.filter { $0.xtraID != nil }.map(\.id) }
    @objc var spLiveChannelNumbers: [String] { radio.channels.filter { $0.xtraID == nil }.map(\.id) }

    @objc var spMenuVisible: Bool {
        get { menu.panel.isVisible }
        set { if newValue != spMenuVisible { newValue ? menu.statusItemClicked() : menu.hide() } }
    }

    @objc var spMenuDetached: Bool {
        get { menu.detached }
        set {
            guard newValue != menu.detached else { return }
            if newValue {
                if !spMenuVisible { menu.statusItemClicked() }
                menu.detach()
            } else {
                menu.hide()
                menu.statusItemClicked()
            }
        }
    }

    @objc var spMenuShaded: Bool {
        get { menu.shaded }
        set {
            menu.ensureShown()
            menu.shaded = newValue
        }
    }

    /// {x, y} of the panel's top-left corner, AppleScript screen coordinates (y down from the top).
    @objc var spMenuPosition: [Int] {
        get { let p = menu.scriptPosition; return [Int(p.x.rounded()), Int(p.y.rounded())] }
        set {
            guard newValue.count == 2 else { return }
            menu.scriptPosition = NSPoint(x: newValue[0], y: newValue[1])
        }
    }

    @objc var spMenuSize: [Int] {
        [Int(menu.panel.frame.width.rounded()), Int(menu.panel.frame.height.rounded())]
    }

    @objc var spSearchText: String {
        get { menu.search }
        set { menu.search = newValue }
    }

    @objc var spVisibleChannelNumbers: [String] { menu.visibleChannels.map(\.id) }

    @objc var spScrollPosition: Int {
        get { Int(menu.scrollOffset.rounded()) }
        set { menu.scrollOffset = CGFloat(newValue) }
    }

    @objc var spTopVisibleChannel: String { menu.topVisibleChannel?.id ?? "" }
    @objc var spVersion: String { String(MenuView.version.dropFirst()) }   // "v1.1.13-dev" -> "1.1.13-dev"
    @objc var spChannelsLoaded: Bool { radio.channelsLoaded }
    @objc var spAudioStarted: Bool { radio.audioStarted }
    @objc var spCurrentChannelCategory: String { radio.current?.category ?? "" }
    @objc var spCategories: [String] {
        var seen = Set<String>()
        return radio.channels.map(\.category).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    @objc var spShownArtwork: String { radio.current.flatMap { radio.displayed($0.id) }?.image ?? "" }
    @objc var spCurrentChannelLogo: String { radio.current?.imageURL ?? "" }
    @objc var spShowArt: Bool {
        get { radio.current.map { radio.showArtChannels.contains($0.id) } ?? false }
        set { if let id = radio.current?.id, newValue != spShowArt { radio.toggleShowArt(id) } }
    }
    /// Four-char enumerator codes SPB0 / SPB1 / SPB2 = bubbleStage 0 / 1 / 2 (Visualizer's @AppStorage).
    @objc var spBubbleMode: NSNumber {
        get { NSNumber(value: SPXCommand.code("SPB\(Self.bubbleStage)")) }
        set {
            for i in 0..<3 where SPXCommand.code("SPB\(i)") == newValue.uint32Value { Self.bubbleStage = i }
        }
    }
    static var bubbleStage: Int {
        get { UserDefaults.standard.object(forKey: "bubbleStage") as? Int ?? 1 }
        set { UserDefaults.standard.set(newValue % 3, forKey: "bubbleStage") }
    }
    @objc var spModernLive: Bool {
        get { radio.modernLive || radio.modernLogin }
        set { if !radio.modernLogin, newValue != radio.modernLive { radio.setModernLive(newValue) } }
    }
    @objc var spModernSignIn: Bool { radio.modernLogin }
    @objc var spPreset: Bool {
        get { radio.current.map { radio.presets.contains($0.id) } ?? false }
        set { if let id = radio.current?.id, newValue != spPreset { radio.togglePreset(id) } }
    }
    @objc var spPresetChannelNumbers: [String] { radio.channels.filter { radio.presets.contains($0.id) }.map(\.id) }
    @objc var spStarsOnly: Bool {
        get { menu.starsOnly }
        set { menu.starsOnly = newValue }
    }
}

/// A script error with a message (raised to AppleScript as error -10000).
struct ScriptFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

@objc(SPXCommand)
final class SPXCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { perform() }
    }

    @MainActor
    private func perform() -> Any? {
        let radio = Radio.shared
        let menu = MenuController.shared
        let arg = (directParameter as? String)?.trimmingCharacters(in: .whitespaces) ?? ""

        switch commandDescription.commandName {
        case "play channel":
            // Returns only once the channel is really playing and both the list (PDT) and the
            // player know the song, so a following `get shown …` / `get playing …` has real data.
            return playWhenReady { radio.channels.first { $0.id == arg } }
        case "stop":
            radio.stop()
        case "resume":
            return playWhenReady { radio.current }
        case "toggle playback":
            radio.togglePlayPause()
        case "sign in":
            let user = evaluatedArguments?["user"] as? String
            let pass = evaluatedArguments?["password"] as? String
            let modern = evaluatedArguments?["modern"] as? Bool
            guard let creds = user.map({ ($0, pass ?? "") }) ?? Keychain.load().map({ ($0.user, $0.pass) }) else {
                return fail("No user given and no credentials in the Keychain.")
            }
            return later {
                guard await radio.login(user: creds.0, pass: creds.1, modern: modern) else { throw ScriptFailure(radio.status) }
                try await Self.ready()
                return true
            }
        case "sign out":
            radio.signOut()
        case "wait until ready":
            let wait = (evaluatedArguments?["wait"] as? Int) ?? 60
            return later { try await Self.ready(timeout: TimeInterval(wait)); return true }
        case "refresh now playing":
            return later { try await Self.ready(); await radio.updatePDT(); return nil }
        case "now playing":
            return whenReady { radio.nowPlaying[arg].map(Self.format) ?? "" }
        case "channel info":
            return whenReady {
                guard let channel = radio.channels.first(where: { $0.id == arg }) else { return "" }
                let np = radio.nowPlaying[channel.id]
                return [channel.id, channel.name, channel.category, channel.xtraID != nil ? "xtra" : "live",
                        np?.artist ?? "", np?.song ?? ""].joined(separator: "\t")
            }
        case "channel name":
            return whenReady { radio.channels.first { $0.id == arg }?.name ?? "" }
        case "channel logo":
            return whenReady { radio.channels.first { $0.id == arg }?.imageURL ?? "" }
        case "artwork of":
            return whenReady { radio.displayed(arg)?.image ?? "" }
        case "channels in category":
            return whenReady { radio.channels.filter { $0.category.caseInsensitiveCompare(arg) == .orderedSame }.map(\.id) }
        case "search channels":
            return whenReady { Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: arg).map(\.id) }
        case "next channel", "previous channel":
            // Step through the list as the panel shows it (search text applied), wrapping at the ends.
            let step = commandDescription.commandName == "next channel" ? 1 : -1
            let list = Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: menu.search,
                                      stars: menu.starsOnly ? radio.presets : nil)
            guard let current = radio.current, let i = list.firstIndex(where: { $0.id == current.id }), !list.isEmpty else { return "" }
            let target = list[(i + step + list.count) % list.count]
            return later {
                try await Self.ready()
                try await Self.play(target)
                return target.id
            }
        case "toggle show art":
            guard let id = radio.current?.id else { return false }
            return radio.toggleShowArt(id)
        case "toggle preset":
            // The star: the channel given, or the current one, in or out of the presets.
            guard let id = arg.isEmpty ? radio.current?.id : radio.channels.first(where: { $0.id == arg })?.id else {
                return fail(arg.isEmpty ? "No current channel." : "No channel \(arg).")
            }
            radio.togglePreset(id)
            return radio.presets.contains(id)
        case "toggle bubbles":
            AppDelegate.bubbleStage = (AppDelegate.bubbleStage + 1) % 3
            return NSNumber(value: Self.code("SPB\(AppDelegate.bubbleStage)"))
        case "select channel":
            // A click on the row: only channels the list is showing (after the search field).
            return playWhenReady { menu.visibleChannels.first { $0.id == arg } }
        case "scroll to channel":
            return whenReady {
                menu.ensureShown()
                return menu.scroll(to: arg)
            }
        case "drag menu":
            // Same steps as dragging the header with the mouse: far enough tears it off, else it snaps back.
            guard let by = directParameter as? [NSNumber], by.count == 2 else { return fail("Give {dx, dy}.") }
            menu.ensureShown()
            menu.beginDrag()
            menu.drag(by: CGSize(width: by[0].doubleValue, height: -by[1].doubleValue))
            menu.endDrag()
            return menu.detached
        case "park menu":
            let code = (evaluatedArguments?["corner"] as? NSNumber)?.uint32Value
            let corners: [UInt32: MenuController.Corner] = [
                Self.code("SPUL"): .upperLeft, Self.code("SPUR"): .upperRight,
                Self.code("SPLL"): .lowerLeft, Self.code("SPLR"): .lowerRight]
            menu.park(code.flatMap { corners[$0] } ?? .upperRight)
            if let shaded = evaluatedArguments?["shaded"] as? Bool { menu.shaded = shaded }
        case "toggle shade":
            menu.ensureShown()
            menu.shaded.toggle()
            return menu.shaded
        case "test channel":
            let wait = (evaluatedArguments?["wait"] as? Int) ?? 30
            if Self.isReady, !radio.channels.contains(where: { $0.id == arg }) { return "NO CHANNEL\t\(arg)" }
            return later {
                try await Self.ready()
                guard let channel = radio.channels.first(where: { $0.id == arg }) else { return "NO CHANNEL\t\(arg)" }
                let shown = radio.nowPlaying[channel.id].map(Self.format) ?? ""
                guard !shown.isEmpty else { throw ScriptFailure("The list shows nothing for channel \(channel.id) yet.") }
                do {
                    try await Self.play(channel, timeout: TimeInterval(wait))
                } catch {
                    return "TIMEOUT\t\(channel.id)\t\(shown)\t"
                }
                let played = radio.playingNow.map(Self.format) ?? ""
                return "\(played == shown ? "MATCH" : "MISMATCH")\t\(channel.id)\t\(shown)\t\(played)"
            }
        case "show menu":
            if !(menu.panel.isVisible) || menu.detached { menu.statusItemClicked() }
        case "hide menu":
            menu.hide()
        case "detach menu":
            if !(menu.panel.isVisible) { menu.statusItemClicked() }
            menu.detach()
        case "reattach menu":
            if menu.detached { menu.hide(); menu.statusItemClicked() }
        default:
            return fail("Unknown command \(commandDescription.commandName).")
        }
        return nil
    }

    private static func format(_ np: NowPlaying) -> String { "\(np.artist) – \(np.song)" }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    @MainActor
    static var isReady: Bool {
        let radio = Radio.shared
        return radio.isLoggedIn && radio.channelsLoaded && !radio.isBusy
    }

    /// Waits until StarPlayrX is signed in with every channel loaded (Xtra included), e.g. right
    /// after launch while the Keychain sign-in is still running. Throws if that doesn't happen.
    @MainActor
    static func ready(timeout: TimeInterval = 60) async throws {
        let radio = Radio.shared
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady {
            guard Date() < deadline else {
                throw ScriptFailure("StarPlayrX isn't ready (\(radio.status)). Sign in first.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Tunes `channel` and waits until audio is actually coming out and both what the list shows
    /// (PDT) and what plays are known. Throws if that doesn't happen in time.
    @MainActor
    static func play(_ channel: Channel, timeout: TimeInterval = 30) async throws {
        let radio = Radio.shared
        radio.play(channel)
        let deadline = Date().addingTimeInterval(timeout)
        while !(radio.audioStarted && radio.playingNow != nil && radio.nowPlaying[channel.id] != nil) {
            guard radio.current?.id == channel.id else {
                throw ScriptFailure("Channel \(channel.id) was replaced by another channel before it started.")
            }
            guard Date() < deadline else {
                throw ScriptFailure("Channel \(channel.id) didn't start playing within \(Int(timeout)) seconds.")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Runs `body` now when StarPlayrX is ready, else suspends the Apple Event until it is
    /// (an error if it never gets there), so nothing answers from a half-loaded channel list.
    @MainActor
    private func whenReady(_ body: @escaping @MainActor () -> Any?) -> Any? {
        Self.isReady ? body() : later { try await Self.ready(); return body() }
    }

    /// Waits until ready, plays the channel `pick` returns and waits until it really plays.
    /// Returns false (right away when ready) if there is no such channel.
    @MainActor
    private func playWhenReady(_ pick: @escaping @MainActor () -> Channel?) -> Any? {
        if Self.isReady, pick() == nil { return false }
        return later {
            try await Self.ready()
            guard let channel = pick() else { return false }
            try await Self.play(channel)
            return true
        }
    }

    private func fail(_ message: String) -> Any? {
        scriptErrorNumber = -10000
        scriptErrorString = message
        return nil
    }

    /// Suspends the Apple Event until `work` finishes, so the script gets the real result.
    /// A thrown error becomes an AppleScript error instead of a false or empty result.
    @MainActor
    private func later(_ work: @escaping @MainActor () async throws -> Any?) -> Any? {
        suspendExecution()
        Task { @MainActor in
            do {
                resumeExecution(withResult: try await work())
            } catch {
                scriptErrorNumber = -10000
                scriptErrorString = (error as? ScriptFailure)?.message ?? error.localizedDescription
                resumeExecution(withResult: nil)
            }
        }
        return nil
    }
}
