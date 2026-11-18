//===----------------------------------------------------------------------===//
// Copyright © 2026 the Pratico project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Added by the Pratico project (Vendor/README.md).
//===----------------------------------------------------------------------===//

import ContainerizationError
import Foundation

extension LinuxSeccomp {
    /// What a profile's conditions are resolved against: one container on arm64.
    public struct Target: Sendable {
        /// The container's bounding capabilities (`CAP_SYS_ADMIN`, …), as Docker checks.
        public var capabilities: [String]
        /// The guest kernel's version, for `minKernel`.
        public var kernel: (major: Int, minor: Int)

        public init(capabilities: [String], kernel: (major: Int, minor: Int)) {
            self.capabilities = capabilities
            self.kernel = kernel
        }
    }

    /// Decodes a profile in either format: the OCI runtime spec's (`decode(from:)`) or
    /// Docker's, whose `includes` / `excludes` conditions are resolved for `target` as
    /// moby's `setupSeccomp` does, so a rule gated on `CAP_SYS_ADMIN` applies only when
    /// the container has it. Docker's architecture names are Go's (`arm64`).
    public static func decodeAnyFormat(from data: Data, for target: Target) throws -> LinuxSeccomp {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], dockerFormatMarker(in: object) != nil else {
            return try decode(from: data)
        }
        let profile: DockerProfile
        do {
            profile = try JSONDecoder().decode(DockerProfile.self, from: data)
        } catch {
            throw ContainerizationError(.invalidArgument, message: "seccomp profile could not be decoded as Docker's format: \(error)")
        }
        return try profile.resolved(for: target)
    }
}

private struct DockerProfile: Decodable {
    struct ArchMapEntry: Decodable {
        var architecture: String
        var subArchitectures: [String]?
    }
    struct Filter: Decodable {
        var caps: [String]?
        var arches: [String]?
        var minKernel: String?
    }
    struct Syscall: Decodable {
        var name: String?
        var names: [String]?
        var action: LinuxSeccompAction
        var errnoRet: UInt?
        var args: [LinuxSeccompArg]?
        var includes: Filter?
        var excludes: Filter?
    }

    var defaultAction: LinuxSeccompAction
    var defaultErrnoRet: UInt?
    var architectures: [String]?
    var archMap: [ArchMapEntry]?
    var flags: [LinuxSeccompFlag]?
    var listenerPath: String?
    var listenerMetadata: String?
    var syscalls: [Syscall]?

    static let goArch = "arm64"
    static let seccompArch = "SCMP_ARCH_AARCH64"

    func resolved(for target: LinuxSeccomp.Target) throws -> LinuxSeccomp {
        var rules: [LinuxSyscall] = []
        for call in syscalls ?? [] {
            if call.name != nil, call.names?.isEmpty == false {
                throw ContainerizationError(.invalidArgument, message: "seccomp: a Docker rule has both name and names")
            }
            guard try applies(call, target) else { continue }
            let names = call.names ?? call.name.map { [$0] } ?? []
            rules.append(LinuxSyscall(names: names, action: call.action, errnoRet: call.errnoRet, args: call.args ?? []))
        }
        // archMap lists the native architecture with the ones it also runs; only arm64's
        // matters here, and the filter admits arm64 calls alone.
        var arches = architectures ?? []
        if let map = archMap, !map.isEmpty {
            arches = map.filter { $0.architecture == Self.seccompArch }.flatMap { [$0.architecture] + ($0.subArchitectures ?? []) }
        }
        return LinuxSeccomp(
            defaultAction: defaultAction, defaultErrnoRet: defaultErrnoRet,
            architectures: arches.compactMap { Arch(rawValue: $0) }, flags: flags ?? [],
            listenerPath: listenerPath ?? "", listenerMetadata: listenerMetadata ?? "", syscalls: rules)
    }

    private func applies(_ call: Syscall, _ target: LinuxSeccomp.Target) throws -> Bool {
        if let ex = call.excludes {
            if let a = ex.arches, a.contains(Self.goArch) { return false }
            if let c = ex.caps, c.contains(where: target.capabilities.contains) { return false }
            if let k = ex.minKernel, try atLeast(target.kernel, k) { return false }
        }
        if let inc = call.includes {
            if let a = inc.arches, !a.isEmpty, !a.contains(Self.goArch) { return false }
            if let c = inc.caps, !c.allSatisfy(target.capabilities.contains) { return false }
            if let k = inc.minKernel, try !atLeast(target.kernel, k) { return false }
        }
        return true
    }

    private func atLeast(_ kernel: (major: Int, minor: Int), _ version: String) throws -> Bool {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else {
            throw ContainerizationError(.invalidArgument, message: "seccomp: minKernel \(version) is not major.minor")
        }
        return (kernel.major, kernel.minor) >= (major, minor)
    }
}
