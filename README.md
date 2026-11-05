# SpaceSweeper

[![CI](https://github.com/MatthewFuchs/space-sweeper/actions/workflows/ci.yml/badge.svg)](https://github.com/MatthewFuchs/space-sweeper/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-4169E1)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-4169E1)

**A native macOS app that finds what's using your disk, tells you plainly whether each item is safe to delete, and removes it safely.**

**[Website](https://matthewfuchs.github.io/space-sweeper/) · [Download](https://github.com/MatthewFuchs/space-sweeper/releases/latest/download/SpaceSweeper.dmg) · [Install guide](https://matthewfuchs.github.io/space-sweeper/install.html)**

SpaceSweeper scans your Mac, rates every large file, folder and cache **Safe**, **Review**, **Careful** or **Protected**, explains what happens if you delete it, and moves what you choose to the Trash, always after a review step. It works offline and never reads the contents of your files.

## Features

- **Overview:** free space at a glance, the biggest safe wins, Trash size with Empty Trash, and *System data, explained* (purgeable space, Time Machine local snapshots, apps).
- **Large Files and Old Files:** every big or long-untouched file with a safety rating, a plain-English explanation, filters by rating, and an inspector with details.
- **Folders:** a space map (treemap) to see where space goes at a glance, or a drill-down list.
- **Developer Junk:** Xcode DerivedData, simulators and old DeviceSupport, `node_modules`, `build/`, `target/`, virtualenvs, package-manager caches (npm, Gradle, Maven, NuGet, Homebrew…), app caches, Android emulators, installers in Downloads. Each one says what it is and how it comes back.
- **Applications:** sizes and last-used dates; **uninstall** removes the app *and* its leftovers (caches, preferences, containers, startup helpers).
- **Security Check:** points out startup items, apps and downloads that look unusual (broken signatures, disguised file names, hidden programs that start automatically) using macOS's own signature checks. It's not an antivirus, and nothing is uploaded.
- **Safety first:** Trash by default, a review sheet with Cancel as the default button, a built-in protection list (macOS, Keychains, iCloud Drive, Mail, Photos, `~/.ssh`…), warnings for recently changed files, and an activity log you can export as CSV.
- **Native and accessible:** SwiftUI, light and dark mode, VoiceOver labels, Reduce Motion, keyboard shortcuts.

## Requirements

- A Mac (Apple Silicon or Intel) running macOS 14 Sonoma or later
- Xcode 16 or later to build (developed with Xcode 26)

## Build and run

```sh
git clone https://github.com/MatthewFuchs/space-sweeper.git
cd space-sweeper
open SpaceSweeper.xcodeproj      # then press ⌘R
```

Or from the terminal:

```sh
scripts/ci.sh            # build + run all tests (the same script CI uses)
scripts/ci.sh build      # build only
open build/DerivedData/Build/Products/Debug/SpaceSweeper.app
```

The only dependency, [Sparkle](https://github.com/sparkle-project/Sparkle) (automatic updates), is fetched by Swift Package Manager on the first build. Debug builds are ad-hoc signed, so no Apple developer account is needed.

## Full Disk Access

SpaceSweeper isn't sandboxed because it needs to measure your whole home folder. macOS still hides some folders (Mail, Safari, other apps' data, the Trash) until you grant **Full Disk Access**:

1. Launch SpaceSweeper. If access is missing it explains why and offers **Open System Settings**.
2. In *Privacy & Security › Full Disk Access*, turn on **SpaceSweeper** (use **+** if it isn't listed).
3. Return to the app (choose **Quit & Reopen** if macOS asks) and **Rescan**.

Without it the app still works; hidden folders are listed under **Couldn't Scan**. Locally built apps get a new signature on each rebuild, so macOS may forget the permission. Remove and re-add the app if the access screen comes back.

## Safety ratings

| Rating | Meaning | Examples |
|---|---|---|
| **Safe** | Recreated automatically | Caches, build output, installers you've used |
| **Review** | Your data, check first | Documents, photos, videos, downloads |
| **Careful** | Loses app data or settings | Application Support, containers, virtual machines, simulators |
| **Protected** | Never deleted | macOS, `/Library`, Keychains, iCloud Drive, `~/.ssh`, Mail, the Photos library |

Anything changed recently (7 days by default) is never rated Safe. Sizes are space actually used on disk, so sparse files like Docker's disk image show their real footprint. The in-app **Help** section explains every kind of data in more detail.

## Privacy

SpaceSweeper collects nothing: no accounts, analytics, tracking or ads. It reads file names, sizes and dates (plus code signatures for Security Check), keeps its scan results on your Mac, and makes no network connections except optional update checks. See [PRIVACY.md](PRIVACY.md).

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘R / ⌘. | Rescan / cancel scan |
| Space | Quick Look the selected item |
| ⌘⌫ | Move checked items to Trash… |
| ⌥⌘A | Deselect all |
| ⌘, | Settings |
| ⌘? | Help |

## Project layout

```
SpaceSweeper/
  App/        App entry point and AppState (central @Observable model)
  Models/     Scan results, folder tree, treemap layout, settings, help and privacy text
  Scanning/   getattrlistbulk-based parallel scanner and scan cache
  DevJunk/    Developer junk detection rules and catalog
  Safety/     Protection list, safety ratings, deletion, activity log, Trash/system space, Security Check
  Apps/       App inventory, uninstall leftovers, administrator prompt fallback
  Updates/    Sparkle updater and Settings window
  Views/      SwiftUI views
SpaceSweeperTests/   Unit tests (temporary-folder fixtures only; they never touch real files)
scripts/ci.sh        Single build/test entry point
website/             The website (GitHub Pages)
docs/                Maintainer docs
```

Scanning uses `getattrlistbulk(2)` (about 20–25% faster than `FileManager`'s enumerator on a real home folder) and walks subtrees in parallel with Swift concurrency; a full home folder of about a million items scans in roughly 10–15 seconds on Apple Silicon.

## Contributing

Issues and pull requests are welcome.

- Run `scripts/ci.sh` before opening a pull request. CI runs the same script on every push and pull request.
- Add tests for new rules or behaviour. Tests must use the `TestFixture` temporary folders, never real user files.
- Anything that deletes files must go through `DeletionService`, which re-checks the protection list, and must show the review sheet first.

## Releasing

Releases, signing, automatic updates and the website are covered in [docs/RELEASING.md](docs/RELEASING.md).
