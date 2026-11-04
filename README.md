# SpaceSweeper

A native macOS app (SwiftUI, macOS 14+, Apple Silicon) that finds what's using your disk, tells you whether each item is safe to delete, and removes it safely: to the Trash by default, with a review step every time.

## Build and run

Requirements: Xcode 16 or newer (built and tested with Xcode 26.3), macOS 14+, an Apple Silicon Mac. One dependency, [Sparkle](https://github.com/sparkle-project/Sparkle) (automatic updates), fetched by Swift Package Manager on first build.

1. Open `SpaceSweeper.xcodeproj`.
2. Choose the **SpaceSweeper** scheme and **My Mac**, then press **⌘R**.

From the terminal:

```sh
scripts/ci.sh            # build + all unit tests (same as CI)
scripts/ci.sh build      # build only
open build/DerivedData/Build/Products/Debug/SpaceSweeper.app
```

The project signs with "Sign to Run Locally" (ad-hoc), so it builds without an Apple developer account.

## Granting Full Disk Access

SpaceSweeper is not sandboxed: it has to read your whole home folder. macOS still hides some folders (Mail, Safari, other apps' containers) until you grant **Full Disk Access**:

1. Launch SpaceSweeper. If access is missing, it shows an explanation screen.
2. Click **Open System Settings** (Privacy & Security › Full Disk Access).
3. Turn on **SpaceSweeper**. If it isn't listed, click **+** and choose the app.
4. Return to SpaceSweeper and choose **Quit & Reopen** if macOS asks, then **Rescan**.

Ad-hoc signed builds get a new signature on every rebuild, so macOS may forget the permission. If the access screen comes back after a rebuild, remove SpaceSweeper from the list with **–** and add it again, or set a Development Team under *Signing & Capabilities*.

Without Full Disk Access the app still works; protected folders appear under **Couldn't Scan**.

## What the app shows

| Section | What it is |
|---|---|
| **Overview** | Disk total, used and free; the biggest *Safe* items; Trash size with Empty Trash; "System data, explained" (purgeable space, Time Machine local snapshots, apps); a usage breakdown; an estimate of reclaimable space. |
| **Large Files** | Every file above a size threshold (slider, default 500 MB). |
| **Old Files** | Files not opened or modified in 6/12/24 months, above a minimum size (default 50 MB). |
| **Folders** | A space map (treemap: bigger tiles use more space, double-click to open) or a drill-down list, largest first. |
| **Developer Junk** | Regenerable developer data: Xcode DerivedData, simulators, archives and DeviceSupport; `node_modules`, `.next`, `dist`, `ios/Pods`, virtualenvs, `target/` and `build/` (only next to a project file); package-manager caches (npm, NuGet, Gradle, Maven, Expo, Homebrew, `~/.cache`); app caches; Docker's disk image (view only); Android images and emulators; VM installer images; installers in Downloads. |
| **Applications** | Apps in `/Applications` and `~/Applications` with version, size and last-used date. Uninstall removes the app plus its leftovers. |
| **Couldn't Scan** | Folders skipped because macOS protects them, they couldn't be read, or they're cloud placeholders. |
| **Activity Log** | Everything removed, exportable as CSV. |
| **Help** | In-app guide to ratings and kinds of data. |

### Safety ratings

Every file, folder and junk item is rated:

| Rating | Meaning | Examples |
|---|---|---|
| **Safe** | Recreated automatically | Caches, build output, installers you've used |
| **Review** | Your data, check first | Documents, photos, videos, downloads |
| **Careful** | Loses app data or settings | Application Support, containers, VMs, simulators |
| **Protected** | Never deleted | `/System`, `/Library`, `/usr`, `/private`, Keychains, iCloud Drive, `~/.ssh`, Mail, Photos library, SpaceSweeper itself |

Anything modified in the last 7 days is never rated Safe. Items in Documents or Desktop show a warning.

### Sizes

Sizes are **allocated** space on disk, not logical file length, so sparse files such as Docker's `Docker.raw` show what they really use. Hard links are counted once; symlinks are never followed. Freed space only appears after the Trash is emptied, and macOS may keep Time Machine local snapshots or purgeable space for a while.

## Deleting safely

- **Move to Trash** is the default (`FileManager.trashItem`), so everything can be put back.
- **Delete Permanently** is a secondary button behind a second confirmation.
- A review sheet always lists every item, its size, rating and consequence, with **Cancel** as the default button.
- Protected items appear as locked rows and are re-checked immediately before each removal.
- If an app that owns the files is running (Xcode, VS Code, Cursor, Docker…), the sheet warns and offers **Quit**.
- After removal, the app shows how much was removed and how free space changed, and records each item in the activity log.

### Uninstalling apps

Uninstall moves the `.app` to the Trash and lists leftovers found in `~/Library` (Application Support, Caches, Preferences, Containers, Group Containers, Saved Application State, HTTPStorages, WebKit, LaunchAgents, Logs, Cookies). Matches by bundle identifier are ticked; matches by app name only are shown unticked. Apple system apps and SpaceSweeper itself can't be uninstalled, and a running app must be quit first. Apps owned by root or another user trigger the standard macOS administrator prompt.

## Settings

*SpaceSweeper › Settings…* (⌘,): scan on open and default sizes; appearance (System/Light/Dark); scan locations and **folders to always skip**; how recent a change counts as "in use" and whether to offer Delete Permanently; privacy (policy, delete the saved scan, clear the activity log); updates.

## Accessibility

Every checkbox, badge and chart slice has a VoiceOver label; ratings use text and icons, not only colour; decorative graphics are hidden from VoiceOver; animations respect *Reduce Motion*; the space map uses colours that keep white labels readable (WCAG AA for large text). Keyboard: ⌘R rescan, ⌘. cancel, ⌘⌫ Move to Trash…, ⌥⌘A deselect all, Space Quick Look, ⌘? Help.

## Privacy

See [PRIVACY.md](PRIVACY.md), which is also shown in *Settings › Privacy*. In short: no data collection, no network use except optional update checks, and everything stays on your Mac.

## Project layout

```
SpaceSweeper/
  App/        App entry point, AppState (central @Observable model)
  Models/     Scan models, folder tree, overview calculations, help content
  Scanning/   getattrlistbulk lister, parallel walker, scanner, cache
  DevJunk/    Junk detection rules and catalog
  Safety/     Protection policy, safety ratings, deletion service, activity log
  Apps/       App inventory, leftover matching, admin-rights fallback
  System/     Disk info, Full Disk Access check
  Views/      SwiftUI views
SpaceSweeperTests/   Unit tests (temporary-folder fixtures only)
scripts/ci.sh        Single CI entry point
.github/workflows/   GitHub Actions: build + test on every push/PR, Release artifact on main
```

Scanning uses `getattrlistbulk(2)`, which was about 20–25% faster than `FileManager`'s enumerator on a real home folder. It also returns inode, link count and flags in the same call. Subtrees are scanned in parallel with Swift concurrency, and progress is polled ten times a second so the UI never blocks. The last scan is cached in `~/Library/Application Support/SpaceSweeper/` so the app opens instantly.

## Tests and CI

`scripts/ci.sh` builds and runs all tests; GitHub Actions runs the same script on every push and pull request. Tests cover size aggregation, the protection list, safety ratings, developer-junk detection, leftover matching, deletion (using a fixture "Trash", never the real one), CSV export and the Help content. Every test works in a temporary folder and never touches real user files.

## Distribution notes (for selling the app)

- **Not Mac App Store:** App Store apps must be sandboxed, and SpaceSweeper needs full-disk reads, so distribute directly. Sign with a **Developer ID Application** certificate (Apple Developer Program, $99/year), enable Hardened Runtime (already on), and **notarize** with `xcrun notarytool` so Gatekeeper opens it without warnings.
- **Licensing and payments:** Paddle, Lemon Squeezy or FastSpring act as merchant of record (they handle sales tax and VAT) and provide license keys. Setapp is an alternative subscription channel. A common model is a free scan with paid cleanup.
- **Updates:** built in with [Sparkle 2](https://sparkle-project.org) (see below).
- **Trust:** the app is offline and reads metadata only. Publish a short privacy policy saying so; the Help screen already states it.
- **Bundle ID:** `com.mattfuchs.SpaceSweeper`. Change it before the first public release if you plan to sell under a company name, because it can't change afterwards without losing users' settings.

## Releasing updates (Sparkle)

Updates are **off** until the build has a feed URL and a signing key; until then *Check for Updates…* is disabled and Settings says updates aren't set up. To turn them on:

1. **Create a signing key (once).** Run Sparkle's `generate_keys` tool. After the first build it is in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/`. It stores the private key in your login Keychain and prints the public key. Back up the private key (`generate_keys -x private-key.txt`) somewhere safe; losing it means existing users can't receive updates.
2. **Configure the build.** In the SpaceSweeper target's build settings, set `SPARKLE_PUBLIC_KEY` to the printed public key and `SPARKLE_FEED_URL` to the HTTPS address where you'll host `appcast.xml` (for example GitHub Pages, or your website).
3. **For each release:** bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, archive, sign with Developer ID, notarize, and zip or DMG the app. Then run `generate_appcast <folder-with-releases>`, which signs the archives and writes `appcast.xml`. Upload both to the feed location.

Users get an update prompt on their next automatic check (once a day by default), or via *SpaceSweeper › Check for Updates…*.
