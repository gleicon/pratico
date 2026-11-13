import Foundation
import PraticoCore

/// An image scanner pratico runs on a Docker archive of each pulled image (SPEC D-24).
/// Scanners are external programs by design: they carry their own databases and release
/// cadence. Built-in ones are found where Homebrew and Go put them; `scan_custom` adds any
/// executable that speaks pratico's JSON (`ScanParsers.custom`).
struct ImageScanner: Sendable {
    let name: String
    /// What its findings carry in `sources`.
    let source: String
    /// Overrides the lookup (tests, unusual installs).
    let envOverride: String?
    /// `brew install <formula>`; nil for custom scanners.
    let brew: String?
    let homepage: String
    let versionArgs: [String]
    let builtin: Bool
    /// Runs it on the archive at `archive`: findings and packages, or why it did not run.
    let scan: @Sendable (_ path: String, _ archive: URL, _ image: LocalImage) -> Result<(findings: [ScanFinding], packages: [String]), ScanFailure>

    static let builtins: [ImageScanner] = [
        ImageScanner(
            name: "osv-scanner", source: "osv", envOverride: "PRATICO_OSV_BIN", brew: "osv-scanner",
            homepage: "https://google.github.io/osv-scanner/", versionArgs: ["--version"], builtin: true
        ) { path, archive, _ in
            // Exit 1 means "vulnerabilities found"; other codes are failures.
            let r = ScanService.run(path, ["scan", "image", "--archive", archive.path, "--format", "json", "--all-packages"])
            guard r.status == 0 || r.status == 1 else { return .failure(ScanFailure(r)) }
            let parsed = ScanParsers.osv(r.stdout)
            return .success((parsed.findings, parsed.packages))
        },
        ImageScanner(
            name: "grype", source: "grype", envOverride: "PRATICO_GRYPE_BIN", brew: "grype",
            homepage: "https://github.com/anchore/grype", versionArgs: ["--version"], builtin: true
        ) { path, archive, _ in
            let r = ScanService.run(path, ["docker-archive:\(archive.path)", "-o", "json", "-q"])
            guard r.ok else { return .failure(ScanFailure(r)) }
            return .success((ScanParsers.grype(r.stdout), []))
        },
        ImageScanner(
            name: "trivy", source: "trivy", envOverride: "PRATICO_TRIVY_BIN", brew: "trivy",
            homepage: "https://trivy.dev", versionArgs: ["--version"], builtin: true
        ) { path, archive, _ in
            let r = ScanService.run(path, ["image", "--input", archive.path, "--format", "json", "--quiet"])
            guard r.ok else { return .failure(ScanFailure(r)) }
            return .success((ScanParsers.trivy(r.stdout), []))
        },
    ]

    /// `scan_custom`: run as `<path> <docker-archive.tar>` with `PRATICO_IMAGE_ID` and
    /// `PRATICO_IMAGE_REFS` set; exit 0 and print `{"findings": [...]}` (README).
    static func custom(_ path: String) -> ImageScanner {
        let name = URL(filePath: path).lastPathComponent
        return ImageScanner(name: name, source: name, envOverride: nil, brew: nil, homepage: "", versionArgs: ["--version"], builtin: false) {
            path, archive, image in
            let r = ScanService.run(path, [archive.path], environment: [
                "PRATICO_IMAGE_ID": image.id, "PRATICO_IMAGE_REFS": image.refs.map(ImageRef.familiar).joined(separator: " "),
            ])
            guard r.ok else { return .failure(ScanFailure(r)) }
            guard let findings = ScanParsers.custom(r.stdout, source: name) else {
                return .failure(ScanFailure(note: "output is not pratico scanner JSON"))
            }
            return .success((findings, []))
        }
    }

    /// Where the daemon finds it: its override, else Homebrew's and Go's usual places
    /// (launchd gives the daemon a minimal PATH). Custom scanners are their own path.
    func locate(environment: [String: String], customPath: String? = nil) -> String? {
        let fm = FileManager.default
        if let path = customPath ?? envOverride.flatMap({ environment[$0] }) {
            return fm.isExecutableFile(atPath: (path as NSString).expandingTildeInPath) ? (path as NSString).expandingTildeInPath : nil
        }
        return Self.searchPath.map { "\($0)/\(name)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    static var searchPath: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/go/bin", "\(home)/.local/bin"]
    }
}

struct ScanFailure: Error {
    var note: String
    init(note: String) { self.note = note }
    init(_ r: ProcessResult) {
        let first = String(decoding: r.stderr.isEmpty ? r.stdout : r.stderr, as: UTF8.self).split(separator: "\n").first.map(String.init)
        note = first ?? "exited \(r.status)"
    }
}

extension ScanService {
    /// Every scanner `config.toml` asks for: the built-ins, then `scan_custom` paths.
    var scanners: [(scanner: ImageScanner, path: String?)] {
        ImageScanner.builtins.map { ($0, $0.locate(environment: env)) }
            + config.scanCustom.map { p in let s = ImageScanner.custom(p); return (s, s.locate(environment: env, customPath: p)) }
    }

    /// `GET /pratico/scanners`: the menubar's checkup, like `flutter doctor`.
    func doctor() -> JSON {
        let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
        return [
            "enabled": .bool(config.scan),
            "brew": brew.map(JSON.string) ?? .null,
            "scanners": .array(scanners.map { s, path in
                [
                    "name": .string(s.name), "builtin": .bool(s.builtin),
                    "path": path.map(JSON.string) ?? .null,
                    "version": path.flatMap { Self.version($0, s.versionArgs) }.map(JSON.string) ?? .null,
                    "brew": s.brew.map(JSON.string) ?? .null, "homepage": .string(s.homepage),
                ]
            }),
        ]
    }

    /// The version `<tool> --version` prints, within 5 s: tools word it differently
    /// ("grype 0.111.0", "Version: 0.76.2"), so the first dotted number, else the first line.
    static func version(_ path: String, _ args: [String]) -> String? {
        let r = run(path, args, timeout: 5)
        guard r.ok else { return nil }
        let text = String(decoding: r.stdout.isEmpty ? r.stderr : r.stdout, as: UTF8.self)
        if let m = text.firstMatch(of: /\d+\.\d+(\.\d+)?/) { return String(m.output.0) }
        return text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
