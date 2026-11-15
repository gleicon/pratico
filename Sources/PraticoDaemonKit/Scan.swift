import Foundation
import PraticoCore

/// One finding from any scanner, deduplicated by advisory across scanners.
struct ScanFinding: Codable, Equatable, Sendable {
    var id: String
    var aliases: [String] = []
    var sources: [String]
    var package: String
    var version: String
    var fixed: [String] = []
    var severity: String  // critical | high | medium | low | unknown
    var cvss: Double?
    var malicious = false  // OpenSSF Malicious Packages (MAL-*)
    var kev = false  // CISA Known Exploited Vulnerabilities
    /// FIRST EPSS: the probability (0–1) of exploitation in the next 30 days, and its
    /// percentile among all CVEs; the highest among the finding's CVEs.
    var epss: Double? = nil
    var epssPercentile: Double? = nil

    var cves: [String] { ([id] + aliases).filter { $0.hasPrefix("CVE-") } }
}

struct ScannerRun: Codable, Equatable, Sendable {
    var name: String
    var ran: Bool
    var note = ""
}

/// `~/.pratico/scans/<image hex id>.json`.
struct ScanReport: Codable, Sendable {
    var imageId: String
    var refs: [String]
    var time: Date
    var scanners: [ScannerRun]
    var findings: [ScanFinding]
    /// Bill of materials: every package osv-scanner found, vulnerable or not.
    var packages: [String]
    var kevDate: String?
}

/// Verdict under a `scan_block` level (D-24): `serious` stops and blocks the image.
enum ScanVerdict: String, Codable, Sendable {
    case serious, warning, ok, unknown

    static func judge(_ findings: [ScanFinding], ran: Bool, block: String) -> (ScanVerdict, [String]) {
        guard ran else { return (.unknown, ["no scanner ran"]) }
        // Which finding kinds block at each level; anything else found only warns.
        let blocking: Set<String> = switch block {
        case "malware": ["malicious"]
        case "kev": ["malicious", "kev"]
        case "critical": ["malicious", "kev", "critical"]
        default: []  // off
        }
        var serious: [String] = []
        var warnings: [String] = []
        for f in findings {
            let label = "\(f.id) in \(f.package) \(f.version)"
            let (kind, text): (String, String) =
                f.malicious ? ("malicious", "malicious package: \(label)")
                : f.kev ? ("kev", "exploited (CISA KEV): \(label)")
                : f.severity == "critical" ? ("critical", "critical: \(label)")
                : f.severity == "high" ? ("high", "high: \(label)")
                : ("", "")
            if kind.isEmpty { continue }
            if blocking.contains(kind) { serious.append(text) } else { warnings.append(text) }
        }
        if !serious.isEmpty { return (.serious, serious) }
        if !warnings.isEmpty { return (.warning, warnings) }
        return (.ok, [])
    }
}

enum ScanParsers {
    static func severity(cvss: Double?) -> String {
        guard let s = cvss else { return "unknown" }
        return s >= 9 ? "critical" : s >= 7 ? "high" : s >= 4 ? "medium" : "low"
    }

    /// `osv-scanner scan image --format json --all-packages`.
    static func osv(_ data: Data) -> (findings: [ScanFinding], packages: [String]) {
        guard let json = JSON.parse(data) else { return ([], []) }
        var findings: [ScanFinding] = []
        var packages: [String] = []
        for result in json["results"]?.array ?? [] {
            for p in result["packages"]?.array ?? [] {
                let name = p["package"]?["name"]?.string ?? "?"
                let version = p["package"]?["version"]?.string ?? "?"
                let eco = p["package"]?["ecosystem"]?.string ?? ""
                packages.append("\(eco)/\(name)@\(version)")
                for g in p["groups"]?.array ?? [] {
                    let ids = g["ids"]?.strings ?? []
                    guard let id = ids.first else { continue }
                    let cvss = g["max_severity"]?.string.flatMap(Double.init)
                    let aliases = Array(Set((g["aliases"]?.strings ?? []) + ids.dropFirst())).filter { $0 != id }.sorted()
                    findings.append(ScanFinding(
                        id: id, aliases: aliases, sources: ["osv"], package: name, version: version,
                        severity: severity(cvss: cvss), cvss: cvss,
                        malicious: ([id] + aliases).contains { $0.hasPrefix("MAL-") }))
                }
            }
        }
        return (findings, packages)
    }

