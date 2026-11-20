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

#if os(Linux)

import ContainerizationOS
import Foundation
import LCShim
import Logging
import Synchronization

#if canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif

/// pratico's flight recorder: loads the probes (`vm/bpf`) at boot and sends their records
/// to the host on `port`, one reader at a time, as `struct pratico_event` (384 bytes, times
/// in CLOCK_REALTIME). Records wait in the kernel's ring buffer while no one reads; past
/// its size the probes drop and count them, and the count is sent as a record. If the
/// probes cannot be loaded, a reader gets one record saying why.
package final class Recorder: Sendable {
    package static let port: UInt32 = 1028
    package static let objectPath = "/usr/lib/pratico/recorder.bpf.o"
    static let kindDrops: UInt32 = 4  // PRATICO_EVENT_DROPS
    static let kindError: UInt32 = 5  // PRATICO_EVENT_ERROR

    /// `struct pratico_event` (vm/bpf/recorder.h): the offsets the recorder writes at.
    enum Layout {
        static let kind = 0, time = 16, value = 24, fileLength = 40, text = 64, size = 384
        static let textCapacity = size - text
    }
    /// Records sent per wakeup at most, so a burst cannot hold the loop.
    static let batchMax = 512

    private let probes: Result<Probes, Swift.Error>
    /// The reader's socket, and replaced ones for `pump`, the only closer, to close
    /// between writes (closing one under a write could hand its number to the next).
    private let readers = Mutex<(current: Int32, retired: [Int32])>((-1, []))
    /// Wakes `pump` when a reader arrives: the host dials just before the container's
    /// process starts, and a short-lived one's records should not wait out a sleep.
    private let readerArrived = DispatchSemaphore(value: 0)
    private let log: Logger

    private init(probes: Result<Probes, Swift.Error>, log: Logger) {
        self.probes = probes
        self.log = log
    }

    /// Loads the probes and starts serving; never fails the boot, as a VM without the
    /// recorder still runs its container.
    package static func start(log: Logger) {
        let probes = Result { try Probes.load(path: objectPath) }
        switch probes {
        case .success(let p): log.info("flight recorder loaded", metadata: ["programs": "\(p.links.count)"])
        case .failure(let e): log.error("flight recorder unavailable: \(e)")
        }
        let recorder = Recorder(probes: probes, log: log)
        let listener: Socket
        do {
            listener = try Socket(type: VsockType(port: port, cid: VsockType.anyCID))
            try listener.listen()
        } catch {
            log.error("flight recorder cannot listen on vsock \(port): \(error)")
            return
        }
        Thread { recorder.accept(listener) }.start()
        if case .success(let p) = probes { Thread { recorder.pump(p) }.start() }
    }

    /// A new reader replaces the one before: the host reconnects after a restart.
    private func accept(_ listener: Socket) {
        while true {
            guard let client = try? listener.accept(closeOnDeinit: false) else {
                usleep(100_000)
                continue
            }
            let fd = dup(client.fileDescriptor)
            try? client.close()
            guard fd >= 0 else { continue }
            if case .failure(let e) = probes {
                var record = Self.record(kind: Self.kindError, value: 0)
                Self.put(text: "\(e)", into: &record)
                _ = Self.send(record[...], to: fd)
                close(fd)
                continue
            }
            readers.withLock { r in
                if r.current >= 0 { r.retired.append(r.current) }
                r.current = fd
            }
            readerArrived.signal()
        }
    }

    /// Moves records from the ring buffer to the reader, with the drop count when it grows:
    /// the probes' count, plus records in a batch a reader went away in the middle of.
    private func pump(_ probes: Probes) {
        let ring = probes.ring
        var dropsSent: UInt64 = 0
        var lost: UInt64 = 0
        var batch: [UInt8] = []
        batch.reserveCapacity((Self.batchMax + 1) * Layout.size)
        while true {
            let (fd, retired) = readers.withLock { r in
                defer { r.retired.removeAll() }
                return (r.current, r.retired)
            }
            for old in retired { close(old) }
            guard fd >= 0 else {
                // No reader: records wait, and the probes count what does not fit.
                _ = readerArrived.wait(timeout: .now() + .milliseconds(250))
                continue
            }
            var p = pollfd(fd: ring.fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&p, 1, 250)
            batch.removeAll(keepingCapacity: true)
            let offset = Self.clockOffset()
            ring.drain(max: Self.batchMax) { record in
                precondition(record.count == Layout.size, "a record of \(record.count) bytes, not \(Layout.size)")
                let start = batch.count
                batch.append(contentsOf: record)
                Self.rebase(&batch, at: start, by: offset)
            }
            let drops = probes.drops() + lost
            if drops > dropsSent {
                batch.append(contentsOf: Self.record(kind: Self.kindDrops, value: drops))
                dropsSent = drops
            }
            guard !batch.isEmpty, !Self.send(batch[...], to: fd) else { continue }
            lost += UInt64(batch.count / Layout.size)
            readers.withLock { r in if r.current == fd { r.current = -1 } else { r.retired.removeAll { $0 == fd } } }
            close(fd)
        }
    }

    /// CLOCK_REALTIME minus CLOCK_BOOTTIME, the probes' clock, in ns.
    static func clockOffset() -> Int64 {
        var real = timespec(), boot = timespec()
        clock_gettime(CLOCK_REALTIME, &real)
        clock_gettime(CLOCK_BOOTTIME, &boot)
        return (Int64(real.tv_sec) - Int64(boot.tv_sec)) * 1_000_000_000 + Int64(real.tv_nsec) - Int64(boot.tv_nsec)
    }

    /// The record's `time_ns` moved from boot time to wall time.
    static func rebase(_ bytes: inout [UInt8], at start: Int, by offset: Int64) {
        bytes.withUnsafeMutableBytes { b in
            let boot = Int64(littleEndian: b.loadUnaligned(fromByteOffset: start + Layout.time, as: Int64.self))
            b.storeBytes(of: (boot &+ offset).littleEndian, toByteOffset: start + Layout.time, as: Int64.self)
        }
    }

    /// A record of the recorder's own, stamped now.
    static func record(kind: UInt32, value: UInt64) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: Layout.size)
        let now = clockOffset() &+ Int64(bootNanoseconds())
        r.withUnsafeMutableBytes { b in
            b.storeBytes(of: kind.littleEndian, toByteOffset: Layout.kind, as: UInt32.self)
            b.storeBytes(of: now.littleEndian, toByteOffset: Layout.time, as: Int64.self)
            b.storeBytes(of: value.littleEndian, toByteOffset: Layout.value, as: UInt64.self)
        }
        return r
    }

    /// `text` as the record's file part, NUL-terminated, cut to fit.
    static func put(text: String, into record: inout [UInt8]) {
        let bytes = Array(text.utf8.prefix(Layout.textCapacity - 1))
        record.replaceSubrange(Layout.text..<(Layout.text + bytes.count), with: bytes)
        record.withUnsafeMutableBytes { $0.storeBytes(of: UInt16(bytes.count + 1).littleEndian, toByteOffset: Layout.fileLength, as: UInt16.self) }
    }

    static func bootNanoseconds() -> UInt64 {
        var boot = timespec()
        clock_gettime(CLOCK_BOOTTIME, &boot)
        return UInt64(boot.tv_sec) * 1_000_000_000 + UInt64(boot.tv_nsec)
    }

    /// Writes all of `bytes`; false when the reader is gone.
    static func send(_ bytes: ArraySlice<UInt8>, to fd: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var done = 0
            while done < buffer.count {
                let n = write(fd, base + done, buffer.count - done)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }
                done += n
            }
            return true
        }
    }
}

