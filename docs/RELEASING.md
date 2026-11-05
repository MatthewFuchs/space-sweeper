# Releasing SpaceSweeper

For maintainers. Building and running locally needs none of this; see the [README](../README.md).

Releases are **free**: no Apple Developer account. They're signed with a self-signed certificate ("SpaceSweeper Release"), so macOS keeps Full Disk Access across updates, and updates are signed with a Sparkle key. People installing for the first time confirm the app once via *System Settings › Privacy & Security › Open Anyway*; the [install guide](https://matthewfuchs.github.io/space-sweeper/install.html) walks them through it.

## One-time setup

1. **Create the keys** (already done once; re-running refuses to overwrite):

   ```sh
   scripts/ci.sh build              # downloads Sparkle's tools
   scripts/setup-release-keys.sh    # writes ~/SpaceSweeper-release-keys (never commit it)
   ```

   It prints the Sparkle public key, which is already set as `SPARKLE_PUBLIC_KEY` in the app's Release build settings. **Back up `~/SpaceSweeper-release-keys`** somewhere safe. Losing it means installed copies stop receiving updates and Full Disk Access must be granted again.

2. **Add three repository secrets** (GitHub › Settings › Secrets and variables › Actions › New repository secret). Each command copies the value; paste it as the secret:

   | Secret | Copy the value with |
   |---|---|
   | `SIGNING_CERT_P12` | `base64 -i ~/SpaceSweeper-release-keys/SpaceSweeper-Release.p12 \| pbcopy` |
   | `SIGNING_CERT_PASSWORD` | `pbcopy < ~/SpaceSweeper-release-keys/p12-password.txt` |
   | `SPARKLE_PRIVATE_KEY` | `pbcopy < ~/SpaceSweeper-release-keys/sparkle-private-key.txt` |

3. **Turn on the website:** GitHub › Settings › Pages › Build and deployment › Source: **GitHub Actions**.

## Publishing a release

```sh
git tag v1.0.0 && git push origin v1.0.0
```

The [Release workflow](../.github/workflows/release.yml) then:
1. runs the tests
2. builds a universal app (Apple Silicon and Intel)
3. signs it with the certificate
4. packages `SpaceSweeper.dmg`
5. signs the update feed (`appcast.xml`)
6. creates the GitHub Release
7. redeploys the website with the new feed

The download button on the site always points at the latest release:
`https://github.com/MatthewFuchs/space-sweeper/releases/latest/download/SpaceSweeper.dmg`.

Version numbers come from the tag (`v1.2.0` → 1.2.0); the build number is the workflow run number.

## Website

`website/` is plain HTML and CSS. The [Website workflow](../.github/workflows/pages.yml) publishes it to GitHub Pages whenever `website/` or `PRIVACY.md` changes. `privacy.html` is generated from `PRIVACY.md` by `scripts/build-site.py`. Preview locally with `python3 scripts/build-site.py --out build/site && open build/site/index.html`.

Screenshots in `website/assets/` come from a sample Mac, never a real one. Debug builds can scan a demo folder with `SPACESWEEPER_DEMO_ROOT=/path/to/demo` (see `SpaceSweeper/App/DebugLaunch.swift`).

## Later: Apple Developer account

With a paid account, replace the certificate step in `release.yml` with a Developer ID identity, add `--timestamp`, and notarize (`xcrun notarytool submit … --wait`, then `xcrun stapler staple`). Users then see no warning at all. The update feed and website don't change, but everyone grants Full Disk Access once more, because the signing identity changes.
