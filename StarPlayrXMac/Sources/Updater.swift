//
//  Updater.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/3/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import AppKit
import Security

/// Keeps StarPlayrX up to date from the GitHub releases (tags `mac-X.Y.Z`, zip asset).
/// A newer version is offered once: Update (download, verify the Developer ID signature, swap the
/// bundle in place and relaunch), Remind Me in 1 Hour, or No Thanks (that version is never offered again).
@MainActor
final class Updater: NSObject {
    static let shared = Updater()

    static let releasesAPI = URL(string: "https://api.github.com/repos/AgentiLoop/StarPlayrX/releases?per_page=30")!
    static let releasesPage = URL(string: "https://github.com/AgentiLoop/StarPlayrX/releases")!
    /// What a downloaded app must satisfy before it replaces this one.
    static let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"469UCUB275\" and identifier \"com.starplayrx.mac\""

    static let checkInterval: TimeInterval = 6 * 3600
    static let snoozeInterval: TimeInterval = 3600

    struct Release: Equatable {
        let version: String
        let notes: String
        let zip: URL
        let page: URL
    }

    enum UpdateError: LocalizedError {
        case notWritable(String), noApp, badSignature(OSStatus), unzip(Int32)
        var errorDescription: String? {
            switch self {
            case .notWritable(let path): return "StarPlayrX can't replace itself in \(path). Download the update and drag it to Applications."
            case .noApp: return "The download didn't contain StarPlayrX.app."
            case .badSignature(let s): return "The downloaded app isn't signed by StarPlayrX's developer (code \(s)). It was not installed."
            case .unzip(let s): return "The download couldn't be unpacked (ditto exited \(s))."
            }
        }
    }

    private(set) var busy = false
    private var timer: Timer?
    private var snooze: Timer?

    /// Current version from the bundle ("1.1.15").
    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var defaults: UserDefaults { .standard }
    /// The version the user said No Thanks to: never offered again (a newer one is).
    private var skippedVersion: String? {
        get { defaults.string(forKey: "updateSkippedVersion") }
        set { defaults.set(newValue, forKey: "updateSkippedVersion") }
    }
    private var snoozedUntil: Date? {
        get { defaults.object(forKey: "updateSnoozedUntil") as? Date }
        set { defaults.set(newValue, forKey: "updateSnoozedUntil") }
    }
    /// `defaults write com.starplayrx.mac updatePrereleases -bool YES` to be offered pre-releases too.
    var includesPrereleases: Bool { defaults.bool(forKey: "updatePrereleases") }

