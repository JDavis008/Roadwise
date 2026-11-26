import Foundation
import Compression

/// One downloadable state, as listed in the offline manifest (tools/ios-offline/pack_states.py).
struct OfflineState: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let abbr: String
    /// south, west, north, east
    let bbox: [Double]
    let url: String
    let bytes: Int64
    let unpackedBytes: Int64
    let sha256: String
    let tiles: Int

    /// A smaller box for the map tiles, where most of the state's box is ocean (Hawaii).
    var mapBbox: [Double]? = nil

    /// The area to download map tiles for.
    var mapBounds: [Double] { mapBbox?.count == 4 ? mapBbox! : bbox }

    func contains(_ c: Coord) -> Bool {
        bbox.count == 4 && c.latitude >= bbox[0] && c.latitude <= bbox[2] && c.longitude >= bbox[1] && c.longitude <= bbox[3]
    }
}

struct OfflineManifest: Codable {
    let version: Int
    let states: [OfflineState]
}

/// A state that's on the phone: which files it unpacked (tiles are shared between neighbours).
struct InstalledState: Codable {
    let state: OfflineState
    var files: [String]
    var installed: Date
}

struct OfflineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Streams an .xz file to a plain file with Apple's Compression framework (LZMA, xz container).
enum XZ {
    static func decompress(_ src: URL, to dst: URL, progress: (Double) -> Void = { _ in }) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        let total = max(1, (try? FileManager.default.attributesOfItem(atPath: src.path)[.size] as? NSNumber)?.int64Value ?? 1)

        let size = 1 << 20
        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { srcBuf.deallocate(); dstBuf.deallocate(); stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw OfflineError(message: "Couldn't start unpacking")
        }
        defer { compression_stream_destroy(stream) }
        stream.pointee.src_size = 0

        var eof = false, read: Int64 = 0, idle = 0
        while true {
            if stream.pointee.src_size == 0 && !eof {
                let chunk = try input.read(upToCount: size) ?? Data()
                if chunk.isEmpty { eof = true } else {
                    chunk.copyBytes(to: srcBuf, count: chunk.count)
                    stream.pointee.src_ptr = UnsafePointer(srcBuf)
                    stream.pointee.src_size = chunk.count
                    read += Int64(chunk.count)
                    progress(Double(read) / Double(total))
                }
            }
            stream.pointee.dst_ptr = dstBuf
            stream.pointee.dst_size = size
            let status = compression_stream_process(stream, eof ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
            let produced = size - stream.pointee.dst_size
            if produced > 0 { try output.write(contentsOf: Data(bytes: dstBuf, count: produced)) }
            switch status {
            case COMPRESSION_STATUS_END: return
            case COMPRESSION_STATUS_OK:
                if eof && produced == 0 { idle += 1; if idle > 3 { throw OfflineError(message: "The download is incomplete") } }
            default:
                throw OfflineError(message: "The download is damaged")
            }
        }
    }
}

/// Minimal ustar reader (what pack_states.py writes): regular files only.
enum Tar {
    /// Extracts every regular file under `dest` and returns their relative paths.
    static func extract(_ tar: URL, to dest: URL, progress: (Double) -> Void = { _ in }) throws -> [String] {
        let fh = try FileHandle(forReadingFrom: tar)
        defer { try? fh.close() }
        let total = max(1, (try? FileManager.default.attributesOfItem(atPath: tar.path)[.size] as? NSNumber)?.int64Value ?? 1)
        var files: [String] = []
        var offset: Int64 = 0
        let fm = FileManager.default
        while true {
            guard let data = try fh.read(upToCount: 512), data.count == 512 else { break }
            offset += 512
            let h = [UInt8](data)
            if h.allSatisfy({ $0 == 0 }) { break }
            let name = field(h, 0, 100), prefix = field(h, 345, 155)
            let size = Int64(field(h, 124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            let type = h[156]
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let safe = !path.isEmpty && !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
            if (type == 0x30 || type == 0) && safe {
                let url = dest.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
                let out = try FileHandle(forWritingTo: url)
                var left = size
                while left > 0 {
                    let chunk = try fh.read(upToCount: Int(min(left, 1 << 20))) ?? Data()
                    if chunk.isEmpty { try? out.close(); throw OfflineError(message: "The download is incomplete") }
                    try out.write(contentsOf: chunk)
                    left -= Int64(chunk.count)
                }
                try out.close()
                files.append(path)
            } else if size > 0 {
                try fh.seek(toOffset: UInt64(offset + size))
            }
            offset += size
            let pad = (512 - size % 512) % 512
            offset += pad
            try fh.seek(toOffset: UInt64(offset))
            progress(Double(offset) / Double(total))
        }
        return files
    }

    private static func field(_ h: [UInt8], _ start: Int, _ len: Int) -> String {
        let bytes = h[start..<(start + len)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
