import Foundation
import Darwin

/// The kind of a directory entry, as reported by the file system (symlinks are never resolved).
enum EntryType: UInt8, Sendable {
    case file
    case directory
    case symlink
    case other
}

/// One entry of a directory listing. Times are seconds since 1970.
struct DirEntry: Sendable {
    var name: String = ""
    var type: EntryType = .other
    /// Bytes actually allocated on disk (all forks). Sparse and compressed files report their real usage.
    var allocatedSize: Int64 = 0
    /// Logical length of the data fork.
    var logicalSize: Int64 = 0
    var modified: TimeInterval = 0
    var accessed: TimeInterval = 0
    /// BSD flags (`st_flags`), e.g. `SF_DATALESS` for cloud placeholders.
    var flags: UInt32 = 0
    var fileID: UInt64 = 0
    var device: Int32 = 0
    var linkCount: UInt32 = 1
}

/// Lists the immediate children of a directory without following symlinks.
protocol DirectoryLister: AnyObject {
    /// Fills `entries` with the children of `path`. Returns 0 on success or an `errno` value.
    func list(_ path: String, into entries: inout [DirEntry]) -> Int32
}

/// Fast lister built on `getattrlistbulk(2)`: one syscall returns the attributes of many entries.
/// Not thread-safe (it owns a reusable buffer); give each worker its own instance.
final class BulkDirectoryLister: DirectoryLister {
    private let bufferSize = 256 * 1024
    private let buffer: UnsafeMutableRawPointer

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    private static let commonAttributes: attrgroup_t =
        attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_ACCTIME)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FLAGS)
        | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)

    private static let fileAttributes: attrgroup_t =
        attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
        | attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
        | attrgroup_t(truncatingIfNeeded: ATTR_FILE_DATALENGTH)

    func list(_ path: String, into entries: inout [DirEntry]) -> Int32 {
        entries.removeAll(keepingCapacity: true)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return errno }
        defer { close(fd) }

        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Self.commonAttributes
        request.fileattr = Self.fileAttributes

        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 {
                let error = errno
                if error == EINTR { continue }
                return error
            }
            if count == 0 { break }

            var entryStart = UnsafeRawPointer(buffer)
            for _ in 0..<Int(count) {
                let length = Int(entryStart.loadUnaligned(as: UInt32.self))
                if let entry = Self.parseEntry(at: entryStart) {
                    entries.append(entry)
                }
                entryStart += length
            }
        }
        return 0
    }

    private static func has(_ set: attrgroup_t, _ attribute: Int32) -> Bool {
        set & attrgroup_t(truncatingIfNeeded: attribute) != 0
    }

    private static func time(_ ts: timespec) -> TimeInterval {
        TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1_000_000_000
    }

    /// Attributes are packed in bit order, except `ATTR_CMN_ERROR`, which follows the returned-attributes set.
    private static func parseEntry(at start: UnsafeRawPointer) -> DirEntry? {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        var entry = DirEntry()
        var failed = false
        let common = returned.commonattr

        if has(common, ATTR_CMN_ERROR) {
            failed = field.loadUnaligned(as: UInt32.self) != 0
            field += MemoryLayout<UInt32>.size
        }
        if has(common, ATTR_CMN_NAME) {
            let reference = field.loadUnaligned(as: attrreference_t.self)
            let namePointer = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
            entry.name = String(cString: namePointer)
            field += MemoryLayout<attrreference_t>.size
        }
        guard !entry.name.isEmpty else { return nil }
        if has(common, ATTR_CMN_DEVID) {
            entry.device = field.loadUnaligned(as: dev_t.self)
            field += MemoryLayout<dev_t>.size
        }
        if has(common, ATTR_CMN_OBJTYPE) {
            let type = field.loadUnaligned(as: fsobj_type_t.self)
            field += MemoryLayout<fsobj_type_t>.size
            switch type {
            case VREG.rawValue: entry.type = .file
            case VDIR.rawValue: entry.type = .directory
            case VLNK.rawValue: entry.type = .symlink
            default: entry.type = .other
            }
        }
        if has(common, ATTR_CMN_MODTIME) {
            entry.modified = time(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        if has(common, ATTR_CMN_ACCTIME) {
            entry.accessed = time(field.loadUnaligned(as: timespec.self))
            field += MemoryLayout<timespec>.size
        }
        if has(common, ATTR_CMN_FLAGS) {
            entry.flags = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if has(common, ATTR_CMN_FILEID) {
            entry.fileID = field.loadUnaligned(as: UInt64.self)
            field += MemoryLayout<UInt64>.size
        }

        let file = returned.fileattr
        if has(file, ATTR_FILE_LINKCOUNT) {
            entry.linkCount = field.loadUnaligned(as: UInt32.self)
            field += MemoryLayout<UInt32>.size
        }
        if has(file, ATTR_FILE_ALLOCSIZE) {
            entry.allocatedSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }
        if has(file, ATTR_FILE_DATALENGTH) {
            entry.logicalSize = field.loadUnaligned(as: off_t.self)
            field += MemoryLayout<off_t>.size
        }

        if failed { entry.type = .other }
        return entry
    }
}

/// Reference implementation using Foundation resource keys plus `lstat` for inode/link data.
/// Slower than `BulkDirectoryLister`; kept as a fallback and as the oracle in tests.
final class FoundationDirectoryLister: DirectoryLister {
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .isPackageKey,
        .fileSizeKey, .totalFileAllocatedSizeKey,
        .contentModificationDateKey, .contentAccessDateKey,
    ]

    func list(_ path: String, into entries: inout [DirEntry]) -> Int32 {
        entries.removeAll(keepingCapacity: true)
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: Self.keys, options: [])
        } catch {
            let ns = error as NSError
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
                return Int32(underlying.code)
            }
            return ns.code == NSFileReadNoPermissionError ? EACCES : EIO
        }
        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(Self.keys)) else { continue }
            var entry = DirEntry()
            entry.name = child.lastPathComponent
            if values.isSymbolicLink == true {
                entry.type = .symlink
            } else if values.isDirectory == true {
                entry.type = .directory
            } else if values.isRegularFile == true {
                entry.type = .file
            }
            entry.allocatedSize = Int64(values.totalFileAllocatedSize ?? 0)
            entry.logicalSize = Int64(values.fileSize ?? 0)
            entry.modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            entry.accessed = values.contentAccessDate?.timeIntervalSince1970 ?? 0
            var info = stat()
            if lstat(child.path, &info) == 0 {
                entry.fileID = info.st_ino
                entry.device = info.st_dev
                entry.linkCount = UInt32(info.st_nlink)
                entry.flags = info.st_flags
            }
            if entry.type == .directory { entry.allocatedSize = 0 }
            entries.append(entry)
        }
        return 0
    }
}
