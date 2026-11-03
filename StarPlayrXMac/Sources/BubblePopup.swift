//
//  BubblePopup.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import AppKit

/// Shows a `ChatBubble` for a moment in its own small floating window, so it is never cropped by the
/// panel's edge. The bottom of the pointer sits exactly on the given screen point.
@MainActor
final class BubblePopup {
    static let shared = BubblePopup()
    private let pad: CGFloat = 4   // room for the bubble's shadow inside its window
    private var window: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var shown = 0

    func show(_ text: String, at point: NSPoint) {
        // One hosting view, reused. It must not drive the window's size itself (sizingOptions = []):
        // swapping in a new hosting view each click and letting it resize the window threw AppKit's
        // "too many Update Constraints passes" exception, which crashed the app.
        let content = AnyView(ChatBubble(text: text).fixedSize().padding(pad))
        let host = self.host ?? {
            let h = NSHostingView(rootView: content)
            h.sizingOptions = []
            self.host = h
            return h
        }()
        host.rootView = content
        // Measure with a throwaway hosting view: with sizingOptions = [] the live one reports no
        // size, so the window was 0 wide and the bubble ended up off the click.
        let size = NSHostingView(rootView: content).fittingSize
        let panel = window ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            window = p
            return p
        }()
        if panel.contentView !== host { panel.contentView = host }
        panel.setFrame(NSRect(x: point.x - size.width / 2, y: point.y - pad, width: size.width, height: size.height), display: false)
        host.frame = NSRect(origin: .zero, size: size)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        shown += 1
        let id = shown
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard shown == id else { return }   // a newer click keeps its own label up
            await NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 0 }
            if shown == id { panel.orderOut(nil) }
        }
    }
}

/// A small speech bubble: a capsule with a tail pointing down.
private struct ChatBubble: View {
    let text: String


    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()   // never truncated to "…"
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: Capsule())
            Tail().fill(.regularMaterial).frame(width: 8, height: 4)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
        .allowsHitTesting(false)
    }

    private struct Tail: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.minX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
                p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}
