import Foundation

/// One kind of data the app shows, as explained in Help.
struct DataKind: Identifiable, Sendable {
    let name: String
    let symbol: String
    let examples: String
    let rating: SafetyLevel
    /// What deleting it means, in a few words.
    let ifDeleted: String
    /// Home-relative example path the app rates with `rating`. Used by tests to keep Help truthful.
    let samplePath: String?

    var id: String { name }
}

/// A short question-and-answer pair.
struct HelpFAQ: Identifiable, Sendable {
    let question: String
    let answer: String
    var id: String { question }
}

/// Everything shown in the Help section. Kept as data so the wording is in one place and testable.
enum HelpContent {
    /// The four steps of using the app.
    static let steps: [(symbol: String, title: String, text: String)] = [
        ("magnifyingglass", "Scan", "Reads names, sizes and dates. Never file contents."),
        ("checkmark.shield", "Rate", "Every item gets a safety rating."),
        ("list.bullet.clipboard", "Review", "Nothing is removed until you confirm."),
        ("trash", "Trash", "Removed items go to the Trash, so you can put them back."),
    ]

    /// An example for each safety rating.
    static let ratingExamples: [SafetyLevel: String] = [
        .safe: "Caches, build output, installers you've used",
        .review: "Your documents, photos, videos, downloads",
        .caution: "App data, settings, virtual machines",
        .protected: "macOS, Keychains, iCloud Drive, Mail, Photos",
    ]

    static let dataKinds: [DataKind] = [
        DataKind(name: "Caches", symbol: "internaldrive", examples: "~/Library/Caches, browser caches",
                 rating: .safe, ifDeleted: "Apps rebuild them; may be slower once.",
                 samplePath: "Library/Caches/com.example.app/data"),
        DataKind(name: "Build output", symbol: "hammer", examples: "Xcode DerivedData, node_modules, build/, target/",
                 rating: .safe, ifDeleted: "Recreated on the next build or install.", samplePath: nil),
        DataKind(name: "Package downloads", symbol: "shippingbox", examples: "npm, Gradle, Maven, Homebrew downloads",
                 rating: .safe, ifDeleted: "Downloaded again when needed.", samplePath: nil),
        DataKind(name: "Logs", symbol: "doc.text", examples: "~/Library/Logs",
                 rating: .safe, ifDeleted: "Only used for troubleshooting.", samplePath: "Library/Logs/app.log"),
        DataKind(name: "Installers", symbol: "arrow.down.app", examples: ".dmg, .pkg, .iso in Downloads",
                 rating: .safe, ifDeleted: "Not needed once installed.", samplePath: "Downloads/Installer.dmg"),
        DataKind(name: "Your files", symbol: "person.crop.square", examples: "Documents, Desktop, photos, videos, music",
                 rating: .review, ifDeleted: "Can't be recreated. Back up first.", samplePath: "Movies/holiday.mov"),
        DataKind(name: "Other downloads", symbol: "arrow.down.circle", examples: "Anything else in Downloads",
                 rating: .review, ifDeleted: "Download again if you still need it.", samplePath: "Downloads/report.pdf"),
        DataKind(name: "App data", symbol: "square.stack.3d.up", examples: "Application Support, Containers",
                 rating: .caution, ifDeleted: "Loses settings, saves, chat history or offline content.",
                 samplePath: "Library/Application Support/Some App/data.db"),
        DataKind(name: "Settings & tool folders", symbol: "gearshape", examples: "~/Library/Preferences, ~/.config, ~/.docker",
                 rating: .caution, ifDeleted: "Apps or tools reset or stop working.", samplePath: ".config/tool/settings.json"),
        DataKind(name: "Virtual machines", symbol: "desktopcomputer", examples: "UTM/Parallels VMs, Android emulators, iOS simulators",
                 rating: .caution, ifDeleted: "Everything inside the VM is lost.", samplePath: "VMs/Windows.utm"),
        DataKind(name: "Docker disk image", symbol: "cube.transparent", examples: "Docker Desktop's Docker.raw",
                 rating: .protected, ifDeleted: "Clean it with `docker system prune` instead.", samplePath: nil),
        DataKind(name: "System & vaults", symbol: "lock", examples: "macOS, Keychains, iCloud Drive, Mail, Photos library, ~/.ssh",
                 rating: .protected, ifDeleted: "SpaceSweeper never deletes these.", samplePath: "Library/Keychains/login.keychain-db"),
    ]

