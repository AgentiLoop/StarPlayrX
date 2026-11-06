//
//  AccessibilityAuditTests.swift
//  StarPlayrXUITests
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Automated VoiceOver checks in the simulator: Xcode's accessibility audit (missing labels,
//  hit areas, contrast, Dynamic Type, traits) plus the labels VoiceOver should read.
//  The sign-in screen always runs. The player screens run only when SPX_USER and SPX_PASS are
//  set (TEST_RUNNER_SPX_USER / TEST_RUNNER_SPX_PASS on the xcodebuild command line).
//

import XCTest

final class AccessibilityAuditTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    private var signedIn: Bool { app.buttons["Account"].waitForExistence(timeout: 3) }

    func testSignInScreenVoiceOver() throws {
        try XCTSkipIf(signedIn, "A saved account skips the sign-in screen")
        XCTAssertTrue(app.textFields["Username or email"].exists, "Username field label")
        XCTAssertTrue(app.secureTextFields["Password"].exists, "Password field label")
        XCTAssertTrue(app.switches["Canada"].exists, "Canada toggle label")
        try app.performAccessibilityAudit()
    }

    func testPlayerScreenVoiceOver() throws {
        try signInIfNeeded()
        for label in ["Account", "Previous", "Next"] {
            XCTAssertTrue(app.buttons[label].exists, "\(label) button label")
        }
        XCTAssertTrue(app.buttons["Play"].exists || app.buttons["Pause"].exists, "Play/Pause label")
        try app.performAccessibilityAudit()
    }

    func testLyricsScreenVoiceOver() throws {
        try signInIfNeeded()
        let lyrics = app.buttons["Lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap()
        XCTAssertTrue(app.buttons["Channels"].waitForExistence(timeout: 5), "Toggle reads Channels on lyrics")
        try app.performAccessibilityAudit()
        app.buttons["Channels"].tap()
    }

    private func signInIfNeeded() throws {
        if signedIn { return }
        let env = ProcessInfo.processInfo.environment
        guard let user = env["SPX_USER"], let pass = env["SPX_PASS"], !user.isEmpty, !pass.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_SPX_USER and TEST_RUNNER_SPX_PASS to audit the player")
        }
        let field = app.textFields["Username or email"]
        field.tap(); field.typeText(user)
        let secure = app.secureTextFields["Password"]
        secure.tap(); secure.typeText(pass)
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Sign In'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 30), "Signed in")
    }
}
