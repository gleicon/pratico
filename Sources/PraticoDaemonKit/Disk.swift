import Foundation

/// What pratico keeps on disk, measured as allocated blocks: rootfs images are sparse, so
/// their length says little, and a layer two images share is counted once. Serves Docker's
/// `GET /system/df` and `POST /containers/prune`, and the menubar's `GET /pratico/disk`.
struct DiskService {
    let home: URL
    let images: ImageService
    let containers: ContainerService

    private var store: URL { home.appending(path: "store", directoryHint: .isDirectory) }
    private var blobs: URL { store.appending(path: "content/blobs/sha256", directoryHint: .isDirectory) }

    /// Bytes allocated under `path`, symlinks not followed.
    static func allocated(_ path: String) -> Int64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        let own = Int64(st.st_blocks) * 512
        guard st.st_mode & S_IFMT == S_IFDIR else { return own }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.reduce(own) { $0 + allocated(path + "/" + $1) }
    }

    struct ImageUse {
        var image: LocalImage
        var size: Int64
        var shared: Int64
        var containers: Int
    }

    struct ContainerUse {
        var record: ContainerRecord
        var rootfs: Int64
        var logs: Int64
    }

    /// Per image: its blobs' size, the part other images share, and its containers.
    /// Images whose record lists no blobs (the CLI backend) fall back to their layer sizes.
    /// `referenced`: bytes of the blobs some image holds; the rest of the store is garbage.
    func imageUse() -> (items: [ImageUse], unusedReclaimable: Int64, referenced: Int64) {
        let all = images.localImages()
        var holders: [String: Set<String>] = [:]
        for img in all { for b in img.record["blobs"]?.strings ?? [] { holders[b, default: []].insert(img.id) } }
        let counts = Dictionary(grouping: containers.all(), by: \.imageId).mapValues(\.count)
        let used = images.inUse()
        var sizes: [String: Int64] = [:]
        func size(_ blob: String) -> Int64 {
            if let s = sizes[blob] { return s }
            let s = Self.allocated(blobs.appending(path: blob).path)
            sizes[blob] = s
            return s
        }
        var items: [ImageUse] = []
        for img in all {
            let mine = img.record["blobs"]?.strings ?? []
            let total = mine.isEmpty ? (ImageService.variant(img.record)?["size"]?.int ?? 0) : mine.reduce(0) { $0 + size($1) }
            let shared = mine.filter { (holders[$0]?.count ?? 0) > 1 }.reduce(0) { $0 + size($1) }
            items.append(ImageUse(image: img, size: total, shared: shared, containers: counts[img.id] ?? 0))
        }
        // What removing every unused image frees: blobs no image in use holds.
        let unused = Set(all.map(\.id)).subtracting(used)
        let freed = holders.filter { $0.value.isSubset(of: unused) }.keys.reduce(Int64(0)) { $0 + size($1) }
        let fallback = items.filter { $0.image.record["blobs"] == nil && unused.contains($0.image.id) }.reduce(Int64(0)) { $0 + $1.size }
        let referenced = holders.keys.reduce(Int64(0)) { $0 + size($1) }
        return (items, freed + fallback, referenced)
    }

    func containerUse() -> [ContainerUse] {
        containers.all().map { rec in
            let files = ShimFiles(dir: containers.root.appending(path: rec.id, directoryHint: .isDirectory))
            let logs = Self.allocated(files.log.path) + Self.allocated(files.log.path + ".1")
            return ContainerUse(record: rec, rootfs: Self.allocated(files.dir.path) - logs, logs: logs)
        }
    }

    /// `GET /pratico/disk`: the menubar's Disk menu.
    func usage() -> JSON {
        let (imgs, unused, referenced) = imageUse()
        let ctrs = containerUse()
        let content = Self.allocated(store.appending(path: "content").path)
        let runtime = Self.allocated(store.appending(path: "initfs.ext4").path)
        let scans = Self.allocated(home.appending(path: "scan-db").path) + Self.allocated(home.appending(path: "scans").path)
        let running = ctrs.filter(\.record.state.running)
        let stopped = ctrs.filter { !$0.record.state.running }
        let sum: ([ContainerUse]) -> Int64 = { $0.reduce(0) { $0 + $1.rootfs } }
        let logs = ctrs.reduce(Int64(0)) { $0 + $1.logs }
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        return [
            // Every part below is its own slice: they add up to Total.
            "Total": .int(content + runtime + scans + sum(ctrs) + logs),
            "Free": .int(free),
            "Images": [
                "Size": .int(content), "Unused": .int(unused),
                "Unreferenced": .int(max(content - referenced, 0)),
                "Items": .array(imgs.map { u in
                    ["Id": .string(u.image.id), "Tags": JSON(u.image.tags), "Size": .int(u.size), "Shared": .int(u.shared),
                     "Containers": .int(Int64(u.containers))]
                }),
            ],
            "Containers": [
                "Running": .int(sum(running)), "Stopped": .int(sum(stopped)),
                "Logs": .int(logs),
                "Items": .array(ctrs.map { c in
                    ["Id": .string(c.record.id), "Name": .string(c.record.name), "Image": .string(c.record.image),
                     "Running": .bool(c.record.state.running), "Size": .int(c.rootfs), "Logs": .int(c.logs)]
                }),
            ],
            // The guest's init filesystem, shared by every container.
            "Runtime": .int(runtime),
            "Scans": .int(scans),
        ]
    }

    /// Docker's `GET /system/df`: the legacy lists, from which older CLIs derive
    /// "reclaimable", and the per-type summaries newer ones read.
    func df() -> JSON {
        let (imgs, unusedReclaimable, referenced) = imageUse()
        let sizes = Dictionary(uniqueKeysWithValues: imgs.map { ($0.image.id, $0.size) })
        let imageItems: [JSON] = imgs.map { u in
            var s = ImageService.summary(u.image)
            s["Size"] = .int(u.size)
            s["SharedSize"] = .int(u.shared)
            s["Containers"] = .int(Int64(u.containers))
            return s
        }
        let ctrs = containerUse()
        let containerItems: [JSON] = ctrs.map { c in
            var s = containers.summary(c.record)
            s["SizeRw"] = .int(c.rootfs)
            s["SizeRootFs"] = .int(c.rootfs + (sizes[c.record.imageId] ?? 0))
            return s
        }
        let unusedImages = imgs.filter { $0.containers == 0 }
        let stopped = ctrs.filter { !$0.record.state.running }
        let empty: JSON = ["ActiveCount": 0, "TotalCount": 0, "TotalSize": 0, "Reclaimable": 0, "Items": []]
        return [
            "LayersSize": .int(Self.allocated(store.appending(path: "content").path)),
            "ImageUsage": [
                "ActiveCount": .int(Int64(imgs.count - unusedImages.count)), "TotalCount": .int(Int64(imgs.count)),
                "TotalSize": .int(referenced), "Reclaimable": .int(unusedReclaimable), "Items": .array(imageItems),
            ],
            "ContainerUsage": [
                "ActiveCount": .int(Int64(ctrs.count - stopped.count)), "TotalCount": .int(Int64(ctrs.count)),
                "TotalSize": .int(ctrs.reduce(0) { $0 + $1.rootfs }), "Reclaimable": .int(stopped.reduce(0) { $0 + $1.rootfs }),
                "Items": .array(containerItems),
            ],
            "VolumeUsage": empty,
            "BuildCacheUsage": empty,
            "Images": .array(imageItems),
            "Containers": .array(containerItems),
            "Volumes": [],
            "BuildCache": [],
        ]
    }

    /// `POST /containers/prune`: removes every container that is not running.
    func pruneContainers(filters: [String: [String]]) throws -> JSON {
        guard filters.isEmpty else { throw APIError(400, "pratico: container prune filters are not supported yet") }
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for c in containerUse() where !c.record.state.running {
            guard (try? containers.remove(c.record.id, force: false)) != nil else { continue }
            deleted.append(.string(c.record.id))
            reclaimed += c.rootfs + c.logs
        }
        return ["ContainersDeleted": deleted.isEmpty ? .null : .array(deleted), "SpaceReclaimed": .int(reclaimed)]
    }
}