    /// `grype <source> -o json`.
    static func grype(_ data: Data) -> [ScanFinding] {
        guard let json = JSON.parse(data) else { return [] }
        return (json["matches"]?.array ?? []).compactMap { m in
            guard let v = m["vulnerability"], let id = v["id"]?.string else { return nil }
            let related = (m["relatedVulnerabilities"]?.array ?? []).compactMap { $0["id"]?.string }
            let cvss = (v["cvss"]?.array ?? []).compactMap { $0["metrics"]?["baseScore"]?.double }.max()
            return ScanFinding(
                id: id, aliases: related.filter { $0 != id }, sources: ["grype"],
                package: m["artifact"]?["name"]?.string ?? "?", version: m["artifact"]?["version"]?.string ?? "?",
                fixed: v["fix"]?["versions"]?.strings ?? [],
                severity: (v["severity"]?.string ?? "unknown").lowercased(), cvss: cvss,
                malicious: id.hasPrefix("MAL-"))
        }
    }

    /// `trivy image --input <archive> --format json`.
    static func trivy(_ data: Data) -> [ScanFinding] {
        guard let json = JSON.parse(data) else { return [] }
        return (json["Results"]?.array ?? []).flatMap { result in
            (result["Vulnerabilities"]?.array ?? []).compactMap { v -> ScanFinding? in
                guard let id = v["VulnerabilityID"]?.string else { return nil }
                let cvss = (v["CVSS"]?.object ?? [:]).values.compactMap { $0["V3Score"]?.double }.max()
                return ScanFinding(
                    id: id, sources: ["trivy"], package: v["PkgName"]?.string ?? "?",
                    version: v["InstalledVersion"]?.string ?? "?",
                    fixed: (v["FixedVersion"]?.string).map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } } ?? [],
                    severity: (v["Severity"]?.string ?? "unknown").lowercased(), cvss: cvss, malicious: id.hasPrefix("MAL-"))
            }
        }
    }

    /// A `scan_custom` scanner's output: `{"findings": [{"id", "package", "version",
    /// "severity", "fixed"?, "aliases"?, "cvss"?, "malicious"?}]}`; nil if it is not that.
    static func custom(_ data: Data, source: String) -> [ScanFinding]? {
        guard let items = JSON.parse(data)?["findings"]?.array else { return nil }
        let severities: Set<String> = ["critical", "high", "medium", "low", "unknown"]
        return items.compactMap { f in
            guard let id = f["id"]?.string, let package = f["package"]?.string else { return nil }
            let severity = (f["severity"]?.string ?? "unknown").lowercased()
            return ScanFinding(
                id: id, aliases: f["aliases"]?.strings ?? [], sources: [source], package: package,
                version: f["version"]?.string ?? "?", fixed: f["fixed"]?.strings ?? [],
                severity: severities.contains(severity) ? severity : "unknown", cvss: f["cvss"]?.double,
                malicious: f["malicious"]?.bool ?? id.hasPrefix("MAL-"))
        }
    }

    /// Previous findings a now-failed scanner contributed to; kept so a scanner outage
    /// (osv-scanner offline, say) cannot drop a malicious flag or a higher severity and
    /// lift a block. `merge` keeps the strictest values when the other scanner re-reports.
    static func carryOver(_ prior: [ScanFinding], failed: Set<String>) -> [ScanFinding] {
        prior.filter { !failed.isDisjoint(with: $0.sources) }
    }

    /// Joins findings that name the same advisory (by ID or alias) for the same package.
    static func merge(_ lists: [[ScanFinding]]) -> [ScanFinding] {
        let rank = ["critical": 4, "high": 3, "medium": 2, "low": 1, "unknown": 0]
        var out: [ScanFinding] = []
        for f in lists.flatMap({ $0 }) {
            let names = Set([f.id] + f.aliases)
            if let i = out.firstIndex(where: { $0.package == f.package && !names.isDisjoint(with: [$0.id] + $0.aliases) }) {
                var e = out[i]
                e.sources = Array(Set(e.sources + f.sources)).sorted()
                e.aliases = Array(Set(e.aliases + f.aliases + [f.id]).subtracting([e.id])).sorted()
                e.fixed = Array(Set(e.fixed + f.fixed)).sorted()
                if (rank[f.severity] ?? 0) > (rank[e.severity] ?? 0) { e.severity = f.severity }
                e.cvss = [e.cvss, f.cvss].compactMap { $0 }.max()
                e.malicious = e.malicious || f.malicious
                out[i] = e
            } else {
                out.append(f)
            }
        }
        return out
    }
}

