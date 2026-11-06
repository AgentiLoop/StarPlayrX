//
//  ChannelGroup.swift
//  StarPlayrKit
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  The channel categories shared by the iOS and Mac apps: a hand-made table from the API's genres
//  to a few top-level chips (Music, Sports, …) with a second row each (NFL, Rock, …), and the chip bar.
//

import SwiftUI

/// A fixed, hand-made table from the API's genres (decorations.genre, audited Nov 2026: ~50 genres,
/// many with 1–5 channels) to five top-level chips and a few second-row chips each. Small genres are
/// folded into a neighbour so no chip is a lone channel; talk never lands in Music. Xtra channels
/// carry music genres and sit in Music with the live ones. Search still matches the API's own genre.
public enum ChannelGroup {
    public static let order: [(group: String, subs: [String])] = [
        ("Music", ["Pop", "Rock", "Hip-Hop & R&B", "Country", "Dance", "Latin & World", "Jazz & Classical",
                   "Christian", "Chill", "Kids", "Holiday"]),
        ("Sports", ["Sports Talk", "NFL", "MLB", "NBA", "NHL", "College", "Live Games"]),
        ("News", ["News", "Business"]),
        ("Talk", ["Entertainment", "Faith & Health"]),
        ("Comedy", []),
    ]

    private static let genres: [String: (group: String, sub: String)] = [
        "Pop": ("Music", "Pop"),
        "Rock": ("Music", "Rock"), "Classic Rock": ("Music", "Rock"),
        "Hard Rock & Metal": ("Music", "Rock"), "Alternative & Indie": ("Music", "Rock"),
        "Hip-Hop": ("Music", "Hip-Hop & R&B"), "R&B": ("Music", "Hip-Hop & R&B"),
        "Country": ("Music", "Country"),
        "Dance & Electronic": ("Music", "Dance"),
        "Latin": ("Music", "Latin & World"), "International": ("Music", "Latin & World"), "Reggae": ("Music", "Latin & World"),
        "Jazz": ("Music", "Jazz & Classical"), "Classical": ("Music", "Jazz & Classical"),
        "Standards": ("Music", "Jazz & Classical"), "Stage & Screen": ("Music", "Jazz & Classical"),
        "Christian": ("Music", "Christian"),
        "New Age & Ambient": ("Music", "Chill"),
        "Family & Kids": ("Music", "Kids"),
        "Holiday": ("Music", "Holiday"),
        "Sports Talk": ("Sports", "Sports Talk"),
        "Live Games": ("Sports", "Live Games"),
        "News & Politics": ("News", "News"),
        "Business": ("News", "Business"),
        "Pop Culture": ("Talk", "Entertainment"), "Society & Culture": ("Talk", "Entertainment"),
        "Fiction & Drama": ("Talk", "Entertainment"), "True Crime": ("Talk", "Entertainment"),
        "Religion": ("Talk", "Faith & Health"), "Lifestyle & Health": ("Talk", "Faith & Health"),
        "Health & Wellness": ("Talk", "Faith & Health"),
        "Comedy": ("Comedy", ""),
    ]

    /// Live channels the API sends with no genre (Howard 100, Road Dog, Holy Culture, …).
    private static let blankLive: [String: (group: String, sub: String)] = [
        "100": ("Talk", "Entertainment"), "142": ("Talk", "Entertainment"), "143": ("Talk", "Entertainment"),
        "159": ("Talk", "Entertainment"), "770": ("Talk", "Entertainment"), "790": ("Talk", "Entertainment"),
        "168": ("Music", "Christian"), "362": ("Music", "Hip-Hop & R&B"), "1999": ("Sports", "Live Games"),
    ]

    public static func place(_ ch: Channel) -> (group: String, sub: String) {
        if ch.category == "Sports & Recreation" { return ("Sports", sport(ch.id)) }
        // College Sports Radio and SEC / Big Ten / ACC Radio come as "Sports Talk".
        if ["84", "256", "257", "258"].contains(ch.id) { return ("Sports", "College") }
        if let p = genres[ch.category] { return p }
        if let p = blankLive[ch.id] { return p }
        // Anything else: Xtra (always music; the blank ones are moods like Rainfall Radio, Lo-Fi Café)
        // goes to Chill, the Limited Edition pop-ups to Pop, and an unknown talk genre to Talk.
        if ch.xtraID != nil { return ("Music", "Chill") }
        if ch.category.isEmpty { return ("Music", "Pop") }
        return ("Talk", "Entertainment")
    }

    /// "Sports & Recreation" is the league talk channels (81–91) and every team's play-by-play,
    /// numbered in league blocks.
    private static func sport(_ id: String) -> String {
        switch Int(id) ?? 0 {
        case 800...832: return "NFL"
        case 840...871: return "MLB"
        case 880...909: return "NBA"
        case 920...951: return "NHL"
        case 952...962: return "College"
        case 963...: return "Live Games"
        default: return "Sports Talk"
        }
    }

    /// The top-level groups that have channels, in `order`.
    public static func groups(_ channels: [Channel]) -> [String] {
        let present = Set(channels.map { place($0).group })
        return order.map(\.group).filter(present.contains)
    }

    /// The second-row chips of one group that have channels, in `order`.
    public static func subs(of group: String, in channels: [Channel]) -> [String] {
        let present = Set(channels.map(place).filter { $0.group == group }.map(\.sub))
        return (order.first { $0.group == group }?.subs ?? []).filter(present.contains)
    }

    /// Only the channels in `group` (nil: all) and, inside it, `sub` (nil: all of the group).
    public static func filter(_ channels: [Channel], group: String?, sub: String?) -> [Channel] {
        guard group != nil || sub != nil else { return channels }
        return channels.filter { ch in
            let p = place(ch)
            return (group.map { p.group == $0 } ?? true) && (sub.map { p.sub == $0 } ?? true)
        }
    }
}

/// An "All …" chip and one chip per title, scrolling sideways over the channel list.
public struct CategoryBar: View {
    let titles: [String]
    let all: String
    @Binding var selected: String?
    var small = false
    var inset: CGFloat = 16

    /// `inset`: the space before the first chip and after the last (the Mac panel already has its own margin).
    public init(titles: [String], all: String, selected: Binding<String?>, small: Bool = false, inset: CGFloat = 16) {
        self.titles = titles; self.all = all; self._selected = selected; self.small = small; self.inset = inset
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(all, value: nil)
                ForEach(titles, id: \.self) { chip($0, value: $0) }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, small ? 4 : 8)
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let isOn = selected == value
        return Button { selected = value } label: {
            Text(title)
                .font(small ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 4 : 6)
                .background(Capsule().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

