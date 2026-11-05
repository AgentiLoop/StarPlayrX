# StarPlayrXMac scripts

Reusable build/release scripts for the Mac menu bar app. All paths resolve from
the repo root, so they work from any directory.

| Script | What it does |
|---|---|
| `scripts/build-mac.sh` | Release build only (Universal), then opens the app. Same as the README's command-line build. |
| `scripts/test-mac.sh` | Runs the unit tests (`xcodebuild test`). |
| `scripts/release-mac.sh` | Full signed release: archive → export Developer ID → notarize → staple → zip → DMG → sign/notarize/staple DMG → `spctl` verify → sha256. |
| `scripts/export.plist` | Default `-exportArchive` options (Developer ID, automatic, team 469UCUB275). `release-mac.sh` regenerates this with the active team at runtime. |

## Release

```sh
# bump version + build number (Info.plist and project.yml), commit, build, sign, notarize:
StarPlayrXMac/scripts/release-mac.sh 1.1.28 34

# build only (version already bumped):
StarPlayrXMac/scripts/release-mac.sh 1.1.28
```

Environment overrides: `OUT=/path` (artifact dir, default `/tmp/spx-rel`),
`NOTARY_PROFILE` (default `"App Store Connect Profile"`), `TEAM`, `SIGN_ID`.

Artifacts land in `$OUT`: `StarPlayrX-Mac-<V>.dmg`, `StarPlayrX-Mac-<V>.zip`,
`out/StarPlayrX.app`, `arch.xcarchive`.

Publish a GitHub release afterwards (needs the FULL commit sha):

```sh
SHA=$(git rev-parse HEAD)
gh release create mac-1.1.28 --target "$SHA" --latest \
  --title "StarPlayrX for Mac 1.1.28" --notes-file notes-1.1.28.md \
  /tmp/spx-rel/StarPlayrX-Mac-1.1.28.dmg /tmp/spx-rel/StarPlayrX-Mac-1.1.28.zip
git tag mac-1.1.28 && git push origin mac-1.1.28
```

Notes:
- The app carries a keychain-access-groups entitlement, so it needs a
  provisioning profile: the release script always archives with
  `ENABLE_HARDENED_RUNTIME=YES -allowProvisioningUpdates` and exports with
  `method=developer-id` (never re-sign manually — that strips the profile).
  Forgetting `ENABLE_HARDENED_RUNTIME` makes notarization come back Invalid.
- The version lives in `StarPlayrXMac/Sources/Info.plist` AND
  `StarPlayrXMac/project.yml` (the XcodeGen project has no
  MARKETING_VERSION/CURRENT_PROJECT_VERSION in the pbxproj) — `release-mac.sh`
  updates both when given a build number.
- Release tags are named `mac-X.Y.Z` to stay apart from the old Catalyst/iOS tags.
