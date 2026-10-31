import SwiftUI

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @State private var search = ""

    private var filtered: [Channel] {
        guard !search.isEmpty else { return radio.channels }
        return radio.channels.filter { ch in
            let np = radio.nowPlaying[ch.id]
            let xtraTerms = ch.xtraID != nil ? "Music Xtra" : ""
            return [ch.id, ch.name, ch.category, xtraTerms, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if radio.isLoggedIn {
                nowPlaying
                if radio.isPlaying { SpectrumView() }
                TextField("Search channels, artists, songs", text: $search)
                    .textFieldStyle(.roundedBorder)
                channelList
            } else {
                Text(radio.status).foregroundStyle(.secondary)
                Button(radio.isBusy ? "Signing in…" : "Sign In…") {
                    Task { await CredentialPrompt.signIn() }
                }
                .disabled(radio.isBusy)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var nowPlaying: some View {
        HStack(spacing: 10) {
            let np = radio.current.flatMap { radio.nowPlaying[$0.id] }
            AsyncImage(url: URL(string: (np?.image.isEmpty == false ? np?.image : radio.current?.imageURL) ?? "")) { img in
                img.resizable().scaledToFit()
            } placeholder: {
                Image(systemName: "radio").font(.largeTitle).foregroundStyle(.secondary)
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                if let ch = radio.current {
                    Text("\(ch.id) · \(ch.name)").font(.caption).foregroundStyle(.secondary)
                    Text(np?.song ?? "").font(.headline).lineLimit(1)
                    Text(np?.artist ?? "").lineLimit(1)
                } else {
                    Text("Pick a channel").font(.headline)
                }
            }
            Spacer()
            Button {
                radio.togglePlayPause()
            } label: {
                Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .disabled(radio.current == nil)
        }
    }

    /// Non-lazy VStack: every row is built once when the menu opens, so scrolling never
    /// has to create rows on the fly (List creates them on first scroll, which stutters).
    private var channelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered) { ch in
                        Button {
                            radio.play(ch)
                        } label: {
                            ChannelRow(channel: ch, nowPlaying: radio.nowPlaying[ch.id],
                                       isCurrent: ch == radio.current,
                                       isPlaying: ch == radio.current && radio.isPlaying)
                                .equatable()
                        }
                        .buttonStyle(.plain)
                        .id(ch.id)
                    }
                }
            }
            .frame(height: 360)
            .padding(.trailing, -12)   // scroll bar sits at the window's right edge
            .onAppear { if let id = radio.current?.id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Canada", isOn: Binding(get: { radio.localeIsCA }, set: { radio.setRegion(ca: $0) }))
                .toggleStyle(.checkbox)
            Spacer()
            if radio.isLoggedIn {
                Button("Sign Out") { radio.signOut() }
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

/// One channel row. Equatable so a now-playing update redraws only the row it changed,
/// and always two lines tall so the list never has to re-measure rows while scrolling.
private struct ChannelRow: View, Equatable {
    let channel: Channel
    let nowPlaying: NowPlaying?
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack {
            Text(channel.id).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(channel.name).fontWeight(isCurrent ? .bold : .regular).lineLimit(1)
                Text(nowPlaying.map { "\($0.artist) – \($0.song)" } ?? " ")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isPlaying {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 12)
        .contentShape(Rectangle())
    }
}
