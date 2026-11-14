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
    func plan(containers withContainers: Bool, images withImages: Bool, _ use: ImageUsage, _ ctrs: [ContainerUse], unreferenced: Int64) -> JSON {
        let gone = withContainers ? ctrs.filter { !$0.record.state.running } : []
        let kept = withContainers ? Set(ctrs.filter(\.record.state.running).map(\.record.imageId)) : images.inUse()
        let removed = withImages ? unusedIds(keeping: kept) : []
        let leftover = withImages ? unreferenced : 0
        let bytes = gone.reduce(0) { $0 + $1.rootfs + $1.logs } + use.reclaimable(removed) + leftover
        return [
            "Containers": .array(gone.map { ["Id": .string($0.record.id), "Name": .string($0.record.name), "Size": .int($0.rootfs + $0.logs)] }),
            "Images": .array(use.items.filter { removed.contains($0.image.id) }.map {
                ["Id": .string($0.image.id), "Name": .string($0.image.displayName), "Size": .int($0.size)]
            }),
            "Leftover": .int(leftover),
            "Bytes": .int(bytes),
        ]
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
        let use = imageUse()
        let ctrs = containerUse()
        let content = Self.allocated(store.appending(path: "content").path)
        let unreferenced = max(content - use.referenced, 0)
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
                "Size": .int(content), "Unused": .int(use.reclaimable(unusedIds(keeping: images.inUse()))),
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
            // The guest's init filesystem, shared by every container.
            "Runtime": .int(runtime),
            "Scans": .int(scans),
            "Cleanup": [
                "Containers": plan(containers: true, images: false, use, ctrs, unreferenced: unreferenced),
                "Images": plan(containers: false, images: true, use, ctrs, unreferenced: unreferenced),
                "Both": plan(containers: true, images: true, use, ctrs, unreferenced: unreferenced),
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
                "TotalSize": .int(use.referenced), "Reclaimable": .int(use.reclaimable(unusedIds(keeping: images.inUse()))), "Items": .array(imageItems),
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
