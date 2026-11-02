# Modern SiriusXM API for live (non-Xtra) channels — Mac app

- Live channels now tune through api.edge-gateway.siriusxm.com `/playback/play/v1/tuneSource` with
  `type: channel-linear`, `manifestVariant: WEB` (XtraClient.liveStream). Legacy local server is the
  fallback; `defaults write com.starplayrx.mac modernLive -bool NO` turns the modern path off.
- Playback goes through `LiveLoader` (AVAssetResourceLoaderDelegate, scheme `sxmlive`): playlists are
  fetched by the app, the `#EXT-X-KEY` URI is rewritten to `sxmkey://` and answered with the raw AES key
  (the real key endpoint needs a bearer and returns JSON → AVPlayer got 401 / -12881 otherwise).
- EQ feed: LiveLoader renames segments to `<tag>_<mediaSequence>_v.aac` (names differ per channel,
  some like `0917_332.aac` have no sequence) and hands the playlist + newest 4 segments to
  SpectrumTimeline.livePlaylist/liveSegment. Segment EXTINF is ~9.752 s (not 10) → `nominal` is read
  from the playlist.
- Modern playlists carry EXT-X-PROGRAM-DATE-TIME only on the FIRST segment; SpectrumTimeline.playlist
  carries the date forward by EXTINF. Without that every segment had start=nil → EQ dead after a switch.
- `working` git tag = last all-legacy state before this experiment (21fbc8d).