    /// First check shortly after launch, then every 6 hours. A snooze that is still running
    /// from the last session is honored (the check after it fires asks again).
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(interactive: false) }
        }
        timer?.tolerance = 300
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            await check(interactive: false)
        }
    }

    /// Looks for a newer release and offers it. Returns its version ("" when up to date).
    /// Automatic checks respect No Thanks and a running snooze; an interactive one (the script
    /// command) always asks, and says so when there is nothing newer.
    @discardableResult
    func check(interactive: Bool) async -> String {
        guard !busy else { return "" }
        busy = true
        defer { busy = false }
        let release: Release?
        do {
            release = try await Self.newestRelease(newerThan: Self.installedVersion, prereleases: includesPrereleases)
        } catch {
            if interactive { await UpdatePrompt.ask(title: "Couldn't check for updates", message: error.localizedDescription, buttons: ["OK"]) }
            return ""
        }
        guard let release else {
            if interactive {
                await UpdatePrompt.ask(title: "You're up to date", message: "StarPlayrX \(Self.installedVersion) is the newest version.", buttons: ["OK"])
            }
            return ""
        }
        if !interactive {
            if release.version == skippedVersion { return release.version }
            if let until = snoozedUntil, until > Date() { scheduleSnooze(until); return release.version }
        }
        await offer(release)
        return release.version
    }

    private func offer(_ release: Release) async {
        var message = "You have StarPlayrX \(Self.installedVersion). Would you like to update now?"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { message += "\n\n" + String(notes.prefix(600)) }
        switch await UpdatePrompt.ask(title: "StarPlayrX \(release.version) is available", message: message,
                                      buttons: ["Update", "Remind Me in 1 Hour", "No Thanks"]) {
        case 0:
            skippedVersion = nil
            snoozedUntil = nil
            await install(release)
        case 1:
            scheduleSnooze(Date().addingTimeInterval(Self.snoozeInterval))
        default:
            skippedVersion = release.version
            snoozedUntil = nil
        }
    }

    private func scheduleSnooze(_ until: Date) {
        snoozedUntil = until
        snooze?.invalidate()
        snooze = Timer.scheduledTimer(withTimeInterval: max(until.timeIntervalSinceNow, 1), repeats: false) { _ in
            Task { @MainActor in
                Updater.shared.snoozedUntil = nil
                await Updater.shared.check(interactive: false)
            }
        }
    }

    // MARK: Releases

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        let tag_name: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let html_url: URL
        let assets: [Asset]
    }

    /// The highest `mac-X.Y.Z` release above `current` that has a zip, or nil.
    nonisolated static func newestRelease(newerThan current: String, prereleases: Bool) async throws -> Release? {
        var request = URLRequest(url: releasesAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        return pick(releases.map { (tag: $0.tag_name, draft: $0.draft, prerelease: $0.prerelease, notes: $0.body ?? "", page: $0.html_url,
                                    zip: $0.assets.first { $0.name.hasPrefix("StarPlayrX-Mac-") && $0.name.hasSuffix(".zip") }?.browser_download_url) },
                    newerThan: current, prereleases: prereleases)
    }

    nonisolated static func pick(_ releases: [(tag: String, draft: Bool, prerelease: Bool, notes: String, page: URL, zip: URL?)],
                     newerThan current: String, prereleases: Bool) -> Release? {
        releases.compactMap { r -> Release? in
            guard !r.draft, prereleases || !r.prerelease, r.tag.hasPrefix("mac-"), let zip = r.zip else { return nil }
            let version = String(r.tag.dropFirst(4))
            guard isVersion(version, newerThan: current) else { return nil }
            return Release(version: version, notes: r.notes, zip: zip, page: r.page)
        }
        .max { isVersion($1.version, newerThan: $0.version) }
    }

    /// "1.1.16" > "1.1.15", "1.2" > "1.1.99"; anything non-numeric is not a version (never newer).
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let p = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return p.allSatisfy { $0 != nil } ? p.map { $0! } : nil
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        let n = max(x.count, y.count)
        let xs = x + Array(repeating: 0, count: n - x.count)
        let ys = y + Array(repeating: 0, count: n - y.count)
        return xs.lexicographicallyPrecedes(ys) == false && xs != ys
    }

    // MARK: Install

    /// Download → unzip → verify signature → swap bundles → relaunch. Any failure is reported, with
    /// the release page as the fallback, and leaves the installed app untouched.
    private func install(_ release: Release) async {
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let progress = ProgressWindow(title: "Downloading StarPlayrX \(release.version)…")
        progress.show()
        defer { progress.close() }
        var stage: URL?
        do {
            let folder = current.deletingLastPathComponent()
            guard fm.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
            // Same volume as the app, so the final moves are renames.
            let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
            stage = dir
            let zip = dir.appendingPathComponent("update.zip")
            let (tmp, _) = try await URLSession.shared.download(for: URLRequest(url: release.zip), delegate: progress)
            try fm.moveItem(at: tmp, to: zip)

            progress.set(text: "Installing StarPlayrX \(release.version)…", indeterminate: true)
            let unpacked = dir.appendingPathComponent("unpacked", isDirectory: true)
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw UpdateError.unzip(ditto.terminationStatus) }
            guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noApp }
            try Self.verify(app)

            let old = dir.appendingPathComponent("old.app")
            try fm.moveItem(at: current, to: old)
            do {
                try fm.moveItem(at: app, to: current)
            } catch {
                try? fm.moveItem(at: old, to: current)
                throw error
            }
            try? fm.removeItem(at: dir)
            relaunch(current)
        } catch {
            if let stage { try? fm.removeItem(at: stage) }
            progress.close()
            if await UpdatePrompt.ask(title: "The update couldn't be installed", message: error.localizedDescription,
                                      buttons: ["OK", "Open Download Page"]) == 1 {
                NSWorkspace.shared.open(release.page)
            }
        }
    }

    /// Developer ID signed by this app's team, same bundle identifier, every nested piece intact.
    static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.badSignature(status) }
        status = SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.badSignature(status) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate))
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.badSignature(status) }
    }

    /// A detached shell waits for this process to exit, then opens the new app at the same path.
    private func relaunch(_ app: URL) {
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? sh.run()
        NSApp.terminate(nil)
    }
}

