//
//  SearchField.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI

/// The channel search box. A plain AppKit search field with AutoFill, text completion and inline
/// predictions turned off: SwiftUI's TextField sometimes popped up an empty AutoFill list.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.contentType = nil
        field.isAutomaticTextCompletionEnabled = false
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }   // e.g. set from AppleScript
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let editor = note.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            if #available(macOS 14.0, *) { editor.inlinePredictionType = .no }
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
