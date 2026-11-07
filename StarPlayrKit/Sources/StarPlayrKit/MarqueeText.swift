//
//  MarqueeText.swift
//  StarPlayrKit
//
//  Created by Todd Bruss on 10/31/26.
//  Modified by Todd Bruss on 11/6/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One line of text that never truncates: if it doesn't fit, it scrolls smoothly left in a loop
/// (pausing at the start of each pass); if it fits, it just sits still.
public struct MarqueeText: View {
    let text: String
    let font: Font
    var secondary = false
    @State private var textWidth: CGFloat = 0

    private let gap: CGFloat = 40      // space between the end of the text and its repeat
    private let speed: CGFloat = 30    // points per second
    private let pause: Double = 2      // seconds held at the start of each pass

    public init(text: String, font: Font, secondary: Bool = false) {
        self.text = text
        self.font = font
        self.secondary = secondary
    }

    public var body: some View {
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
            // One VoiceOver element with the whole line: the measuring copy and the second
            // copy the scrolling strip repeats would otherwise be read as extra text.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text.trimmingCharacters(in: .whitespaces))
            .accessibilityHidden(text.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

/// The repeating slide left by `cycle` points, holding at the start for `pause` seconds each pass.
private func marqueeAnimation(cycle: CGFloat, speed: CGFloat, pause: Double) -> CAKeyframeAnimation {
    let move = Double(cycle / speed)
    let period = move + pause
    let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
    anim.values = [0, 0, -cycle]
    anim.keyTimes = [0, NSNumber(value: pause / period), 1]
    anim.duration = period
    anim.repeatCount = .infinity
    anim.isRemovedOnCompletion = false
    return anim
}

#if os(macOS)
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
            layer.removeAnimation(forKey: "marquee")
            layer.add(marqueeAnimation(cycle: cycle, speed: speed, pause: pause), forKey: "marquee")
        }
    }
}
#else
/// Hosts `content` once and slides it left by `cycle` points on a repeating Core Animation, holding
/// at the start for `pause` seconds each pass. The content must repeat after `cycle` points.
private struct ScrollingStrip: UIViewRepresentable {
    let content: AnyView
    let key: String
    let width: CGFloat   // of `content` (both copies and the gap), measured by MarqueeText
    let cycle: CGFloat, speed: CGFloat, pause: Double

    func makeUIView(context: Context) -> Strip { Strip() }

    func updateUIView(_ view: Strip, context: Context) {
        view.configure(content: content, key: key, width: width, cycle: cycle, speed: speed, pause: pause)
    }

    final class Strip: UIView {
        private let host = UIHostingController(rootView: AnyView(EmptyView()))
        private var key = ""
        private var width: CGFloat = 0, cycle: CGFloat = 0, speed: CGFloat = 30, pause: Double = 2
        /// The slide actually used: one hosted copy plus the gap (see layoutSubviews).
        private var slide: CGFloat = 0
        /// The content's size as the hosting controller lays it out (both copies and the gap).
        private var fit = CGSize.zero
        private var diagTimer: Timer?

        init() {
            super.init(frame: .zero)
            clipsToBounds = true
            isUserInteractionEnabled = false   // taps go to the row
            host.view.backgroundColor = .clear
            host.sizingOptions = []
            // The hosted strip is the content's exact width and runs off the screen's edge, under
            // any safe-area inset there (the Duo's camera side, 84 pt). Honouring it would propose
            // a narrower width, the fixed-size text would overflow, and SwiftUI centres overflow —
            // so the line paused shifted left with its first letter cut off.
            host.safeAreaRegions = []
            addSubview(host.view)
        }
        required init?(coder: NSCoder) { nil }

        func configure(content: AnyView, key: String, width: CGFloat, cycle: CGFloat, speed: CGFloat, pause: Double) {
            guard key != self.key || cycle != self.cycle || width != self.width else { return }
            self.key = key
            (self.width, self.cycle, self.speed, self.pause) = (width, cycle, speed, pause)
            // Measured bare (a maxWidth: .infinity frame would just answer the proposal), then
            // flush left in whatever frame it gets: any slack goes on the right.
            host.rootView = content
            fit = host.sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            host.rootView = AnyView(content.frame(maxWidth: .infinity, alignment: .leading))
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The hosted content's own width, never less: the SwiftUI-measured width can come out a
            // point or two short of what the hosting controller lays out, and a frame narrower than
            // the content centres it, cutting the first letter off at the left edge.
            let w = max(width, fit.width)
            let height = fit.height > 0 ? fit.height : bounds.height
            host.view.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: w, height: height)
            // The slide from the content as hosted (one copy plus the gap), so the loop lands exactly
            // on the second copy. width = 2·text + gap and cycle = text + gap, so gap = 2·cycle − width.
            let gap = 2 * cycle - width
            slide = fit.width > 0 ? (fit.width - gap) / 2 + gap : cycle
            try? "DIAG key=\(key) bounds=\(bounds) hostFrame=\(host.view.frame) fit=\(fit) width=\(width) cycle=\(cycle) slide=\(slide) hostSafe=\(host.view.safeAreaInsets) stripSafe=\(safeAreaInsets)\n".write(toFile: NSTemporaryDirectory() + "marquee-diag.txt", atomically: true, encoding: .utf8)
            diagTimer?.invalidate()
            diagTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let p = self.host.view.layer.presentation()
                let line = "T key=\(self.key.prefix(20)) tx=\(p?.affineTransform().tx ?? -9999) modelTx=\(self.host.view.layer.affineTransform().tx) hostFrame=\(self.host.view.frame) hostBounds=\(self.host.view.bounds) stripInWindow=\(self.convert(self.bounds, to: nil)) sub=\(self.host.view.subviews.map { "\($0.frame)" })\n"
                if let h = FileHandle(forWritingAtPath: NSTemporaryDirectory() + "marquee-diag.txt") { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
            }
            startAnimation()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { startAnimation() }
        }

        private func startAnimation() {
            let layer = host.view.layer
            guard slide > 0 else { return }
            layer.removeAnimation(forKey: "marquee")
            layer.add(marqueeAnimation(cycle: slide, speed: speed, pause: pause), forKey: "marquee")
        }
    }
}
#endif

private struct MarqueeWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