/// The probes in the kernel: their maps, the attachments that keep them running (closing
/// one detaches its program), and the ring buffer.
struct Probes: Sendable {
    let links: [Int32]
    let ring: RingBuffer
    let dropsMap: Int32

    static func load(path: String) throws -> Probes {
        let object = try BPFObject(try Data(contentsOf: URL(filePath: path)))
        var maps: [String: Int32] = [:]
        for m in object.maps { maps[m.name] = try BPF.createMap(m) }
        guard let events = maps["events"], let drops = maps["drops"],
            let size = object.maps.first(where: { $0.name == "events" })?.maxEntries
        else { throw BPFObject.Error.malformed("the probes have no events or drops map") }
        var links: [Int32] = []
        for program in object.programs {
            let fd = try BPF.loadProgram(program, maps: maps, license: object.license)
            links.append(try BPF.attachRawTracepoint(program.tracepoint, program: fd))
        }
        assert(links.count == object.programs.count, "a program was not attached")
        return Probes(links: links, ring: try RingBuffer(fd: events, size: Int(size)), dropsMap: drops)
    }

    /// The probes' count of records the ring buffer had no room for.
    func drops() -> UInt64 {
        var key: UInt32 = 0
        var value: UInt64 = 0
        let ok = withUnsafeMutableBytes(of: &key) { k in
            withUnsafeMutableBytes(of: &value) { v in
                var attr = BPF.Attr()
                attr.put32(0, UInt32(bitPattern: dropsMap))
                attr.put64(8, UInt64(UInt(bitPattern: k.baseAddress)))
                attr.put64(16, UInt64(UInt(bitPattern: v.baseAddress)))
                return attr.call(BPF.mapLookupElem) >= 0
            }
        }
        return ok ? value : 0
    }
}

