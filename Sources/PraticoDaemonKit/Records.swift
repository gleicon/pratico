import Foundation

/// The JSON files pratico keeps its state in (container, network, and volume records, scan
/// reports): ISO 8601 dates, sorted and indented for people who open them, written
/// atomically so a crash never leaves half a file.
enum Records {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(value).write(to: url, options: .atomic)
    }

    /// nil when the file is missing or is not a `T`.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? dec.decode(type, from: $0) }
    }
}
