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

import Foundation

/// A BPF object file as pratico's probes are built (`vm/bpf`, scripts/build-bpf.sh): one
/// function per `raw_tracepoint/<name>` section, maps as `struct pratico_map` globals in
/// `.maps.pratico`, and relocations only from instructions to those maps. Anything else
/// (BPF-to-BPF calls, CO-RE relocations, other sections' data) is refused: the probes
/// are built against the shipped kernel's own types and need nothing more.
package struct BPFObject: Sendable {
    package struct MapDefinition: Sendable, Equatable {
        package var name: String
        package var type: UInt32
        package var keySize: UInt32
        package var valueSize: UInt32
        package var maxEntries: UInt32
    }

    package struct Program: Sendable {
        package var tracepoint: String
        /// Instructions, 8 bytes each.
        package var code: [UInt8]
        /// Byte offsets of the `ld_imm64` instructions that load a map, and its name.
        package var mapLoads: [(offset: Int, map: String)]
    }

    package enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)
        package var description: String {
            switch self {
            case .malformed(let why): "bpf object: \(why)"
            }
        }
    }

    package var license: String
    package var maps: [MapDefinition]
    package var programs: [Program]

    static let maxSections = 64
    static let maxSymbols = 4096
    static let maxRelocations = 4096
    static let mapsSection = ".maps.pratico"
    static let programPrefix = "raw_tracepoint/"
    static let instructionSize = 8
    /// R_BPF_64_64: an `ld_imm64` whose immediate is a symbol's address.
    static let relocationMap: UInt64 = 1

    package init(_ data: Data) throws {
        let elf = try ELF(data)
        let sections = try elf.sections()
        let names = try sections.map { try elf.string(at: $0.name, in: sections[Int(elf.stringTable)]) }
        guard let symtab = sections.firstIndex(where: { $0.type == ELF.symbolTable }) else { throw Error.malformed("no symbol table") }
        let symbols = try elf.symbols(sections[symtab])
        let symbolNames = try symbols.map { try elf.string(at: $0.name, in: sections[Int(sections[symtab].link)]) }
        guard let mapsIndex = names.firstIndex(of: Self.mapsSection) else { throw Error.malformed("no \(Self.mapsSection) section") }
        maps = try Self.mapDefinitions(elf, sections[mapsIndex], mapsIndex, symbols, symbolNames)
        guard let licenseIndex = names.firstIndex(of: "license") else { throw Error.malformed("no license") }
        license = String(decoding: try elf.bytes(sections[licenseIndex]).prefix { $0 != 0 }, as: UTF8.self)
        programs = []
        for (index, name) in names.enumerated() where name.hasPrefix(Self.programPrefix) {
            let relocations = names.firstIndex(of: ".rel" + name).map { sections[$0] }
            programs.append(try Self.program(elf, name, sections[index], relocations, symbols, symbolNames, mapsIndex))
        }
        if let text = names.firstIndex(of: ".text"), sections[text].size > 0 {
            throw Error.malformed(".text holds code: a probe calls a function that was not inlined")
        }
        guard !programs.isEmpty else { throw Error.malformed("no \(Self.programPrefix) programs") }
        assert(programs.allSatisfy { $0.code.count % Self.instructionSize == 0 }, "a program is not whole instructions")
    }

    private static func mapDefinitions(
        _ elf: ELF, _ section: ELF.Section, _ index: Int, _ symbols: [ELF.Symbol], _ names: [String]
    ) throws -> [MapDefinition] {
        let bytes = try elf.bytes(section)
        var out: [MapDefinition] = []
        for (symbol, name) in zip(symbols, names) where Int(symbol.section) == index {
            guard symbol.size == 16, bytes.count >= 16, symbol.value <= UInt64(bytes.count - 16) else { throw Error.malformed("map \(name) is not a pratico_map") }
            let at = Int(symbol.value)
            let word = { (i: Int) in ELF.u32(bytes, at + 4 * i) }
            out.append(MapDefinition(name: name, type: word(0), keySize: word(1), valueSize: word(2), maxEntries: word(3)))
        }
        guard !out.isEmpty else { throw Error.malformed("no maps") }
        return out
    }

    private static func program(
        _ elf: ELF, _ name: String, _ section: ELF.Section, _ relocations: ELF.Section?,
        _ symbols: [ELF.Symbol], _ symbolNames: [String], _ mapsIndex: Int
    ) throws -> Program {
        let code = try elf.bytes(section)
        guard !code.isEmpty, code.count % instructionSize == 0 else { throw Error.malformed("\(name) is not whole instructions") }
        var loads: [(offset: Int, map: String)] = []
        if let relocations {
            let entries = try elf.relocations(relocations)
            guard entries.count <= maxRelocations else { throw Error.malformed("\(name) has too many relocations") }
            for r in entries {
                let symbol = Int(r.info >> 32)
                guard r.info & 0xffff_ffff == relocationMap, symbols.indices.contains(symbol), Int(symbols[symbol].section) == mapsIndex else {
                    throw Error.malformed("\(name) has a relocation that is not a map load")
                }
                guard r.offset <= UInt64(code.count), case let offset = Int(r.offset),
                    offset % instructionSize == 0, offset + 2 * instructionSize <= code.count, code[offset] == 0x18
                else {
                    throw Error.malformed("\(name) relocates something that is not an ld_imm64")
                }
                loads.append((offset, symbolNames[symbol]))
            }
        }
        return Program(tracepoint: String(name.dropFirst(programPrefix.count)), code: code, mapLoads: loads)
    }
}

