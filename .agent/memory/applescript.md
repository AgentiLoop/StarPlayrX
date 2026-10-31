# StarPlayrXMac AppleScript (2026-10-31)
- Sdef: StarPlayrXMac/Sources/StarPlayrX.sdef; impl: Sources/Scripting.swift (AppDelegate KVC keys sp*, one SPXCommand class dispatched by command name; async commands use suspendExecution/resumeExecution).
- Add files → run `xcodegen generate` in StarPlayrXMac, then `git checkout` the xcscheme (xcodegen rewrites it).
- Test Xtra shown-vs-played: `tell application id "com.starplayrx.mac" to test channel "1000" waiting up to 60` → "MATCH\t1000\tshown\tplayed". Loop over `xtra channel numbers` inside `with timeout of 120 seconds`.
- Launch the Debug build by running the binary directly (nohup …/Contents/MacOS/StarPlayrX &); `open` on it gave -609.
