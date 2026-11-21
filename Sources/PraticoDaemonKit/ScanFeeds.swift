import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The public data scans are enriched with, each cached a day in `scan-db/` so a scan
/// offline still uses the last copy: CISA's catalog of exploited CVEs, and FIRST's EPSS.
extension ScanService {
    static let kevURL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"

    /// The body of a `200` (or a `file://` URL, for tests) within `timeout`; nil otherwise.
    /// Blocking: scans run on their own queue.
    static func fetch(_ url: URL, timeout: TimeInterval = 30) -> Data? {
        // Read directly: Linux's URLSession does not load file URLs.
        if url.isFileURL { return try? Data(contentsOf: url) }
        let done = DispatchSemaphore(value: 0)
        let fetched = Box<Data?>(nil)
        URLSession.shared.dataTask(with: url) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { fetched.value = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout)
        return fetched.value
    }

    /// CISA KEV CVE IDs, cached for a day; a stale cache beats none when offline.
    func knownExploited() -> (Set<String>, String?) {
        let cache = dbDir.appending(path: "kev.json")
        let age = (try? FileManager.default.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 24 * 3600, let url = URL(string: env["PRATICO_KEV_URL"] ?? Self.kevURL),
            let data = Self.fetch(url), JSON.parse(data)?["vulnerabilities"] != nil
        {
            try? data.write(to: cache, options: .atomic)
        }
        guard let json = (try? Data(contentsOf: cache)).flatMap(JSON.parse) else { return ([], nil) }
        let ids = (json["vulnerabilities"]?.array ?? []).compactMap { $0["cveID"]?.string }
        return (Set(ids), json["dateReleased"]?.string)
    }

    static let epssURL = "https://api.first.org/data/v1/epss"

    /// FIRST EPSS scores for `cves`, from `scan-db/epss.json` when fetched in the last day,
    /// else from the EPSS API in batches of 100 (only CVE IDs are sent). Offline, whatever
    /// the cache holds; a `file://` URL (tests) is read whole, in the API's JSON shape.
    func exploitPrediction(_ cves: Set<String>) -> [String: (score: Double, percentile: Double)] {
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
                let wanted = Set(batch)
                for row in Self.fetch(url).flatMap(JSON.parse)?["data"]?.array ?? [] {
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

}
