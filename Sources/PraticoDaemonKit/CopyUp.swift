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
    static func copy(rootfs: URL, path: String, into dest: URL) throws {
        let reader = try EXT4.EXT4Reader(blockDevice: FilePath(rootfs.path))
        guard let (_, top) = try? reader.stat(FilePath(path)), top.mode & typeMask == dirType else { return }
        try walk(reader, FilePath(path), dest)
    }

    private static func walk(_ reader: EXT4.EXT4Reader, _ dir: FilePath, _ dest: URL) throws {
        let fm = FileManager.default
        for name in try reader.listDirectory(dir) {
            let src = dir.appending(name)
            let out = dest.appending(path: name)
            let (_, inode) = try reader.stat(src, followSymlinks: false)
            let perms = Int(inode.mode & 0o7777)
            switch inode.mode & typeMask {
            case dirType:
                try fm.createDirectory(at: out, withIntermediateDirectories: false)
                try walk(reader, src, out)
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: out.path)
            case fileType:
                fm.createFile(atPath: out.path, contents: nil)
                let h = try FileHandle(forWritingTo: out)
                defer { try? h.close() }
                var offset: UInt64 = 0
                while case let data = try reader.readFile(at: src, offset: offset, count: chunk, followSymlinks: false), !data.isEmpty {
                    try h.write(contentsOf: data)
                    offset += UInt64(data.count)
                }
                try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: out.path)
            case linkType:
                // Targets under 60 bytes live in the inode itself (ext4 fast symlinks); longer
                // ones are read as the link's data.
                let size = Int(inode.sizeLow)
                var target: String?
                if size < 60 {
                    target = withUnsafeBytes(of: inode.block) { String(bytes: $0.prefix(size), encoding: .utf8) }
                } else if let data = try? reader.readFile(at: src, count: size, followSymlinks: false) {
                    target = String(data: data, encoding: .utf8)
                }
                if let target, !target.isEmpty { try fm.createSymbolicLink(atPath: out.path, withDestinationPath: target) }
            default:
                continue  // devices, FIFOs, sockets: not copied, as with Docker's copy-up of special files
            }
        }
    }
}