/// Icon, title, message and up to three buttons (the first is the default, the last takes Esc),
/// shown without `runModal()` for the same reason as CredentialPrompt. Returns the button index.
@MainActor
enum UpdatePrompt {
    @discardableResult
    static func ask(title: String, message: String, buttons: [String]) async -> Int {
        let width: CGFloat = 400, margin: CGFloat = 20
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: 0))
        var views: [NSView] = []
        var x = width + margin
        var controls: [NSButton] = []
        for (i, name) in buttons.enumerated() {
            let b = NSButton(title: name, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.sizeToFit()
            b.frame.size.width = max(b.frame.width + 16, 90)
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: margin)
            x -= 8
            b.tag = i
            if i == 0 { b.keyEquivalent = "\r" }
            if i == buttons.count - 1, buttons.count > 1 { b.keyEquivalent = "\u{1b}" }
            controls.append(b)
            views.append(b)
        }
        var y = margin + 32 + 20
        let info = NSTextField(wrappingLabelWithString: message)
        info.isSelectable = false
        let infoHeight = info.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 40
        info.frame = NSRect(x: margin, y: y, width: width, height: infoHeight)
        y += infoHeight + 10
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.sizeToFit()
        heading.frame.origin = NSPoint(x: margin, y: y)
        y += heading.frame.height + 14
        let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 64, height: 64))
        icon.image = NSApp.applicationIconImage
        icon.setAccessibilityElement(false)   // decoration: the heading says what this is about
        y += 64 + 28
        content.frame.size.height = y
        for v in views + [info, heading, icon] {
            v.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(v)
        }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        window.contentView = content
        window.level = .modalPanel
        window.center()
        // Keyboard and VoiceOver start on the default button (Update / OK).
        window.initialFirstResponder = controls.first
        let responder = Responder(window: window)
        for b in controls {
            b.target = responder
            b.action = #selector(Responder.pressed(_:))
        }
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            responder.continuation = continuation
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private final class Responder: NSObject {
        let window: NSWindow
        var continuation: CheckedContinuation<Int, Never>?
        private var retainSelf: Responder?

        init(window: NSWindow) {
            self.window = window
            super.init()
            retainSelf = self
        }

        @objc func pressed(_ sender: NSButton) {
            window.orderOut(nil)
            continuation?.resume(returning: sender.tag)
            continuation = nil
            retainSelf = nil
        }
    }
}

/// Small floating "Downloading… / Installing…" window; also the download's progress delegate.
final class ProgressWindow: NSObject, URLSessionDownloadDelegate {
    private let window: NSWindow
    private let label: NSTextField
    private let bar: NSProgressIndicator

    @MainActor
    init(title: String) {
        let width: CGFloat = 320, margin: CGFloat = 20
        label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: margin, y: margin + 28, width: width, height: 20)
        bar = NSProgressIndicator(frame: NSRect(x: margin, y: margin, width: width, height: 20))
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true
        bar.setAccessibilityLabel(title)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: margin * 2 + 48 + 10))
        for v in [label, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            content.addSubview(v)
        }
        window = NSWindow(contentRect: content.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.level = .modalPanel
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
        super.init()
    }

    @MainActor func show() {
        window.center()
        bar.startAnimation(nil)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor func close() { window.orderOut(nil) }

    @MainActor func set(text: String, indeterminate: Bool) {
        label.stringValue = text
        window.title = text
        bar.setAccessibilityLabel(text)
        bar.isIndeterminate = indeterminate
        if indeterminate { bar.startAnimation(nil) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            bar.isIndeterminate = false
            bar.doubleValue = fraction
        }
    }

    // The async download(for:) API hands back the file itself; nothing to do here.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
