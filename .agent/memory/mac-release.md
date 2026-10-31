# StarPlayrXMac release recipe (mac-1.0, 2026-10-31)
- xcodebuild Release, ARCHS="arm64 x86_64", CODE_SIGN_STYLE=Manual, "Developer ID Application" team 469UCUB275, ENABLE_HARDENED_RUNTIME=YES.
- xcodebuild injects get-task-allow → notarization Invalid. Re-sign after build: `codesign --force --options runtime --timestamp --sign "Developer ID Application: Todd Bruss (469UCUB275)" StarPlayrX.app`.
- Notary profile: `--keychain-profile "App Store Connect Profile"` (only one stored). Then stapler staple, ditto zip, gh release.
- Mac tags use `mac-X.Y` to keep them apart from the old Catalyst/iOS tags (1.3.1).
