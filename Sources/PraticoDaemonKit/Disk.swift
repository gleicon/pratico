import Foundation

/// What pratico keeps on disk, measured as allocated blocks: rootfs images are sparse, so
/// their length says little, and a layer two images share is counted once. Serves Docker's
/// `GET /system/df` and `POST /containers/prune`, and the menubar's `GET /pratico/disk`.
struct DiskService {
    let home: URL
    let images: ImageService
    let containers: ContainerService
    let volumes: VolumeService

    private var store: URL { home.appending(path: "store", directoryHint: .isDirectory) }
    /// Images unpacked once for new containers (`EmbeddedContainers.prepareRootfs`).
    private var rootfsCache: URL { store.appending(path: "rootfs-cache", directoryHint: .isDirectory) }

    /// Bytes only this file holds on APFS: a clone shares the rest with its source. nil
    /// where the volume does not report it.
    static func privateSize(_ path: String) -> Int64? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 32)
        guard getattrlist(path, &list, &buf, buf.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// The unpacked copy of `imageId`, if any.
    func unpackedSize(_ imageId: String) -> Int64 { Self.allocated(rootfsCache.appending(path: "\(imageId.dropFirst(7)).ext4").path) }
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

    struct VolumeUse {
        var record: VolumeRecord
        var size: Int64
        var containers: Int
    }

    /// One measurement of everything, which the slices and every cleanup plan read.
    struct Measure {
        var images: ImageUsage
        var containers: [ContainerUse]
        var volumes: [VolumeUse]
        var unreferenced: Int64
    }

    /// Every image's size, and the blobs behind them, so any set of images can be priced.
    struct ImageUsage {
        var items: [ImageUse]
        /// Blob digest → the images that hold it.
        var holders: [String: Set<String>]
        var blobSizes: [String: Int64]
        /// Bytes of the blobs some image holds; the rest of the store is garbage.
        var referenced: Int64 { blobSizes.values.reduce(0, +) }

        /// What removing these images frees: blobs no other image holds, and the layer
        /// sizes of images whose blobs cannot be listed.
        func reclaimable(_ removed: Set<String>) -> Int64 {
            let freed = holders.filter { $0.value.isSubset(of: removed) }.keys.reduce(Int64(0)) { $0 + blobSizes[$1, default: 0] }
            return freed + items.filter { $0.image.record["blobs"] == nil && removed.contains($0.image.id) }.reduce(0) { $0 + $1.size }
        }
    }

    /// Per image: its blobs' size, the part other images share, and its containers.
    /// An image whose blobs cannot be listed falls back to its layer sizes.
    func imageUse() -> ImageUsage {
        let all = images.localImages()
        var holders: [String: Set<String>] = [:]
        for img in all { for b in img.record["blobs"]?.strings ?? [] { holders[b, default: []].insert(img.id) } }
        let counts = Dictionary(grouping: containers.all(), by: \.imageId).mapValues(\.count)
        let sizes = Dictionary(uniqueKeysWithValues: holders.keys.map { ($0, Self.allocated(blobs.appending(path: $0).path)) })
        let items = all.map { img in
            let mine = img.record["blobs"]?.strings ?? []
            let total = mine.isEmpty ? (ImageService.variant(img.record)?["size"]?.int ?? 0) : mine.reduce(0) { $0 + sizes[$1, default: 0] }
            let shared = mine.filter { (holders[$0]?.count ?? 0) > 1 }.reduce(0) { $0 + sizes[$1, default: 0] }
            return ImageUse(image: img, size: total, shared: shared, containers: counts[img.id] ?? 0)
        }
        return ImageUsage(items: items, holders: holders, blobSizes: sizes)
    }

    private func unusedIds(keeping used: Set<String>) -> Set<String> { Set(images.unused(keeping: used).map(\.id)) }

    /// What a Disk menu cleanup removes and frees. Containers go first, so with them the
    /// images only stopped containers used go too; images follow `ImageService.unused`,
    /// the rule `prune -a` applies, so the confirmation lists exactly what is deleted.
    func plan(_ m: Measure, containers withContainers: Bool = false, images withImages: Bool = false, volumes withVolumes: Bool = false) -> JSON {
        let gone = withContainers ? m.containers.filter { !$0.record.state.running } : []
        let kept = withContainers ? Set(m.containers.filter(\.record.state.running).map(\.record.imageId)) : images.inUse()
        let removed = withImages ? unusedIds(keeping: kept) : []
        let leftover = withImages ? m.unreferenced : 0
        // Volumes as `docker volume prune -a`: every one no container mounts, named or not.
        let prunable = withVolumes ? Set(volumes.prunable(filters: ["all": ["true"]]).map(\.name)) : []
        let vols = m.volumes.filter { prunable.contains($0.record.name) }
        let bytes = gone.reduce(0) { $0 + $1.rootfs + $1.logs } + m.images.reclaimable(removed) + leftover + vols.reduce(0) { $0 + $1.size }
            + removed.reduce(0) { $0 + unpackedSize($1) }
        return [
            "Containers": .array(gone.map { ["Id": .string($0.record.id), "Name": .string($0.record.name), "Size": .int($0.rootfs + $0.logs)] }),
            "Images": .array(m.images.items.filter { removed.contains($0.image.id) }.map {
                ["Id": .string($0.image.id), "Name": .string($0.image.displayName), "Size": .int($0.size)]
            }),
            "Volumes": .array(vols.map { ["Id": .string($0.record.name), "Name": .string($0.record.name), "Size": .int($0.size)] }),
            "Leftover": .int(leftover),
            "Bytes": .int(bytes),
        ]
    }

    func volumeUse() -> [VolumeUse] {
        let users = volumes.usedBy()
        return volumes.all().map { VolumeUse(record: $0, size: volumes.size($0.name), containers: users[$0.name]?.count ?? 0) }
    }

    func containerUse() -> [ContainerUse] {
        containers.all().map { rec in
            let files = ShimFiles(dir: containers.root.appending(path: rec.id, directoryHint: .isDirectory))
            let logs = Self.allocated(files.log.path) + Self.allocated(files.log.path + ".1")
            // The rootfs is a clone of the unpacked image: only its own blocks are its.
            let rootfs = files.dir.appending(path: "rootfs.ext4").path
            let own = Self.privateSize(rootfs).map { Self.allocated(files.dir.path) - Self.allocated(rootfs) + $0 } ?? Self.allocated(files.dir.path)
            return ContainerUse(record: rec, rootfs: own - logs, logs: logs)
        }
    }

    /// Container summaries or inspects with Docker's `SizeRw` (what the container wrote)
    /// and `SizeRootFs` (that plus its image): `ps --size`, `inspect --size`, `system df`.
    func sized(_ items: [JSON]) -> [JSON] {
        let sizes = Dictionary(uniqueKeysWithValues: imageUse().items.map { ($0.image.id, $0.size) })
        return Self.sized(items, containerUse(), imageSizes: sizes)
    }

    private static func sized(_ items: [JSON], _ use: [ContainerUse], imageSizes: [String: Int64]) -> [JSON] {
        let byId = Dictionary(uniqueKeysWithValues: use.map { ($0.record.id, $0) })
        return items.map { item in
            guard var s = item.object, let id = s["Id"]?.string, let c = byId[id] else { return item }
            s["SizeRw"] = .int(c.rootfs)
            s["SizeRootFs"] = .int(c.rootfs + (imageSizes[c.record.imageId] ?? 0))
            return .object(s)
        }
    }

    /// `GET /pratico/disk`: the menubar's Disk menu.
    func usage() -> JSON {
        let use = imageUse()
        let ctrs = containerUse()
        let vols = volumeUse()
        let content = Self.allocated(store.appending(path: "content").path)
        let unpacked = Self.allocated(rootfsCache.path)
        let unreferenced = max(content - use.referenced, 0)
        let m = Measure(images: use, containers: ctrs, volumes: vols, unreferenced: unreferenced)
        let volumeBytes = vols.reduce(Int64(0)) { $0 + $1.size }
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
            "Total": .int(content + unpacked + runtime + scans + sum(ctrs) + logs + volumeBytes),
            "Free": .int(free),
            "Images": [
                "Size": .int(content), "Unpacked": .int(unpacked), "Unused": .int(use.reclaimable(unusedIds(keeping: images.inUse()))),
                "Unreferenced": .int(unreferenced),
                "Items": .array(use.items.map { u in
                    ["Id": .string(u.image.id), "Name": .string(u.image.displayName), "Tags": JSON(u.image.tags), "Size": .int(u.size), "Shared": .int(u.shared),
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
            "Volumes": [
                "Size": .int(volumeBytes),
                "Unused": .int(vols.filter { $0.containers == 0 }.reduce(0) { $0 + $1.size }),
                "Items": .array(vols.map { v in
                    ["Name": .string(v.record.name), "Size": .int(v.size), "Containers": .int(Int64(v.containers)),
                     "Anonymous": .bool(v.record.anonymous)]
                }),
            ],
            // The guest's init filesystem, shared by every container.
            "Runtime": .int(runtime),
            "Scans": .int(scans),
            "Cleanup": [
                "Containers": plan(m, containers: true),
                "Images": plan(m, images: true),
                "Both": plan(m, containers: true, images: true),
                "Volumes": plan(m, volumes: true),
            ],
        ]
    }

    /// Docker's `GET /system/df`: the legacy lists, from which older CLIs derive
    /// "reclaimable", and the per-type summaries newer ones read.
    func df() -> JSON {
        let use = imageUse()
        let imgs = use.items
        let sizes = Dictionary(uniqueKeysWithValues: imgs.map { ($0.image.id, $0.size) })
        let imageItems: [JSON] = imgs.map { u in
            var s = ImageService.summary(u.image)
            s["Size"] = .int(u.size)
            s["SharedSize"] = .int(u.shared)
            s["Containers"] = .int(Int64(u.containers))
            return s
        }
        let ctrs = containerUse()
        let containerItems = Self.sized(ctrs.map { containers.summary($0.record) }, ctrs, imageSizes: sizes)
        let unusedImages = imgs.filter { $0.containers == 0 }
        let stopped = ctrs.filter { !$0.record.state.running }
        let empty: JSON = ["ActiveCount": 0, "TotalCount": 0, "TotalSize": 0, "Reclaimable": 0, "Items": []]
        let vols = volumeUse()
        let volumeItems: [JSON] = vols.map { volumes.json($0.record, usage: ($0.size, $0.containers)) }
        let unusedVolumes = vols.filter { $0.containers == 0 }
        return [
            "LayersSize": .int(Self.allocated(store.appending(path: "content").path)),
            "ImageUsage": [
                "ActiveCount": .int(Int64(imgs.count - unusedImages.count)), "TotalCount": .int(Int64(imgs.count)),
                "TotalSize": .int(use.referenced), "Reclaimable": .int(use.reclaimable(unusedIds(keeping: images.inUse()))), "Items": .array(imageItems),
            ],
            "ContainerUsage": [
                "ActiveCount": .int(Int64(ctrs.count - stopped.count)), "TotalCount": .int(Int64(ctrs.count)),
                "TotalSize": .int(ctrs.reduce(0) { $0 + $1.rootfs }), "Reclaimable": .int(stopped.reduce(0) { $0 + $1.rootfs }),
                "Items": .array(containerItems),
            ],
            "VolumeUsage": [
                "ActiveCount": .int(Int64(vols.count - unusedVolumes.count)), "TotalCount": .int(Int64(vols.count)),
                "TotalSize": .int(vols.reduce(0) { $0 + $1.size }), "Reclaimable": .int(unusedVolumes.reduce(0) { $0 + $1.size }),
                "Items": .array(volumeItems),
            ],
            "BuildCacheUsage": empty,
            "Images": .array(imageItems),
            "Containers": .array(containerItems),
            "Volumes": .array(volumeItems),
            "BuildCache": [],
        ]
    }

    /// `POST /containers/prune`: removes every container that is not running and matches
    /// Docker's `until` and `label` / `label!` filters.
    func pruneContainers(filters: [String: [String]]) throws -> JSON {
        let filter = try PruneFilter(filters)
        var deleted: [JSON] = []
        var reclaimed: Int64 = 0
        for c in containerUse() where !c.record.state.running && filter.matches(created: c.record.created, labels: c.record.labels) {
            guard (try? containers.remove(c.record.id, force: false)) != nil else { continue }
            deleted.append(.string(c.record.id))
            reclaimed += c.rootfs + c.logs
        }
        return ["ContainersDeleted": deleted.isEmpty ? .null : .array(deleted), "SpaceReclaimed": .int(reclaimed)]
    }
}

