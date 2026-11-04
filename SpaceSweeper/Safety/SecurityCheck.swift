import CoreServices
import Foundation
import Security

// Security Check: flags items worth a second look using signals macOS already provides (code signatures,
// startup items, download records, file names). It is deliberately conservative and is not an antivirus:
// a flag means "unusual", not "malware". Everything runs offline.

/// How strongly an item stands out.
enum SecurityLevel: Int, Comparable, Sendable {
    /// Not normal for legitimate software (tampered signature, disguised name, hidden auto-start program…).
    case suspicious = 0
    /// Uncommon but often harmless (unsigned app, startup item pointing to a missing program…).
    case unusual = 1

    static func < (lhs: SecurityLevel, rhs: SecurityLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String { self == .suspicious ? "Suspicious" : "Unusual" }
    var symbol: String { self == .suspicious ? "exclamationmark.octagon.fill" : "questionmark.diamond.fill" }
}

/// Where a finding came from.
enum SecurityCategory: String, CaseIterable, Sendable {
    case startupItems = "Startup Items"
    case applications = "Applications"
    case downloads = "Downloads, Desktop & Shared"

    var symbol: String {
        switch self {
        case .startupItems: return "power"
        case .applications: return "square.grid.2x2"
        case .downloads: return "arrow.down.circle"
        }
    }
}

struct SecurityFinding: Identifiable, Hashable, Sendable {
    var path: String
    var category: SecurityCategory
    var level: SecurityLevel
    /// Short reasons, most important first.
    var reasons: [String]
    /// Who signed it, e.g. "Signed by Developer ID Application: Example Inc. (ABCDE12345)" or "Not signed".
    var signer: String?
    /// For startup items: the program it launches.
    var program: String?
    /// Where it was downloaded from, when macOS recorded it.
    var source: String?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - Code signatures

/// Result of checking a code signature with Security.framework (offline; resources aren't re-hashed, for speed).
enum SignatureStatus: Equatable, Sendable {
    case apple
    case developer(name: String?, team: String?)
    case adHoc
    case unsigned
    /// The signature doesn't match the code: it was modified after signing, or is broken.
    case invalid(String)
    case missing

    /// Signed by Apple or an identified developer, with a valid signature.
    var isTrusted: Bool {
        switch self {
        case .apple, .developer: return true
        default: return false
        }
    }

    var description: String {
        switch self {
        case .apple: return "Signed by Apple"
        case .developer(let name, let team):
            let who = name ?? "an identified developer"
            return team.map { "Signed by \(who) (\($0))" } ?? "Signed by \(who)"
        case .adHoc: return "Ad-hoc signed (no developer identity)"
        case .unsigned: return "Not signed"
        case .invalid(let reason): return "Signature is not valid (\(reason))"
        case .missing: return "Program not found"
        }
    }
}

enum CodeSignature {
    /// kSecCSNoNetworkAccess (CSCommon.h: 1 << 29), which isn't imported into Swift. Keeps the check offline.
    static let noNetworkAccess: UInt32 = 1 << 29

    static func status(ofPath path: String) -> SignatureStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return .unsigned }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSDoNotValidateResources) | Self.noNetworkAccess)
        let validity = SecStaticCodeCheckValidity(code, flags, nil)
        if validity == errSecCSUnsigned { return .unsigned }
        if validity != errSecSuccess {
            let message = (SecCopyErrorMessageString(validity, nil) as String?) ?? "error \(validity)"
            return .invalid(message)
        }
        var info: CFDictionary?
        SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info)
        let dictionary = info as? [String: Any] ?? [:]
        let codeFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0 { return .adHoc }

        var appleRequirement: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &appleRequirement) == errSecSuccess,
           SecStaticCodeCheckValidity(code, flags, appleRequirement) == errSecSuccess {
            return .apple
        }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        var name: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first {
            name = SecCertificateCopySubjectSummary(leaf) as String?
        }
        return .developer(name: name, team: team)
    }
}

// MARK: - Pure rules (unit-tested)

