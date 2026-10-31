import SwiftUI
import AppKit

@main
struct StarPlayrXMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var radio = Radio.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(radio)
        } label: {
            Image(systemName: radio.isPlaying ? "dot.radiowaves.left.and.right" : "radio")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            if let saved = Keychain.load(), await Radio.shared.login(user: saved.user, pass: saved.pass) {
                return
            }
            await CredentialPrompt.signIn()
        }
    }
}

/// Native username / password prompt. Credentials go straight from this dialog to the Keychain.
@MainActor
enum CredentialPrompt {
    static func signIn() async {
        var message = "Enter your SiriusXM username and password.\nThey are stored only in your Mac's Keychain."
        while true {
            let alert = NSAlert()
            alert.messageText = "Sign in to StarPlayrX"
            alert.informativeText = message
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")

            let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            user.placeholderString = "Username or email"
            user.stringValue = Keychain.load()?.user ?? UserDefaults.standard.string(forKey: "user") ?? ""
            let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            pass.placeholderString = "Password"
            let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            stack.addSubview(user)
            stack.addSubview(pass)
            alert.accessoryView = stack
            alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : pass

            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let u = user.stringValue.trimmingCharacters(in: .whitespaces)
            let p = pass.stringValue
            if u.isEmpty || p.isEmpty { message = "Username and password are required."; continue }
            if await Radio.shared.login(user: u, pass: p) { return }
            message = Radio.shared.status
        }
    }
}
