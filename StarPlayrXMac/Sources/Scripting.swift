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
        "spScrollPosition", "spTopVisibleChannel"]

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
        get { menu.panel?.isVisible ?? false }
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
        let channel = radio.channels.first { $0.id == arg }

        switch commandDescription.commandName {
        case "play channel":
            guard let channel else { return false }
            radio.play(channel)
            return true
        case "stop":
            radio.stop()
        case "resume":
            guard let current = radio.current else { return false }
            radio.play(current)
            return true
        case "toggle playback":
            radio.togglePlayPause()
        case "sign in":
            let user = evaluatedArguments?["user"] as? String
            let pass = evaluatedArguments?["password"] as? String
            guard let creds = user.map({ ($0, pass ?? "") }) ?? Keychain.load().map({ ($0.user, $0.pass) }) else {
                return fail("No user given and no credentials in the Keychain.")
            }
            return later { await radio.login(user: creds.0, pass: creds.1) }
        case "sign out":
            radio.signOut()
        case "refresh now playing":
            return later { await radio.updatePDT(); return nil }
        case "now playing":
            return radio.nowPlaying[arg].map(Self.format) ?? ""
        case "channel info":
            guard let channel else { return "" }
            let np = radio.nowPlaying[channel.id]
            return [channel.id, channel.name, channel.category, channel.xtraID != nil ? "xtra" : "live",
                    np?.artist ?? "", np?.song ?? ""].joined(separator: "\t")
        case "search channels":
            return Channel.filter(radio.channels, nowPlaying: radio.nowPlaying, search: arg).map(\.id)
        case "select channel":
            // A click on the row: only channels the list is showing (after the search field).
            guard let row = menu.visibleChannels.first(where: { $0.id == arg }) else { return false }
            radio.play(row)
            return true
        case "scroll to channel":
            menu.ensureShown()
            return menu.scroll(to: arg)
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
            guard let channel else { return "NO CHANNEL\t\(arg)" }
            let wait = (evaluatedArguments?["wait"] as? Int) ?? 30
            let shown = radio.nowPlaying[channel.id].map(Self.format) ?? ""
            radio.play(channel)
            return later {
                let deadline = Date().addingTimeInterval(TimeInterval(wait))
                while radio.playingNow == nil, radio.current == channel, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                guard let playing = radio.playingNow, radio.current == channel else {
                    return "TIMEOUT\t\(channel.id)\t\(shown)\t"
                }
                let played = Self.format(playing)
                return "\(played == shown ? "MATCH" : "MISMATCH")\t\(channel.id)\t\(shown)\t\(played)"
            }
        case "show menu":
            if !(menu.panel?.isVisible ?? false) || menu.detached { menu.statusItemClicked() }
        case "hide menu":
            menu.hide()
        case "detach menu":
            if !(menu.panel?.isVisible ?? false) { menu.statusItemClicked() }
            menu.detach()
        default:
            return fail("Unknown command \(commandDescription.commandName).")
        }
        return nil
    }

    private static func format(_ np: NowPlaying) -> String { "\(np.artist) – \(np.song)" }

    static func code(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func fail(_ message: String) -> Any? {
        scriptErrorNumber = -10000
        scriptErrorString = message
        return nil
    }

    /// Suspends the Apple Event until `work` finishes, so the script gets the real result.
    @MainActor
    private func later(_ work: @escaping @MainActor () async -> Any?) -> Any? {
        suspendExecution()
        Task { @MainActor in
            let result = await work()
            resumeExecution(withResult: result)
        }
        return nil
    }
}