enum SecurityRules {
    /// Extensions that run code when opened.
    static let executableExtensions: Set<String> = ["app", "command", "tool", "terminal", "pkg", "mpkg", "scpt", "applescript", "workflow", "sh", "jar"]
    /// Extensions people expect to be harmless documents.
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "jpg", "jpeg", "png", "gif", "heic", "mp3", "mp4", "mov", "zip", "csv", "pages", "numbers", "key"]
    /// Places where well-behaved software doesn't keep unsigned programs that start automatically.
    static let oddProgramLocations = ["/tmp", "/private/tmp", "/private/var/tmp", "/Users/Shared"]
    /// Developer-tool locations where ad-hoc signed programs are normal (Homebrew, MacPorts, /usr/local).
    static let devToolLocations = ["/opt/homebrew", "/usr/local", "/opt/local"]
    /// Interpreters used by download-and-run commands.
    static let shells: Set<String> = ["sh", "bash", "zsh", "python", "python3", "perl", "ruby", "osascript"]

    /// "invoice.pdf.app" → true: looks like a document but runs as a program.
    static func isDisguisedName(_ name: String) -> Bool {
        let parts = name.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return false }
        let last = String(parts[parts.count - 1])
        let previous = String(parts[parts.count - 2])
        return executableExtensions.contains(last) && documentExtensions.contains(previous)
    }

    /// Invisible characters that reverse or hide part of a file name.
    static func hasDeceptiveCharacters(_ name: String) -> Bool {
        let deceptive: Set<Unicode.Scalar> = ["\u{202E}", "\u{202D}", "\u{2066}", "\u{2067}", "\u{2068}", "\u{200B}"]
        return name.unicodeScalars.contains { deceptive.contains($0) }
    }

    /// True when any folder in the path (relative to home when inside it) starts with a dot.
    static func isHiddenPath(_ path: String, home: String) -> Bool {
        let relative = PathUtil.isSameOrDescendant(path, of: home) ? String(path.dropFirst(home.count)) : path
        return relative.split(separator: "/").contains { $0.hasPrefix(".") && $0 != ".." && $0 != "." }
    }

    /// A command line that downloads something and runs or decodes it, e.g. `sh -c "curl … | sh"`.
    static func isDownloadAndRun(_ arguments: [String]) -> Bool {
        guard let first = arguments.first, shells.contains((first as NSString).lastPathComponent) else { return false }
        let script = arguments.dropFirst().joined(separator: " ").lowercased()
        let downloads = script.contains("curl ") || script.contains("wget ")
        let runs = script.contains("| sh") || script.contains("|sh") || script.contains("| bash") || script.contains("base64 -d")
            || script.contains("base64 --decode") || script.contains("chmod +x")
        return downloads && runs
    }

    /// Judges a startup item from its launch plist, the program's signature and the user's home folder.
    static func assessStartupItem(plistPath: String, plist: [String: Any], signature: (String) -> SignatureStatus,
                                  home: String) -> SecurityFinding? {
        let arguments = (plist["ProgramArguments"] as? [String]) ?? []
        guard let program = (plist["Program"] as? String) ?? arguments.first else { return nil }
        let status = signature(program)
        var suspicious: [String] = []
        var unusual: [String] = []

        if isDownloadAndRun(arguments) {
            suspicious.append("Downloads and runs code from the internet each time it starts")
        }
        if isHiddenPath(program, home: home) {
            suspicious.append("Starts a program hidden in a folder whose name begins with a dot")
        }
        if case .invalid = status {
            // Self-updating apps often change files after signing, so on its own this is only "unusual".
            unusual.append("The program's signature no longer matches. Often an app updating itself, but it can mean tampering")
        }
        let inOddPlace = oddProgramLocations.contains { PathUtil.isSameOrDescendant(program, of: $0) }
            || PathUtil.isSameOrDescendant(program, of: PathUtil.join(home, "Downloads"))
        let inDevTools = devToolLocations.contains { PathUtil.isSameOrDescendant(program, of: $0) }
        if inOddPlace && !status.isTrusted && status != .missing {
            suspicious.append("Starts an unsigned program from a temporary or shared folder")
        }
        if status == .missing {
            unusual.append("Points to a program that no longer exists (a leftover from an uninstalled app)")
        } else if (status == .unsigned || status == .adHoc) && !inDevTools && !inOddPlace {
            unusual.append("Starts a program that isn't signed by an identified developer")
        }

        guard !suspicious.isEmpty || !unusual.isEmpty else { return nil }
        return SecurityFinding(path: plistPath, category: .startupItems,
                               level: suspicious.isEmpty ? .unusual : .suspicious,
                               reasons: suspicious + unusual, signer: status.description, program: program)
    }

    /// Judges an application bundle from its signature and name.
    static func assessApp(path: String, signature: SignatureStatus, category: SecurityCategory = .applications) -> SecurityFinding? {
        var suspicious: [String] = []
        var unusual: [String] = []
        let name = (path as NSString).lastPathComponent
        if isDisguisedName(name) { suspicious.append("Named like a document but it's an app") }
        if hasDeceptiveCharacters(name) { suspicious.append("Its name contains invisible characters that disguise it") }
        switch signature {
        case .invalid:
            if category == .downloads {
                // A freshly downloaded app whose signature doesn't match is a real red flag.
                suspicious.append("Its signature doesn't match: the download may have been tampered with")
            } else {
                // Installed apps that patch themselves (game launchers, updaters) commonly end up like this.
                unusual.append("Its signature no longer matches, often because the app updated itself. Reinstalling from the developer fixes it")
            }
        case .unsigned, .adHoc:
            unusual.append("Not signed by an identified developer (common for some open-source apps)")
        default:
            break
        }
        guard !suspicious.isEmpty || !unusual.isEmpty else { return nil }
        return SecurityFinding(path: path, category: category, level: suspicious.isEmpty ? .unusual : .suspicious,
                               reasons: suspicious + unusual, signer: signature.description)
    }
}

