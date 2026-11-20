import ContainerizationArchive
import ContainerizationEXT4
import Foundation

/// Whether what a container ran came with its image (`FromImage` on exec events). The
/// recorder notes, at exec, the loaded file's inode number and change time and whether it
/// is on the container's root filesystem (vm/bpf/recorder.bpf.c). A container's rootfs is
/// a clone of its image's unpacked ext4, so a file it never touched is the image's inode
/// with the image's change time; the guest kernel sets the change time on any write,
/// rename, or metadata change, and nothing in the guest can set it back. So an exec ran
/// the image's file exactly when its (inode, change time) is one of the image's regular
/// files, whatever the container did to the path before or after.
///
/// When pratico rewrites a rootfs (`docker cp` into a stopped container, a crash repair)
/// every inode is new; `carry` then writes `image-files.json` in the container's
/// directory, the new identities of the files that were still the image's, and that list
/// stands for the image from then on.
final class ExecOrigin: @unchecked Sendable {
    /// Inode number → change time in nanoseconds, of regular files.
    typealias Files = [UInt32: Int64]
    static let tableName = "image-files.json"
    static let maxImagesCached = 16

    private let lock = NSLock()
    private var images: [String: Files] = [:]  // unpacked image path → its files

    /// The files that count as the image's for the container in `dir`.
    func files(container dir: URL, image: URL) -> Files? {
        if let data = try? Data(contentsOf: dir.appending(path: Self.tableName)) {
            return (try? JSONDecoder().decode([String: Int64].self, from: data)).map { table in
                Files(uniqueKeysWithValues: table.compactMap { k, v in UInt32(k).map { ($0, v) } })
            }
        }
        if let known = lock.withLock({ images[image.path] }) { return known }
        guard let files = try? Self.identities(image) else { return nil }
        lock.withLock {
            if images.count >= Self.maxImagesCached { images.removeAll() }
            images[image.path] = files
        }
        return files
    }

    /// `FromImage` on each exec event the recorder identified; the identity fields, which
    /// only this check needs, are taken out. Without `files`, nothing is marked.
    static func tag(_ events: [JSON], _ files: Files?) -> [JSON] {
        events.map { e in
            guard e["Kind"]?.string == "exec", var out = e.object, let inode = out["Inode"]?.int else { return e }
            let changed = out["ChangeTime"]?.int, onRoot = out["OnRootfs"]?.bool ?? false
            // A script: what was loaded is its interpreter, so the script's own origin is unknown.
            let interpreted = out["Interpreted"]?.bool ?? false
            for key in ["Inode", "ChangeTime", "OnRootfs", "Interpreted"] { out[key] = nil }
            if let files, let changed, !interpreted {
                out["FromImage"] = .bool(onRoot && UInt32(exactly: inode).flatMap { files[$0] } == changed)
            }
            return .object(out)
        }
    }

    /// The regular files of an ext4 image, by inode.
    static func identities(_ ext4: URL) throws -> Files {
        var out: Files = [:]
        try RootfsTree.walk(ext4) { _, _, number, inode in
            if inode.mode & CopyUp.typeMask == CopyUp.fileType { out[number] = changeTime(inode) }
        }
        return out
    }

    /// The change time as the kernel decodes it: 32 bits of seconds, two epoch bits and
    /// the nanoseconds in `ctimeExtra`.
    static func changeTime(_ inode: EXT4.Inode) -> Int64 {
        let seconds = Int64(inode.ctime) | (Int64(inode.ctimeExtra & 3) << 32)
        return seconds * 1_000_000_000 + Int64(inode.ctimeExtra >> 2)
    }

    /// A rootfs is about to be rewritten (`rewrite` swaps the new filesystem in): the paths
    /// that are still the image's files are noted first, and after it their new
    /// identities are written as the container's table, leaving out paths `written`
    /// replaced. Without `files` (an image no longer stored) the table is not written, so
    /// those execs go unmarked rather than wrong.
    static func carry(_ rootfs: URL, files: Files?, written: Set<String>, rewrite: () throws -> Void) throws {
        var still: Set<String> = []
        if let files {
            try RootfsTree.walk(rootfs) { _, path, number, inode in
                if inode.mode & CopyUp.typeMask == CopyUp.fileType, files[number] == changeTime(inode) { still.insert(path) }
            }
        }
        try rewrite()
        let table = rootfs.deletingLastPathComponent().appending(path: tableName)
        guard files != nil else { try? FileManager.default.removeItem(at: table); return }
        var next: [String: Int64] = [:]
        try RootfsTree.walk(rootfs) { _, path, number, inode in
            if still.contains(path), !written.contains(path), inode.mode & CopyUp.typeMask == CopyUp.fileType { next[String(number)] = changeTime(inode) }
        }
        try JSONEncoder().encode(next).write(to: table, options: .atomic)
    }

    /// The paths a layer tar writes, as absolute paths.
    static func members(_ layer: URL) throws -> Set<String> {
        var out: Set<String> = []
        let reader = try ArchiveReader(file: layer)
        for (entry, _) in reader.makeStreamingIterator() {
            let parts = (entry.path ?? "").split(separator: "/").filter { $0 != "." }
            if !parts.isEmpty { out.insert("/" + parts.joined(separator: "/")) }
        }
        try reader.throwIfStreamFailed()
        return out
    }
}