/// Just enough of ELF64, little-endian, to read a relocatable BPF object.
struct ELF {
    struct Section {
        var name: UInt32
        var type: UInt32
        var offset: UInt64
        var size: UInt64
        var link: UInt32
    }

    struct Symbol {
        var name: UInt32
        var section: UInt16
        var value: UInt64
        var size: UInt64
    }

    struct Relocation {
        var offset: UInt64
        var info: UInt64
    }

    static let symbolTable: UInt32 = 2
    static let machineBPF: UInt16 = 247

    let data: [UInt8]
    let stringTable: UInt16

    init(_ data: Data) throws {
        self.data = [UInt8](data)
        guard self.data.count >= 64, self.data.starts(with: [0x7f, 0x45, 0x4c, 0x46, 2, 1]) else {
            throw BPFObject.Error.malformed("not a 64-bit little-endian ELF file")
        }
        guard Self.u16(self.data, 0x12) == Self.machineBPF else { throw BPFObject.Error.malformed("not a BPF object") }
        stringTable = Self.u16(self.data, 0x3e)
    }

    func sections() throws -> [Section] {
        let table = Self.u64(data, 0x28), size = Int(Self.u16(data, 0x3a)), count = Int(Self.u16(data, 0x3c))
        guard size == 64, count <= BPFObject.maxSections, Int(stringTable) < count, table <= UInt64(data.count),
            Int(table) + count * size <= data.count
        else { throw BPFObject.Error.malformed("bad section table") }
        let offset = Int(table)
        return (0..<count).map { i in
            let at = offset + i * size
            return Section(name: Self.u32(data, at), type: Self.u32(data, at + 4), offset: Self.u64(data, at + 24),
                           size: Self.u64(data, at + 32), link: Self.u32(data, at + 40))
        }
    }

    func bytes(_ s: Section) throws -> [UInt8] {
        guard s.offset <= UInt64(data.count), s.size <= UInt64(data.count) - s.offset else { throw BPFObject.Error.malformed("a section runs past the file") }
        return Array(data[Int(s.offset)..<Int(s.offset + s.size)])
    }

    func string(at offset: UInt32, in table: Section) throws -> String {
        let bytes = try self.bytes(table)
        guard Int(offset) < bytes.count else { throw BPFObject.Error.malformed("a name runs past its string table") }
        return String(decoding: bytes[Int(offset)...].prefix { $0 != 0 }, as: UTF8.self)
    }

    func symbols(_ table: Section) throws -> [Symbol] {
        let bytes = try self.bytes(table)
        guard bytes.count % 24 == 0, bytes.count / 24 <= BPFObject.maxSymbols else { throw BPFObject.Error.malformed("bad symbol table") }
        return stride(from: 0, to: bytes.count, by: 24).map {
            Symbol(name: Self.u32(bytes, $0), section: Self.u16(bytes, $0 + 6), value: Self.u64(bytes, $0 + 8), size: Self.u64(bytes, $0 + 16))
        }
    }

    func relocations(_ table: Section) throws -> [Relocation] {
        let bytes = try self.bytes(table)
        guard bytes.count % 16 == 0 else { throw BPFObject.Error.malformed("bad relocation table") }
        return stride(from: 0, to: bytes.count, by: 16).map { Relocation(offset: Self.u64(bytes, $0), info: Self.u64(bytes, $0 + 8)) }
    }

    static func u16(_ b: [UInt8], _ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[at + $1]) << (8 * $1) } }
    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[at + $1]) << (8 * $1) } }
}