// MARK: - Scanner

/// Runs the Security Check. Home and folders are injectable so tests use fixtures.
struct SecurityScanner {
    var home: String = NSHomeDirectory()
    var startupFolders: [String] = []
    var appFolders: [String] = []
    var downloadFolders: [String] = []
    var signature: (String) -> SignatureStatus = CodeSignature.status(ofPath:)
    /// Maximum entries examined per download folder (keeps the check quick).
    var maxEntries = 20_000

    static func standard(home: String = NSHomeDirectory()) -> SecurityScanner {
        SecurityScanner(
            home: home,
            startupFolders: [PathUtil.join(home, "Library/LaunchAgents"), "/Library/LaunchAgents", "/Library/LaunchDaemons"],
            appFolders: AppScanner.defaultFolders(home: home),
            downloadFolders: [PathUtil.join(home, "Downloads"), PathUtil.join(home, "Desktop"), "/Users/Shared"])
    }

    func scan() -> [SecurityFinding] {
        let all = startupItemFindings() + appFindings() + downloadFindings()
        let unique = Array(Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values)
        return unique.sorted { ($0.level.rawValue, $0.category.rawValue, $0.name) < ($1.level.rawValue, $1.category.rawValue, $1.name) }
    }

    private func startupItemFindings() -> [SecurityFinding] {
        startupFolders.flatMap { folder -> [SecurityFinding] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
                let path = PathUtil.join(folder, name)
                guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { return nil }
                return SecurityRules.assessStartupItem(plistPath: path, plist: plist, signature: signature, home: home)
            }
        }
    }

    private func appFindings() -> [SecurityFinding] {
        AppScanner.findApps(in: appFolders).compactMap { app in
            guard app.protectionReason == nil else { return nil }
            return SecurityRules.assessApp(path: app.path, signature: signature(app.path))
        }
    }

    /// Walks Downloads/Desktop/Shared (not inside app bundles) looking for disguised or hidden programs.
    private func downloadFindings() -> [SecurityFinding] {
        var findings: [SecurityFinding] = []
        let fm = FileManager.default
        for folder in downloadFolders {
            guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: folder),
                                                 includingPropertiesForKeys: [.isDirectoryKey, .isExecutableKey, .isSymbolicLinkKey],
                                                 options: [.skipsPackageDescendants]) else { continue }
            var count = 0
            for case let url as URL in enumerator {
                count += 1
                if count > maxEntries { break }
                let name = url.lastPathComponent
                let path = url.path
                let ext = url.pathExtension.lowercased()
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isExecutableKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                if values?.isDirectory == true && ext != "app" {
                    // Don't descend into developer projects: they're full of normal hidden executables.
                    if name == "node_modules" || name == ".git" || name.hasSuffix(".xcodeproj") { enumerator.skipDescendants() }
                    continue
                }
                var finding: SecurityFinding?
                if ext == "app" {
                    finding = SecurityRules.assessApp(path: path, signature: signature(path), category: .downloads)
                    // Unsigned apps in Downloads only count with another red flag (many legit downloads are unsigned).
                    if finding?.level == .unusual { finding = nil }
                } else {
                    var reasons: [String] = []
                    if SecurityRules.isDisguisedName(name) { reasons.append("Named like a document but it runs as a program") }
                    if SecurityRules.hasDeceptiveCharacters(name) { reasons.append("Its name contains invisible characters that disguise it") }
                    if name.hasPrefix("."), values?.isExecutable == true, values?.isDirectory != true {
                        reasons.append("A hidden file that can run as a program")
                    }
                    if !reasons.isEmpty {
                        finding = SecurityFinding(path: path, category: .downloads, level: .suspicious, reasons: reasons)
                    }
                }
                if var found = finding {
                    found.source = Self.downloadSource(path)
                    findings.append(found)
                }
            }
        }
        return findings
    }

    /// The website a file was downloaded from, as recorded by macOS (Spotlight's "Where from").
    static func downloadSource(_ path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String] else { return nil }
        return sources.first { $0.hasPrefix("http") } ?? sources.first
    }
}
