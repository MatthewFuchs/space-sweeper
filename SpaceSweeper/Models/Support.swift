import Foundation
import SwiftUI

/// Decimal megabyte, matching how Finder reports sizes.
let MB: Int64 = 1_000_000
let GB: Int64 = 1_000_000_000

extension Int64 {
    /// "1.2 GB" style, same units Finder uses.
    var formattedBytes: String {
        Self.byteFormatter.string(fromByteCount: self)
    }

    /// File-style formatter that writes "0 bytes" rather than the system default "Zero KB".
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

enum PathUtil {
    /// Joins a directory path and a child name without doubling slashes.
    static func join(_ directory: String, _ name: String) -> String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    /// True when `path` equals `ancestor` or lies inside it (component-wise, so "/Library" ≠ "/LibraryX").
    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    /// Absolute, symlink-resolved, no trailing slash.
    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        while resolved.count > 1 && resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }

    /// Drops roots that are inside other roots, so nothing is counted twice.
    static func dedupedRoots(_ roots: [String]) -> [String] {
        let sorted = Array(Set(roots.map(normalize))).sorted { $0.count < $1.count }
        var kept: [String] = []
        for root in sorted where !kept.contains(where: { isSameOrDescendant(root, of: $0) }) {
            kept.append(root)
        }
        return kept
    }

    /// Replaces the home folder prefix with "~" for display.
    static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        isSameOrDescendant(path, of: home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Royal blue and white palette.
enum Theme {
    /// #4169E1 royal blue.
    static let royalBlue = Color(red: 0x41 / 255, green: 0x69 / 255, blue: 0xE1 / 255)
    static let accent = Color.accentColor
    /// Royal-blue gradient for hero cards and header icon tiles.
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.36, green: 0.52, blue: 0.96), royalBlue, Color(red: 0.16, green: 0.29, blue: 0.75)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Shades of royal blue for charts, darkest first.
    static let chartPalette: [Color] = [
        Color(red: 0.12, green: 0.23, blue: 0.62),
        Color(red: 0.18, green: 0.32, blue: 0.78),
        royalBlue,
        Color(red: 0.35, green: 0.50, blue: 0.94),
        Color(red: 0.50, green: 0.63, blue: 0.97),
        Color(red: 0.64, green: 0.74, blue: 0.98),
        Color(red: 0.77, green: 0.84, blue: 0.99),
        Color(red: 0.62, green: 0.65, blue: 0.72),
    ]
}
