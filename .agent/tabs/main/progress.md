# Auto-pilot session — 2026-10-31 20:33
Goal: applescript needs to verify things are ready before getting false data and false positives and NOTHING : MORON!!! -> tell application "StarPlayrX"	activate	delay 3	play channel "1009"	get {shown artist, shown song} -- what the list shows	get {playing artist, playing song} -- what's actually playing	park menu at upper right	toggle shadeend tell
Budget: no time limit, unlimited cycles

## Cycle 1 — 2026-10-31 20:37
AUTOPILOT: GOAL REACHED. I ran your exact script right after a fresh launch and it now returns real data: `play channel "1009"` → true, shown = playing = "Police – De Do Do Do, De Da Da Da (80)", `toggle shade` → true. The script took about 10 seconds because `play channel` now waits instead of answering early.

**Why it broke:** your `delay 3` ran out before StarPlayrX had finished signing in and loading the channel list. So `play channel` couldn't find 1009 and returned false, and all the gets came back empty.

**What changed** (commit deee1e6, pushed):
- **Waiting for the app to be ready:** any command that needs the channel list now holds the script until StarPlayrX is signed in with every channel loaded, Xtra channels included (`Radio.swift`, `Scripting.swift`). If that doesn't happen within 60 seconds, the script gets an error with the reason instead of false or empty text.
- **Waiting for real playback:** `play channel`, `resume` and `select channel` return only once audio is actually coming out and both the list's song and the playing song are known. If playback doesn't start within 30 seconds, you get an error.
- **Sign in:** `sign in` now raises an error with the failure reason instead of returning false.
- **`test channel`:** also waits for the app to be ready and for real playback.
- **Dictionary:** the descriptions in Script Editor now say all this, and suggest wrapping scripts in `with timeout of 120 seconds` when they run right after launch.

When the app is already ready, commands still answer straight away, so the 23 unit tests run as before and all pass.

**Other checks:**
- Live channel 2: shown matched playing.
- Unknown channel: `play channel "99999"` → false.
- `stop` then `resume` → true.
- `test channel` on 8 Xtra and live channels: all MATCH. 1200 returned NO CHANNEL, which is correct because it isn't in the Xtra list.

**Not done:**
- I didn't test the "never gets ready" error path live, because `sign out` deletes your Keychain credentials.
- Plain property gets like `get shown artist` don't wait. They're only reliable after a command like `play channel`, which now does the waiting.
- This fix isn't in a release yet. The shipped 1.1.2 still has the old behavior.

There are no parity folders for this repo, so nothing to mirror.

Session ended — goal reached after 1 cycle(s) (2026-10-31 20:37)