/// A BPF ring buffer read from user space: the consumer position (ours) on the first page,
/// then the producer position and the data, mapped twice so a record is always contiguous.
struct RingBuffer: @unchecked Sendable {
    let fd: Int32
    let size: Int
    private let consumer: UnsafeMutableRawPointer
    private let producer: UnsafeRawPointer
    private var data: UnsafeRawPointer { producer + Self.page }

    static let page = Int(sysconf(Int32(_SC_PAGESIZE)))
    static let busy: UInt32 = 1 << 31
    static let discard: UInt32 = 1 << 30
    static let headerSize = 8

    init(fd: Int32, size: Int) throws {
        precondition(size > 0 && size & (size - 1) == 0, "a ring buffer's size is a power of two")
        guard let c = mmap(nil, Self.page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), c != MAP_FAILED else {
            throw BPF.error("mmap of the ring buffer's consumer page")
        }
        guard let p = mmap(nil, Self.page + 2 * size, PROT_READ, MAP_SHARED, fd, off_t(Self.page)), p != MAP_FAILED else {
            throw BPF.error("mmap of the ring buffer's data")
        }
        self.fd = fd
        self.size = size
        consumer = c
        producer = UnsafeRawPointer(p)
    }

    /// Hands each committed record to `body`, at most `max`, and frees their space.
    func drain(max: Int, _ body: (UnsafeRawBufferPointer) -> Void) {
        var position = CZ_load_acquire_u64(consumer)
        let end = CZ_load_acquire_u64(producer)
        var taken = 0
        while position < end && taken < max {
            let at = Int(position & UInt64(size - 1))
            let header = CZ_load_acquire_u32(data + at)
            guard header & Self.busy == 0 else { break }  // still being written
            let length = Int(header & ~(Self.busy | Self.discard))
            precondition(length <= size, "a record longer than the ring buffer")
            if header & Self.discard == 0 {
                body(UnsafeRawBufferPointer(start: data + at + Self.headerSize, count: length))
            }
            position += UInt64((length + Self.headerSize + 7) & ~7)
            CZ_store_release_u64(consumer, position)
            taken += 1
        }
    }
}

