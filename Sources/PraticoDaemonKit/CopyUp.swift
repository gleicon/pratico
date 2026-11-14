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

    private static func walk(_ reader: EXT4.EXT4Reader, _ dir: FilePath, _ parent: Int32, depth: Int) throws {
        guard depth < maxDepth else { throw APIError(500, "copy-up: \(dir) nests too deeply") }
        for name in try reader.listDirectory(dir) {
            // One plain component, never a path: the entry is made in `parent` itself.
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { continue }
            let src = dir.appending(name)
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
                // Targets under 60 bytes live in the inode itself (ext4 fast symlinks); longer
                // ones are read as the link's data. The link is stored, never followed.
                let size = Int(inode.sizeLow)
                var target: String?
                if size < 60 {
                    target = withUnsafeBytes(of: inode.block) { String(bytes: $0.prefix(size), encoding: .utf8) }
                } else if let data = try? reader.readFile(at: src, count: size, followSymlinks: false) {
                    target = String(data: data, encoding: .utf8)
                }
                if let target, !target.isEmpty, symlinkat(target, parent, name) != 0 { throw fail("symlink \(src)") }
            default:
                continue  // devices, FIFOs, sockets: not copied, as with Docker's copy-up of special files
            }
        }
    }
}
