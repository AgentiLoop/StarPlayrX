//
//  StarPlayrXMacApp.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import AppKit

@main
struct StarPlayrXMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The menu bar item and its panel are our own (MenuController), so the same window
    // can be used both under the menu bar and torn off. SwiftUI just needs a scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MenuController.shared.install()
        // Hosting unit tests: no network sign-in or password prompt.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        Updater.shared.start()
        LyricSync.shared.start()
        Task { @MainActor in
            if let saved = Keychain.load(), await Radio.shared.login(user: saved.user, pass: saved.pass) {
                return
            }
            await CredentialPrompt.signIn()
        }
    }
}

/// Native username / password prompt. Credentials go straight from this dialog to the Keychain.
/// Laid out by hand (not NSAlert, which re-lays out its buttons): Cancel and Sign In each take half
/// the width, and there is room under the password field for its autofill popup to drop into.
@MainActor
enum CredentialPrompt {
    static func signIn() async {
        var message = "Sign in with your SiriusXM account.\n\nYour username and password are kept only in your Mac's Keychain."
        while true {
            let width: CGFloat = 320, margin: CGFloat = 20, gap: CGFloat = 12
            let content = NSView(frame: NSRect(x: 0, y: 0, width: width + 2 * margin, height: 0))

            // Bottom up. Buttons: half the width each.
            let half = (width - gap) / 2
            let cancel = NSButton(title: "Cancel", target: nil, action: nil)
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"
            cancel.frame = NSRect(x: margin, y: margin, width: half, height: 32)
            let signIn = NSButton(title: "Sign In", target: nil, action: nil)
            signIn.bezelStyle = .rounded
            signIn.keyEquivalent = "\r"
            signIn.frame = NSRect(x: margin + half + gap, y: margin, width: half, height: 32)
            // The password field's autofill popup drops ~70 pt below the field; keep the buttons clear of it.
            // The Canada checkbox sits in that gap, flush right (the popup opens on the left), a bit above the buttons.
            var y = margin + 32 + 60
            let canada = NSButton(checkboxWithTitle: "Canada", target: nil, action: nil)
            canada.sizeToFit()
            canada.state = Radio.shared.localeIsCA ? .on : .off
            canada.frame.origin = NSPoint(x: margin + width - canada.frame.width, y: y - 30)
            y += canada.frame.height + 10
            let pass = NSSecureTextField(frame: NSRect(x: margin, y: y, width: width, height: 24))
            pass.placeholderString = "Password"
            pass.setAccessibilityLabel("Password")
            y += 24 + 10
            let user = NSTextField(frame: NSRect(x: margin, y: y, width: width, height: 24))
            user.placeholderString = "Username or email"
            user.setAccessibilityLabel("Username or email")
            user.stringValue = Keychain.load()?.user ?? ""
            y += 24 + 16
            let info = NSTextField(wrappingLabelWithString: message)
            info.isSelectable = false
            let infoHeight = info.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 40
            info.frame = NSRect(x: margin, y: y, width: width, height: infoHeight)
            y += infoHeight + 10
            let title = NSTextField(labelWithString: "Sign in to StarPlayrX")
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            title.sizeToFit()
            title.frame.origin = NSPoint(x: margin, y: y)
            y += title.frame.height + 14
            let icon = NSImageView(frame: NSRect(x: margin, y: y, width: 64, height: 64))
            icon.image = NSApp.applicationIconImage
            icon.setAccessibilityElement(false)   // decoration: the title says which app this is
            y += 64 + 28   // top margin includes the (hidden) title bar
            content.frame.size.height = y
            for v in [icon, title, info, user, pass, canada, cancel, signIn] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = true
                content.addSubview(v)
            }

            let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Sign in to StarPlayrX"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(b)?.isHidden = true }
            window.contentView = content
            window.initialFirstResponder = user.stringValue.isEmpty ? user : pass

            NSApp.activate(ignoringOtherApps: true)
            guard await present(window, confirm: signIn, cancel: cancel) else { return }

            Radio.shared.setRegion(ca: canada.state == .on)
            let u = user.stringValue.trimmingCharacters(in: .whitespaces)
            let p = pass.stringValue
            if u.isEmpty || p.isEmpty { message = "Username and password are required."; continue }
            if await Radio.shared.login(user: u, pass: p) { return }
            message = Radio.shared.status
        }
    }

    /// Shows the window without `runModal()`. A nested modal run loop on the main thread
    /// blocks at user-interactive QoS while AppKit waits on lower-QoS work (priority inversion / hang risk).
    private static func present(_ window: NSWindow, confirm: NSButton, cancel: NSButton) async -> Bool {
        window.level = .modalPanel
        window.center()
        let responder = AlertResponder(window: window)
        confirm.target = responder
        confirm.action = #selector(AlertResponder.confirm(_:))
        cancel.target = responder
        cancel.action = #selector(AlertResponder.cancel(_:))
        return await withCheckedContinuation { continuation in
            responder.continuation = continuation
            window.makeKeyAndOrderFront(nil)
        }
    }
}

@MainActor
private final class AlertResponder: NSObject {
    let window: NSWindow
    var continuation: CheckedContinuation<Bool, Never>?
    private var retainSelf: AlertResponder?

    init(window: NSWindow) {
        self.window = window
        super.init()
        retainSelf = self   // button targets are weak; stay alive until a button is pressed
    }

    @objc func confirm(_ sender: Any?) { finish(true) }
    @objc func cancel(_ sender: Any?) { finish(false) }

    private func finish(_ ok: Bool) {
        window.orderOut(nil)
        continuation?.resume(returning: ok)
        continuation = nil
        retainSelf = nil
    }
}