/// The few bpf(2) commands the recorder uses; `attr` is `union bpf_attr`, zeroed.
enum BPF {
    static let mapCreate: Int32 = 0
    static let mapLookupElem: Int32 = 1
    static let progLoad: Int32 = 5
    static let rawTracepointOpen: Int32 = 17
    static let programTypeRawTracepoint: UInt32 = 17
    /// `src_reg` of an `ld_imm64` whose immediate is a map's file descriptor.
    static let pseudoMapFD: UInt8 = 1
    static let logSize = 1 << 20

    struct Attr {
        var bytes = [UInt8](repeating: 0, count: 128)
        mutating func put32(_ at: Int, _ v: UInt32) { bytes.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt32.self) } }
        mutating func put64(_ at: Int, _ v: UInt64) { bytes.withUnsafeMutableBytes { $0.storeBytes(of: v.littleEndian, toByteOffset: at, as: UInt64.self) } }
        mutating func call(_ cmd: Int32) -> Int32 {
            let size = UInt32(bytes.count)
            return bytes.withUnsafeMutableBytes { CZ_bpf(cmd, $0.baseAddress, size) }
        }
    }

    static func error(_ what: String) -> BPFObject.Error { .malformed("\(what): \(String(cString: strerror(errno)))") }

    static func createMap(_ m: BPFObject.MapDefinition) throws -> Int32 {
        var attr = Attr()
        attr.put32(0, m.type)
        attr.put32(4, m.keySize)
        attr.put32(8, m.valueSize)
        attr.put32(12, m.maxEntries)
        let fd = attr.call(mapCreate)
        guard fd >= 0 else { throw error("creating map \(m.name)") }
        return fd
    }

    /// Loads `program` with its map loads pointing at `maps`; the verifier's log is read
    /// only when it refuses, on a second try.
    static func loadProgram(_ program: BPFObject.Program, maps: [String: Int32], license: String) throws -> Int32 {
        var code = program.code
        for load in program.mapLoads {
            guard let fd = maps[load.map] else { throw BPFObject.Error.malformed("\(program.tracepoint) loads unknown map \(load.map)") }
            code[load.offset + 1] = (code[load.offset + 1] & 0x0f) | (pseudoMapFD << 4)
            code.withUnsafeMutableBytes { $0.storeBytes(of: fd.littleEndian, toByteOffset: load.offset + 4, as: Int32.self) }
        }
        func attempt(log: UnsafeMutableRawBufferPointer?) -> Int32 {
            code.withUnsafeBytes { insns in
                license.withCString { lic in
                    var attr = Attr()
                    attr.put32(0, programTypeRawTracepoint)
                    attr.put32(4, UInt32(insns.count / BPFObject.instructionSize))
                    attr.put64(8, UInt64(UInt(bitPattern: insns.baseAddress)))
                    attr.put64(16, UInt64(UInt(bitPattern: lic)))
                    if let log {
                        attr.put32(24, 1)
                        attr.put32(28, UInt32(log.count))
                        attr.put64(32, UInt64(UInt(bitPattern: log.baseAddress)))
                    }
                    return attr.call(progLoad)
                }
            }
        }
        let fd = attempt(log: nil)
        if fd >= 0 { return fd }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: logSize, alignment: 1)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0)
        let again = attempt(log: buffer)
        if again >= 0 { return again }
        let failure = error("loading \(program.tracepoint)")
        let verifier = String(decoding: buffer.prefix { $0 != 0 }.suffix(2048), as: UTF8.self)
        throw BPFObject.Error.malformed("\(failure.description); verifier: \(verifier)")
    }

    static func attachRawTracepoint(_ name: String, program: Int32) throws -> Int32 {
        try name.withCString { tp in
            var attr = Attr()
            attr.put64(0, UInt64(UInt(bitPattern: tp)))
            attr.put32(8, UInt32(bitPattern: program))
            let fd = attr.call(rawTracepointOpen)
            guard fd >= 0 else { throw error("attaching \(name)") }
            return fd
        }
    }
}

#endif
