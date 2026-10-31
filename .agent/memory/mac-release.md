# StarPlayrXMac release recipe (mac-1.0, 2026-10-31)
- xcodebuild Release, ARCHS="arm64 x86_64", CODE_SIGN_STYLE=Manual, "Developer ID Application" team 469UCUB275, ENABLE_HARDENED_RUNTIME=YES.
- xcodebuild injects get-task-allow → notarization Invalid. Re-sign after build: `codesign --force --options runtime --timestamp --sign "Developer ID Application: Todd Bruss (469UCUB275)" StarPlayrX.app`.
- Notary profile: `--keychain-profile "App Store Connect Profile"` (only one stored). Then stapler staple, ditto zip, gh release.
- Version lives in StarPlayrXMac/Sources/Info.plist AND project.yml (no MARKETING_VERSION in pbxproj). mac-1.1 shipped 2026-10-31. mac-1.1.1 (build 4) shipped 2026-10-31.
- DMG: hdiutil UDZO of folder {app, /Applications symlink}, codesign dmg, notarize dmg, staple. Release assets also carry StarPlayrX-Mac-screenshot.png + -menu.png (copy from previous release).
- Website repo: ~/Documents/GitHub/starplayrx.com (public/index.html has download link + version; screenshot public/starplayrx-mac.png); deploy `npx -y wrangler@4 deploy`.
- Mac tags use `mac-X.Y` to keep them apart from the old Catalyst/iOS tags (1.3.1).
