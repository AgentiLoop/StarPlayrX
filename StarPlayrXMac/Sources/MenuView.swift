import SwiftUI

struct MenuView: View {
    @EnvironmentObject var radio: Radio
    @State private var search = ""

    private var filtered: [Channel] {
        guard !search.isEmpty else { return radio.channels }
        return radio.channels.filter { ch in
            let np = radio.nowPlaying[ch.id]
            return [ch.id, ch.name, ch.category, np?.artist ?? "", np?.song ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if radio.isLoggedIn {
                nowPlaying
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

    private var channelList: some View {
        ScrollViewReader { proxy in
            List(filtered) { ch in
                Button {
                    radio.play(ch)
                } label: {
                    HStack {
                        Text(ch.id).monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(ch.name).fontWeight(ch == radio.current ? .bold : .regular)
                            if let np = radio.nowPlaying[ch.id] {
                                Text("\(np.artist) – \(np.song)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if ch == radio.current && radio.isPlaying {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(ch.id)
            }
            .listStyle(.plain)
            .frame(height: 360)
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