/// Background image scanning (SPEC D-24, docs/design/image-scanning.md): after a pull,
/// export the image, run every installed scanner (`Scanners.swift`), mark CISA KEV CVEs, and judge
/// by `scan_block`. A serious verdict stops the image's running Docker containers and
/// blocks new starts until the image is in `scan_allow`.
final class ScanService: @unchecked Sendable {
    let images: ImageService
    let containers: ContainerService
    let config: Config
    let dir: URL
    let alerts: AlertLog
    let events: EventBus
    private let dbDir: URL
    private let queue = DispatchQueue(label: "pratico.scan")
    private let lock = NSLock()
    private var pending: Set<String> = []
    private var blocked: [String: String] = [:]  // image ID → reason
    private var verdicts: [String: ScanVerdict] = [:]  // image ID → latest verdict, for the summary
    private var severe: Set<String> = []  // image IDs with a critical or high finding (or malware, or KEV)
    let env = ProcessInfo.processInfo.environment
    static let kevURL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
    static let rescanInterval: TimeInterval = 24 * 3600

    let home: URL
    /// `scan_allow`, normalized to full IDs; grows when the menubar allows an image.
    private var allowed: Set<String>
    private let allowLock = NSLock()

    init(home: URL, images: ImageService, containers: ContainerService, config: Config, events: EventBus, alerts: AlertLog) {
        self.home = home
        allowed = Set(config.scanAllow.map { $0.hasPrefix("sha256:") ? $0 : "sha256:" + $0 })
        self.images = images
        self.containers = containers
        self.config = config
        self.events = events
        dir = home.appending(path: "scans", directoryHint: .isDirectory)
        dbDir = home.appending(path: "scan-db", directoryHint: .isDirectory)
        self.alerts = alerts
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        loadBlocked()
        // A deleted image's report goes with it, so its findings stop counting.
        _ = events.subscribe(since: nil) { [weak self] e in
            guard let self else { return false }
            if e.type == "image" && e.action == "delete" { forget(e.id) }
            return true
        }
    }

    private func forget(_ imageId: String) {
        try? FileManager.default.removeItem(at: path(imageId))
        for f in [SBOMFormat.spdx, .cyclonedx] { try? FileManager.default.removeItem(at: sbomFile(imageId, f)) }
        lock.lock()
        verdicts[imageId] = nil
        severe.remove(imageId)
        blocked[imageId] = nil
        lock.unlock()
    }

    /// Scans images never scanned, then rescans everything daily: advisories change.
    func startBackground() {
        guard config.scan else { return }
        Thread.detachNewThread { [self] in
            while true {
                for img in images.localImages() where report(img.id) == nil || isStale(img.id) { enqueue(img.id) }
                Thread.sleep(forTimeInterval: 3600)
            }
        }
    }

    // MARK: Gate

    /// Reason a container from this image may not start, if any.
    func blockReason(imageId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return blocked[imageId]
    }

    private func setBlocked(_ id: String, _ reason: String?) {
        lock.lock()
        blocked[id] = reason
        lock.unlock()
    }

