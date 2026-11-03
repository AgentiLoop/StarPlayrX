//
//  MarqueeText.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI

/// One line of text that never truncates: if it doesn't fit, it scrolls smoothly left in a loop
/// (pausing at the start of each pass); if it fits, it just sits still.
struct MarqueeText: View {
    let text: String
    let font: Font
    var secondary = false
    @State private var textWidth: CGFloat = 0

    private let gap: CGFloat = 40      // space between the end of the text and its repeat
    private let speed: CGFloat = 30    // points per second
    private let pause: Double = 2      // seconds held at the start of each pass

    var body: some View {
        // Invisible line sets the height; the width comes from the parent.
        Text(" ").font(font).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: MarqueeWidthKey.self, value: g.size.width)
                    })
            }
            .onPreferenceChange(MarqueeWidthKey.self) { textWidth = $0 }
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    if textWidth <= geo.size.width {
                        Text(text).font(font).fixedSize().foregroundStyle(secondary ? .secondary : .primary)
                    } else {
                        // Drawn once, then moved by Core Animation in the render server: no per-frame work
                        // in the app. (A TimelineView rebuilt every scrolling line 60 times a second.)
                        ScrollingStrip(content: AnyView(
                            HStack(spacing: gap) {
                                Text(text).font(font).fixedSize()
                                Text(text).font(font).fixedSize()
                            }
                            .foregroundStyle(secondary ? .secondary : .primary)),
                            key: "\(text)|\(secondary)", width: 2 * textWidth + gap, cycle: textWidth + gap, speed: speed, pause: pause)
                    }
                }
                .clipped()
            }
    }
}

/// Hosts `content` once and slides it left by `cycle` points on a repeating Core Animation, holding
/// at the start for `pause` seconds each pass. The content must repeat after `cycle` points.
private struct ScrollingStrip: NSViewRepresentable {
    let content: AnyView
    let key: String
    let width: CGFloat   // of `content` (both copies and the gap), measured by MarqueeText
    let cycle: CGFloat, speed: CGFloat, pause: Double

    func makeNSView(context: Context) -> Strip { Strip() }

    func updateNSView(_ view: Strip, context: Context) {
        view.configure(content: content, key: key, width: width, cycle: cycle, speed: speed, pause: pause)
    }

    final class Strip: NSView {
        private let host = NSHostingView(rootView: AnyView(EmptyView()))
        private var key = ""
        private var width: CGFloat = 0, cycle: CGFloat = 0, speed: CGFloat = 30, pause: Double = 2

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.masksToBounds = true
            host.sizingOptions = []
            host.wantsLayer = true
            addSubview(host)
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // clicks go to the row

        func configure(content: AnyView, key: String, width: CGFloat, cycle: CGFloat, speed: CGFloat, pause: Double) {
            guard key != self.key || cycle != self.cycle || width != self.width else { return }
            self.key = key
            (self.width, self.cycle, self.speed, self.pause) = (width, cycle, speed, pause)
            host.rootView = content
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // Exactly the content's width (measured in SwiftUI; fittingSize isn't reliable here): any
            // wider and SwiftUI centers the two copies in it, so the text paused in from the left edge.
            let height = host.fittingSize.height > 0 ? host.fittingSize.height : bounds.height
            host.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
            startAnimation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { startAnimation() }
        }

        private func startAnimation() {
            guard let layer = host.layer, cycle > 0 else { return }
            let move = Double(cycle / speed)
            let period = move + pause
            let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
            anim.values = [0, 0, -cycle]
            anim.keyTimes = [0, NSNumber(value: pause / period), 1]
            anim.duration = period
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.removeAnimation(forKey: "marquee")
            layer.add(anim, forKey: "marquee")
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
