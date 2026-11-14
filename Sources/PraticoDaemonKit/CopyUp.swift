import ContainerizationArchive
import ContainerizationEXT4
import Foundation
import SystemPackage

/// Docker's volume copy-up: an empty volume mounted where the image has files starts with
/// a copy of them (SPEC D-32), so `-v data:/var/lib/app` keeps what the image put there.
/// Read from the container's rootfs on the Mac, before the VM boots; no guest help needed.
enum CopyUp {
    static let typeMask: UInt16 = 0o170000
    static let dirType: UInt16 = 0o040000
    static let fileType: UInt16 = 0o100000
    static let linkType: UInt16 = 0o120000
    static let chunk = 4 << 20

    /// Copies what `rootfs` holds under `path` into `dest`, an empty directory: directories,
    /// regular files, and symlinks, with their permission bits. Ownership stays the Mac
    /// user's, as with any file on a volume. Nothing happens if `path` is not a directory.
    ///
    /// The image is untrusted: every entry is made relative to its parent's descriptor with
    /// `O_NOFOLLOW` and `O_EXCL` (`mkdirat`, `symlinkat`), so a symlink in the image, or a
    /// second entry of the same name, can never send a write outside `dest`.
    static func copy(rootfs: URL, path: String, into dest: URL) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        guard let (_, top) = try? reader.stat(FilePath(path)), top.mode & typeMask == dirType else { return }
        let root = open(dest.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(root) }
        try walk(reader, FilePath(path), root, depth: 0)
    }

    static let maxDepth = 64

    private static func fail(_ what: String) -> Error {
        APIError(500, "copy-up \(what): \(String(cString: strerror(errno)))")
    }

    /// `docker cp` out of a stopped container: the entry at `path` (file, directory, or
    /// link) copied from its rootfs into `dest` as `name`, with the same safety as copy-up.
    static func copyOut(rootfs: URL, path: String, into dest: URL, as name: String) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        let root = open(dest.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(root) }
        try entry(reader, FilePath(path), root, name, depth: 0)
    }

    /// `lstat` of a path in the rootfs: size, mode bits, mtime, link target.
    static func stat(rootfs: URL, path: String) throws -> (size: Int64, mode: UInt32, mtime: Int, link: String) {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        let (_, inode) = try reader.stat(FilePath(path), followSymlinks: false)
        let size = Int64(inode.sizeLow) | (Int64(inode.sizeHigh) << 32)
        return (size, UInt32(inode.mode), Int(inode.mtime), inode.mode & typeMask == linkType ? linkTarget(reader, FilePath(path), inode) ?? "" : "")
    }

    private static func linkTarget(_ reader: EXT4.EXT4Reader, _ src: FilePath, _ inode: EXT4.Inode) -> String? {
        // Targets under 60 bytes live in the inode itself (ext4 fast symlinks); longer
        // ones are read as the link's data.
        let size = Int(inode.sizeLow)
        if size < 60 { return withUnsafeBytes(of: inode.block) { String(bytes: $0.prefix(size), encoding: .utf8) } }
        return (try? reader.readFile(at: src, count: size, followSymlinks: false)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func walk(_ reader: EXT4.EXT4Reader, _ dir: FilePath, _ parent: Int32, depth: Int) throws {
        guard depth < maxDepth else { throw APIError(500, "copy-up: \(dir) nests too deeply") }
        for name in try reader.listDirectory(dir) {
            // One plain component, never a path: the entry is made in `parent` itself.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
            try entry(reader, dir.appending(name), parent, name, depth: depth)
        }
    }

    /// One entry from the rootfs made as `name` in `parent`, never following a link.
    private static func entry(_ reader: EXT4.EXT4Reader, _ src: FilePath, _ parent: Int32, _ name: String, depth: Int) throws {
        let (_, inode) = try reader.stat(src, followSymlinks: false)
        let perms = mode_t(inode.mode & 0o7777)
        switch inode.mode & typeMask {
        case dirType:
            guard mkdirat(parent, name, 0o700) == 0 else { throw fail("mkdir \(src)") }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw fail("open \(src)") }
            defer { close(fd) }
            try walk(reader, src, fd, depth: depth + 1)
            fchmod(fd, perms)
        case fileType:
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw fail("create \(src)") }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var offset: UInt64 = 0
            while case let data = try reader.readFile(at: src, offset: offset, count: chunk, followSymlinks: false), !data.isEmpty {
                try h.write(contentsOf: data)
                offset += UInt64(data.count)
            }
            fchmod(fd, perms)
            try h.close()
        case linkType:
            if let target = linkTarget(reader, src, inode), !target.isEmpty, symlinkat(target, parent, name) != 0 {
                throw fail("symlink \(src)")
            }
        default:
            break  // devices, FIFOs, sockets: not copied
        }
    }
}

/// Changes to a stopped container's rootfs from the Mac, without a VM (`docker cp` into a
/// stopped container): the filesystem is exported, a fresh one is formatted, and the old
/// contents, then the new files, are unpacked into it, as image layers are; the new image
/// replaces the old one atomically. Costs a rewrite of the rootfs, so in time it is
/// proportional to the container's files.
enum RootfsEdit {
    static func add(_ files: URL, to rootfs: URL) throws {
        let fm = FileManager.default
        let dir = rootfs.deletingLastPathComponent()
        let export = dir.appending(path: "rootfs-export.tar")
        let fresh = dir.appending(path: "rootfs-new.ext4")
        defer {
            try? fm.removeItem(at: export)
            try? fm.removeItem(at: fresh)
        }
        try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path)).export(archive: FilePath(export.path))
        let capacity = max((try? rootfs.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0, 8 << 30)
        try blocking {
            let formatter = try EXT4.Formatter(FilePath(fresh.path), minDiskSize: capacity)
            try await formatter.unpack(reader: try ArchiveReader(file: export))
            try await formatter.unpack(reader: try ArchiveReader(file: files))
            try formatter.close()
        }
        _ = try fm.replaceItemAt(rootfs, withItemAt: fresh)
    }
}