    static let faqs: [HelpFAQ] = [
        HelpFAQ(question: "I deleted files but free space didn't change",
                answer: "Items in the Trash still use space until you empty it. macOS may also keep Time Machine local snapshots or count space as \"purgeable\"; it frees those on its own when space runs low."),
        HelpFAQ(question: "Why do sizes differ from Finder's \"Get Info\"?",
                answer: "SpaceSweeper shows space actually used on disk. Sparse files (like Docker's disk image) can be far smaller on disk than their file size; copies made by APFS can share space, so their sizes overlap."),
        HelpFAQ(question: "What does Full Disk Access do?",
                answer: "It lets SpaceSweeper see folders macOS hides by default, such as Mail and other apps' data, so totals are complete. Without it those folders appear under Couldn't Scan."),
        HelpFAQ(question: "Can I undo a deletion?",
                answer: "Yes, if you used Move to Trash: open the Trash in Finder and choose Put Back. \"Delete Permanently\" cannot be undone. The Activity Log lists everything removed."),
        HelpFAQ(question: "Is Security Check an antivirus?",
                answer: "No. It points out things that are unusual for legitimate software, such as a broken app signature, a program disguised as a document, or a hidden program that starts automatically, using checks macOS already provides. A flag isn't proof of malware, and no flag isn't proof of safety. macOS's built-in XProtect and Gatekeeper protect you as well."),
        HelpFAQ(question: "What does uninstalling remove?",
                answer: "The app plus files it left in your Library: caches, preferences, saved state and similar. Matches by app name start unticked so you can check them first."),
    ]

    static let privacy: [String] = [
        "Reads only file names, sizes and dates. Never file contents.",
        "Works offline. Nothing is uploaded or shared.",
        "Scan results and the activity log stay on this Mac, in ~/Library/Application Support/SpaceSweeper.",
    ]

    /// Privacy policy, shown in Settings › Privacy and mirrored in PRIVACY.md. Keep both in sync.
    static let privacyPolicyDate = "November 4, 2026"
    static let privacyPolicy: [(heading: String, body: String)] = [
        ("Summary",
         "SpaceSweeper does not collect, sell or share personal data. It has no accounts, analytics, tracking or ads, and it works offline."),
        ("What SpaceSweeper reads",
         "To show what uses your disk, it reads file and folder names, sizes and dates, and Spotlight's \"last used\" date. To identify apps it reads each app's Info.plist (name, version, bundle identifier) and the background-helper (LaunchAgent) files in your Library. Security Check reads code signatures (using macOS's own checks), the startup-item files in Library, and the download source macOS records for files. It does not open or read the contents of your documents, photos or other files."),
        ("What SpaceSweeper stores",
         "Your last scan, the activity log of items you removed, and your settings are stored only on this Mac, in ~/Library/Application Support/SpaceSweeper and the app's preferences. You can delete the saved scan and clear the log in Settings › Privacy."),
        ("Network",
         "SpaceSweeper makes no network connections, except to check for updates when updates are enabled. An update check downloads a small update list from the developer's server; like any web request, that server sees your IP address and the app version. No other information is sent."),
        ("Permissions",
         "Full Disk Access lets SpaceSweeper measure folders macOS protects; it is used only to read the information above. When you uninstall an app that needs an administrator password, macOS asks for it directly. SpaceSweeper never sees or stores your password."),
        ("Deleting files",
         "SpaceSweeper only removes items you review and confirm. By default they go to the Trash so you can restore them."),
        ("Changes and contact",
         "If this policy changes, the new version will ship with the app and be listed with its date. Questions: open an issue at github.com/MatthewFuchs/space-sweeper."),
    ]
}
