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
            guard await present(alert) else { return }

            let u = user.stringValue.trimmingCharacters(in: .whitespaces)
            let p = pass.stringValue
            if u.isEmpty || p.isEmpty { message = "Username and password are required."; continue }
            if await Radio.shared.login(user: u, pass: p) { return }
            message = Radio.shared.status
        }
    }

    /// Shows the alert window without `runModal()`. A nested modal run loop on the main thread
    /// blocks at user-interactive QoS while AppKit waits on lower-QoS work (priority inversion / hang risk).
    private static func present(_ alert: NSAlert) async -> Bool {
        alert.layout()
        let window = alert.window
        window.level = .modalPanel
        window.center()
        let responder = AlertResponder(window: window)
        alert.buttons.first?.target = responder
        alert.buttons.first?.action = #selector(AlertResponder.confirm(_:))
        alert.buttons.last?.target = responder
        alert.buttons.last?.action = #selector(AlertResponder.cancel(_:))
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

