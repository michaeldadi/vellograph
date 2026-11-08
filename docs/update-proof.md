# Two-version update proof (2026-11-07)

This is a local development proof, not a public release qualification.

## Tested on this Mac

- Vellograph 0.2.0 (3) was installed in `~/Applications`. Its own Sparkle updater
  offered the published 0.2.1 (4) prerelease from the renamed repository and
  feed. **Install Update** and **Install and Relaunch** completed; the relaunched
  About panel showed 0.2.1 (4). The installed app passed
  `codesign --verify --deep --strict`, and its feed URL is
  `https://michaeldadi.github.io/vellograph/appcast.xml`.
- The Vellograph 0.2.1 archive and appcast were signed with the same local
  EdDSA key and published as an update-proof prerelease. GitHub Pages served
  the appcast byte-for-byte as generated locally.
- Before the rename, the following Mac Diff Studio proof also passed:
- macOS 27.2, Apple Silicon. Installed build 0.1.0 (1) in `~/Applications`.
- Published build 0.1.1 (2) as a GitHub prerelease and its Sparkle appcast on GitHub Pages.
- Sparkle displayed 0.1.1 and its release notes from the installed 0.1.0 app.
- **Install Update** downloaded and extracted the archive. **Install and Relaunch** replaced the app. The relaunched About panel showed 0.1.1 (2), and `codesign --verify --deep --strict` passed.
- `sign_update --verify` accepted the published archive and rejected a copy modified by one byte. This tests the archive signature, not Sparkle's in-app error presentation.
- A signed 0.1.0 archive was restored and launched; About showed 0.1.0 (1). The 0.1.1 app was then restored and its code signature verified. This tests a manual local rollback path.
- The appcast is EdDSA signed. The private EdDSA key remains in the local Keychain.

## Still required before release

- In-app rejection and user-facing recovery for a tampered download.
- Offline feed and download behavior without changing this Mac's global network settings.
- Developer ID signing and notarization for public distribution, if the Apple Developer account becomes available in Xcode. The proof archive uses an Apple Development identity; that identity is unsuitable as a general public distribution identity.
- Repeat rollback, offline, and tamper UI tests for Vellograph, then test the
  final packaging and Homebrew cask.

The prerelease is intentionally labeled an update proof. It does not imply feature parity.