    /// Verdicts are recomputed from stored findings, so `scan_block` and `scan_allow`
    /// changes apply at the next daemon start without rescanning.
    private func loadBlocked() {
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let r = Self.decode(file) else { continue }
            setVerdict(r)
            if let reason = gateReason(r) { setBlocked(r.imageId, reason) }
        }
    }

    private func gateReason(_ r: ScanReport) -> String? {
        let (verdict, reasons) = ScanVerdict.judge(r.findings, ran: r.scanners.contains(where: \.ran), block: config.scanBlock)
        guard verdict == .serious, !isAllowed(r.imageId) else { return nil }
        let name = ImageRef.displayName(refs: r.refs, id: r.imageId)
        return "image \(name) is blocked by pratico's scan: \(reasons.prefix(3).joined(separator: "; ")). "
            + "Allow it in the menubar's Scan Results, or add \"\(r.imageId)\" to scan_allow in ~/.pratico/config.toml, to run it anyway."
    }

    func isAllowed(_ imageId: String) -> Bool {
        allowLock.lock()
        defer { allowLock.unlock() }
        return allowed.contains(imageId)
    }

    /// `POST /pratico/scans/{id}/allow` (the menubar's Allow This Image…): the image may
    /// run despite its findings, at once and after restarts, as `scan_allow` in
    /// config.toml, where the rest of the file is kept as it is. Its alert is cleared.
    func allow(_ ref: String) throws {
        guard let img = images.resolve(ref)?.image else { throw APIError(404, "No such image: \(ref)") }
        allowLock.lock()
        defer { allowLock.unlock() }
        guard !allowed.contains(img.id) else { return }
        let file = Config.path(home: home)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let current = ((try? Config.parse(text))?.scanAllow ?? []).filter { !$0.isEmpty }
        do {
            try Config.setting("scan_allow", to: .strings(current + [img.id]), in: text).write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw APIError(500, "cannot update \(file.path): \(error)")
        }
        allowed.insert(img.id)
        setBlocked(img.id, nil)
        alerts.resolve(key: "image:\(img.id)")
        events.touch()
    }

    // MARK: Scanning

    /// `POST /pratico/scans`: every local image, now (the menubar's Scan Now).
    func rescanAll() -> JSON {
        guard config.scan else { return ["Queued": 0, "Enabled": false] }
        let all = images.localImages()
        for img in all { enqueue(img.id) }
        return ["Queued": .int(Int64(all.count)), "Enabled": true]
    }

    /// `GET /pratico/scans`: each local image's latest report, verdict, and which scanner
    /// reported each finding (`sources`); images still queued or running are `Scanning`.
    func results() -> JSON {
        lock.lock()
        let scanning = pending
        lock.unlock()
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return .array(images.localImages().map { img in
            var out: [String: JSON] = ["Id": .string(img.id), "Name": .string(img.displayName), "Tags": JSON(img.tags), "Scanning": .bool(scanning.contains(img.id))]
            if let r = report(img.id), let data = try? enc.encode(r), let json = JSON.parse(data) {
                let (verdict, reasons) = ScanVerdict.judge(r.findings, ran: r.scanners.contains(where: \.ran), block: config.scanBlock)
                out["Report"] = json
                out["Verdict"] = .string(verdict.rawValue)
                out["Reasons"] = JSON(reasons)
                out["Blocked"] = .bool(blockReason(imageId: img.id) != nil)
                out["Allowed"] = .bool(isAllowed(img.id))
                out["SBOM"] = .bool(FileManager.default.fileExists(atPath: sbomFile(img.id, .spdx).path))
            }
            return .object(out)
        })
    }

    func enqueue(_ nameOrId: String) {
        guard config.scan, let img = images.resolve(nameOrId)?.image else { return }
        lock.lock()
        let fresh = pending.insert(img.id).inserted
        lock.unlock()
        guard fresh else { return }
        events.touch()
        queue.async { [self] in
            defer {
                lock.lock()
                pending.remove(img.id)
                lock.unlock()
                events.touch()
            }
            scan(img)
        }
    }

    private func scan(_ img: LocalImage) {
        let fm = FileManager.default
        let archive = fm.temporaryDirectory.appending(path: "pratico-scan-\(UUID().uuidString).tar")
        defer { try? fm.removeItem(at: archive) }
        do { try images.exportArchive(img.id, to: archive) } catch { return }

        var runs: [ScannerRun] = []
        var lists: [[ScanFinding]] = []
        var packages: [String] = []
        var failed: Set<String> = []
        for (scanner, path) in scanners {
            guard let path else {
                runs.append(ScannerRun(name: scanner.name, ran: false, note: "not installed"))
                failed.insert(scanner.source)
                continue
            }
            switch scanner.scan(path, archive, img) {
            case .success(let r):
                lists.append(r.findings)
                if packages.isEmpty { packages = r.packages }
                runs.append(ScannerRun(name: scanner.name, ran: true))
            case .failure(let f):
                runs.append(ScannerRun(name: scanner.name, ran: false, note: f.note))
                failed.insert(scanner.source)
            }
        }

        // A failed run is no new information: never let it clear findings or a block.
        let prior = report(img.id)
        guard runs.contains(where: \.ran) || prior == nil else { return }
        lists.append(ScanParsers.carryOver(prior?.findings ?? [], failed: failed))

        let (kev, kevDate) = knownExploited()
        var findings = ScanParsers.merge(lists)
        for i in findings.indices where !kev.isDisjoint(with: findings[i].cves) { findings[i].kev = true }
        let odds = exploitPrediction(Set(findings.flatMap(\.cves)))
        for i in findings.indices {
            guard let best = findings[i].cves.compactMap({ odds[$0] }).max(by: { $0.score < $1.score }) else { continue }
            findings[i].epss = best.score
            findings[i].epssPercentile = best.percentile
        }
        let report = ScanReport(imageId: img.id, refs: img.refs, time: Date(), scanners: runs,
                                findings: findings, packages: packages, kevDate: kevDate)
        // Deleted while it was scanned: `forget` already ran, so saving would bring it back.
        guard images.resolve(img.id) != nil else { return }
        save(report)
        writeSBOM(archive, image: img)
        act(report)
    }

    private func setVerdict(_ r: ScanReport) {
        let (verdict, _) = ScanVerdict.judge(r.findings, ran: r.scanners.contains(where: \.ran), block: config.scanBlock)
        let isSevere = r.findings.contains(where: Self.isSevere)
        lock.lock()
        verdicts[r.imageId] = verdict
        if isSevere { severe.insert(r.imageId) } else { severe.remove(r.imageId) }
        lock.unlock()
    }

    /// What the menubar flags: medium and low findings are listed in Scan Results, not raised.
    static func isSevere(_ f: ScanFinding) -> Bool {
        f.severity == "critical" || f.severity == "high" || f.malicious || f.kev
    }

    /// `GET /pratico/scans/summary`: counts the menubar polls, from memory.
    func summary() -> JSON {
        let ids = images.localImages().map(\.id)
        lock.lock()
        defer { lock.unlock() }
        let blockedCount = ids.filter { blocked[$0] != nil }.count
        // Worth a look, short of a block: a critical or high finding (or one scan_allow lets run).
        let flagged = ids.filter { blocked[$0] == nil && severe.contains($0) }.count
        return ["Images": .int(Int64(ids.count)), "Blocked": .int(Int64(blockedCount)), "CriticalOrHigh": .int(Int64(flagged)),
                "Scanning": .int(Int64(ids.filter { pending.contains($0) }.count)),
                "Unscanned": .int(Int64(ids.filter { verdicts[$0] == nil }.count))]
    }

    /// Findings short of a block show in Scan Results; only a block raises an alert, the one
    /// that becomes a notification.
    private func act(_ r: ScanReport) {
        let name = ImageRef.displayName(refs: r.refs, id: r.imageId)
        let (_, reasons) = ScanVerdict.judge(r.findings, ran: r.scanners.contains(where: \.ran), block: config.scanBlock)
        setVerdict(r)
        guard let reason = gateReason(r) else {
            setBlocked(r.imageId, nil)
            return
        }
        setBlocked(r.imageId, reason)
        var stopped: [String] = []
        for rec in containers.all() where rec.imageId == r.imageId && rec.state.running {
            if (try? containers.stop(rec.id, timeout: 10)) == true { stopped.append(rec.name) }
        }
        // One alert per image: a rescan replaces the earlier one instead of piling up.
        alerts.raise(key: "image:\(r.imageId)", level: "serious", title: "\(name) blocked: \(reasons.first ?? "serious finding")",
                     detail: (reasons.prefix(5) + (stopped.isEmpty ? [] : ["stopped: " + stopped.joined(separator: ", ")]))
                         .joined(separator: "\n"), replace: true)
    }

    // MARK: Storage

    private func path(_ imageId: String) -> URL { dir.appending(path: "\(imageId.dropFirst(7)).json") }

    func report(_ imageId: String) -> ScanReport? { Self.decode(path(imageId)) }

    private func isStale(_ imageId: String) -> Bool {
        guard let r = report(imageId) else { return true }
        return Date().timeIntervalSince(r.time) > Self.rescanInterval
    }

    private func save(_ r: ScanReport) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(r).write(to: path(r.imageId), options: .atomic)
    }

    private static func decode(_ url: URL) -> ScanReport? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? dec.decode(ScanReport.self, from: $0) }
    }

    // MARK: Feeds and tools

    /// CISA KEV CVE IDs, cached for a day; a stale cache beats none when offline.
    private func knownExploited() -> (Set<String>, String?) {
        let cache = dbDir.appending(path: "kev.json")
        let age = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 24 * 3600, let url = URL(string: env["PRATICO_KEV_URL"] ?? Self.kevURL) {
            let done = DispatchSemaphore(value: 0)
            let fetched = Box<Data?>(nil)
            URLSession.shared.dataTask(with: url) { data, response, _ in
                let ok = (response as? HTTPURLResponse).map { $0.statusCode == 200 } ?? url.isFileURL
                if ok, let data, JSON.parse(data)?["vulnerabilities"] != nil { fetched.value = data }
                done.signal()
            }.resume()
            _ = done.wait(timeout: .now() + 30)
            if let data = fetched.value { try? data.write(to: cache, options: .atomic) }
        }
        guard let json = (try? Data(contentsOf: cache)).flatMap(JSON.parse) else { return ([], nil) }
        let ids = (json["vulnerabilities"]?.array ?? []).compactMap { $0["cveID"]?.string }
        return (Set(ids), json["dateReleased"]?.string)
    }

    static let epssURL = "https://api.first.org/data/v1/epss"

    /// FIRST EPSS scores for `cves`, from `scan-db/epss.json` when fetched in the last day,
    /// else from the EPSS API in batches of 100 (only CVE IDs are sent). Offline, whatever
    /// the cache holds; a `file://` URL (tests) is read whole, in the API's JSON shape.
    private func exploitPrediction(_ cves: Set<String>) -> [String: (score: Double, percentile: Double)] {
        guard !cves.isEmpty else { return [:] }
        let cache = dbDir.appending(path: "epss.json")
        var known = ((try? Data(contentsOf: cache)).flatMap(JSON.parse)?.object ?? [:])
        let now = Date().timeIntervalSince1970
        let stale = cves.filter { (known[$0]?["fetched"]?.double ?? 0) < now - 24 * 3600 }.sorted()
        if !stale.isEmpty, let base = URL(string: env["PRATICO_EPSS_URL"] ?? Self.epssURL) {
            let batches = base.isFileURL ? [stale] : stride(from: 0, to: stale.count, by: 100).map { Array(stale[$0..<min($0 + 100, stale.count)]) }
            for batch in batches {
                var url = base
                if !base.isFileURL { url.append(queryItems: [URLQueryItem(name: "cve", value: batch.joined(separator: ","))]) }
                let done = DispatchSemaphore(value: 0)
                let fetched = Box<Data?>(nil)
                URLSession.shared.dataTask(with: url) { data, response, _ in
                    if (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? base.isFileURL { fetched.value = data }
                    done.signal()
                }.resume()
                _ = done.wait(timeout: .now() + 30)
                let wanted = Set(batch)
                for row in fetched.value.flatMap(JSON.parse)?["data"]?.array ?? [] {
                    guard let cve = row["cve"]?.string, wanted.contains(cve),
                        let score = row["epss"]?.string.flatMap(Double.init), let pct = row["percentile"]?.string.flatMap(Double.init)
                    else { continue }
                    known[cve] = ["epss": .double(score), "percentile": .double(pct), "fetched": .double(now)]
                }
            }
            try? JSON.object(known).encoded().write(to: cache, options: .atomic)
        }
        var out: [String: (score: Double, percentile: Double)] = [:]
        for cve in cves {
            if let s = known[cve]?["epss"]?.double, let p = known[cve]?["percentile"]?.double { out[cve] = (s, p) }
        }
        return out
    }

    /// Runs a scanner, by default with a 15-minute bound (grype's first run downloads its
    /// database). `environment` adds to the daemon's own.
    static func run(_ path: String, _ args: [String], environment: [String: String] = [:], timeout: Int = 900) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = args
        if !environment.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new } }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return ProcessResult(status: 127, stdout: Data(), stderr: Data("\(error)".utf8)) }
        let errData = Box<Data>(Data())
        let outData = Box<Data>(Data())
        let group = DispatchGroup()
        for (box, pipe) in [(outData, out), (errData, err)] {
            group.enter()
            DispatchQueue.global().async {
                box.value = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if group.wait(timeout: .now() + .seconds(timeout)) == .timedOut { p.terminate() }
        p.waitUntilExit()
        return ProcessResult(status: p.terminationStatus, stdout: outData.value, stderr: errData.value)
    }
}
