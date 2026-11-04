# Releasing SpaceSweeper

This is for maintainers publishing signed builds. Building and running locally needs none of it; see the [README](../README.md).

## 1. Signing and notarization

SpaceSweeper reads the whole disk, so it can't be sandboxed and isn't distributed through the Mac App Store. Release builds need:

1. A **Developer ID Application** certificate (Apple Developer Program).
2. Set your team under *Signing & Capabilities* (Debug builds use ad-hoc signing and need nothing).
3. Archive the Release configuration (*Product › Archive*), export with *Developer ID*, and notarize:

   ```sh
   xcrun notarytool submit SpaceSweeper.zip --keychain-profile <profile> --wait
   xcrun stapler staple SpaceSweeper.app
   ```

Hardened Runtime is already enabled.

## 2. Automatic updates (Sparkle)

Updates use [Sparkle 2](https://sparkle-project.org). They stay **off** until a build has a feed URL and a signing key; until then *Check for Updates…* is disabled and Settings says updates aren't set up.

1. **Create a signing key (once).** Run Sparkle's `generate_keys`. After the first build it's in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. It stores the private key in your login Keychain and prints the public key. Back the private key up (`generate_keys -x private-key.txt`) somewhere safe: losing it means existing users can't receive updates. Never commit it.
2. **Configure the build.** In the SpaceSweeper target's build settings, set `SPARKLE_PUBLIC_KEY` to the printed public key and `SPARKLE_FEED_URL` to the HTTPS address where `appcast.xml` will be hosted (for example GitHub Pages).
3. **For each release:** bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, archive, sign, notarize, then zip or DMG the app. Run `generate_appcast <folder-with-releases>` (it signs the archives and writes `appcast.xml`) and upload both to the feed location.

Users get an update prompt on their next automatic check (daily by default), or via *SpaceSweeper › Check for Updates…*.

## 3. CI artifacts

Every push to `main` runs [CI](../.github/workflows/ci.yml): build, tests, and an unsigned Release `.app` uploaded as a workflow artifact. That artifact is ad-hoc signed and not notarized, so it's only for testing.
