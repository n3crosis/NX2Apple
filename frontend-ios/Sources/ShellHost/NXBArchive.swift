import Foundation
import CryptoKit

/// ZIP/ZIP64 STORE reader for NXB packages. STORE entries only, no encryption,
/// links, multi-disk archives or unlisted content. File data is never buffered
/// as a whole. Central-directory metadata is bounded independently of data size.
enum NXBArchive {
    public static let maximumBytes: UInt64 = 128 << 30
    static let metadataLimit = 8 << 20
    static let directoryLimit: UInt64 = 32 << 20
    static let chunk = 1 << 20

    struct Entry {
        var path: String
        var bytes: UInt64
        var crc: UInt32
        var start: UInt64
        var end: UInt64
    }

    struct Reader {
        let input: FileHandle
        let size: UInt64
        var entries: [String: Entry] = [:]

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw GamePackageError.invalid("NXB must be a regular file")
            }
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard size >= 22, size <= maximumBytes + directoryLimit + UInt64(metadataLimit) else {
                throw GamePackageError.invalid("NXB archive size")
            }
            input = try FileHandle(forReadingFrom: url)
            do { try readDirectory() } catch { try? input.close(); throw error }
        }

        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size - offset else {
                throw GamePackageError.invalid("NXB entry bounds")
            }
            try input.seek(toOffset: offset)
            guard let data = try input.read(upToCount: count), data.count == count else {
                throw GamePackageError.invalid("NXB truncated file")
            }
            return data
        }

        mutating func readDirectory() throws {
            let tailSize = Int(min(size, 65_557))
            let tail = try read(size - UInt64(tailSize), tailSize)
            var eocd: Int?
            for index in stride(from: tail.count - 22, through: 0, by: -1) {
                if u32(tail, index) == 0x06054b50,
                   index + 22 + Int(u16(tail, index + 20)) == tail.count { eocd = index; break }
            }
            guard let eocd, u16(tail, eocd + 4) == 0, u16(tail, eocd + 6) == 0,
                  u16(tail, eocd + 8) == u16(tail, eocd + 10) else {
                throw GamePackageError.invalid("NXB ZIP end record")
            }
            var count = UInt64(u16(tail, eocd + 10))
            var length = UInt64(u32(tail, eocd + 12))
            var offset = UInt64(u32(tail, eocd + 16))
            var directoryEnd = size - UInt64(tailSize) + UInt64(eocd)
            if count == 0xffff || length == 0xffffffff || offset == 0xffffffff {
                guard directoryEnd >= 20 else { throw GamePackageError.invalid("NXB ZIP64 locator") }
                let locator = try read(directoryEnd - 20, 20)
                guard u32(locator, 0) == 0x07064b50, u32(locator, 4) == 0, u32(locator, 16) == 1 else {
                    throw GamePackageError.invalid("NXB ZIP64 disks")
                }
                let zip64Offset = u64(locator, 8)
                let record = try read(zip64Offset, 56)
                let recordLength = u64(record, 4)
                guard u32(record, 0) == 0x06064b50, recordLength >= 44, recordLength <= 1 << 20,
                      zip64Offset <= directoryEnd - 20,
                      recordLength + 12 == directoryEnd - 20 - zip64Offset,
                      u32(record, 16) == 0, u32(record, 20) == 0,
                      u64(record, 24) == u64(record, 32) else {
                    throw GamePackageError.invalid("NXB ZIP64 end record")
                }
                count = u64(record, 32); length = u64(record, 40); offset = u64(record, 48)
                directoryEnd = zip64Offset
            }
            guard count > 0, count <= 65_535, length <= directoryLimit,
                  offset <= directoryEnd, length == directoryEnd - offset else {
                throw GamePackageError.invalid("NXB central directory bounds")
            }
            let central = try read(offset, Int(length))
            var cursor = 0
            var folded = Set<String>()
            var intervals: [(UInt64, UInt64)] = []
            for _ in 0..<count {
                try Task.checkCancellation()
                guard cursor <= central.count - 46, u32(central, cursor) == 0x02014b50 else {
                    throw GamePackageError.invalid("NXB central record")
                }
                let flags = u16(central, cursor + 8)
                let method = u16(central, cursor + 10)
                let crc = u32(central, cursor + 16)
                let nameLength = Int(u16(central, cursor + 28))
                let extraLength = Int(u16(central, cursor + 30))
                let commentLength = Int(u16(central, cursor + 32))
                let recordLength = 46 + nameLength + extraLength + commentLength
                let mode = u32(central, cursor + 38) >> 16
                guard flags & ~UInt16(0x0808) == 0, method == 0, u16(central, cursor + 34) == 0,
                      mode & 0xf000 == 0 || mode & 0xf000 == 0x8000,
                      recordLength <= central.count - cursor, nameLength > 0,
                      let name = String(data: central[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8),
                      GamePackageManifest.safePath(name), name == name.precomposedStringWithCanonicalMapping,
                      folded.insert(name.lowercased()).inserted else {
                    throw GamePackageError.invalid("NXB unsupported ZIP entry")
                }
                var compressed = UInt64(u32(central, cursor + 20))
                var bytes = UInt64(u32(central, cursor + 24))
                var local = UInt64(u32(central, cursor + 42))
                let extra = Data(central[(cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extraLength)])
                try sizes(extra, bytes: &bytes, compressed: &compressed, offset: &local)
                guard bytes == compressed, bytes <= maximumBytes, local < offset else {
                    throw GamePackageError.invalid("NXB stored entry dimensions")
                }
                let header = try read(local, 30)
                let localNameLength = Int(u16(header, 26))
                let localExtraLength = Int(u16(header, 28))
                guard u32(header, 0) == 0x04034b50, u16(header, 6) == flags, u16(header, 8) == method,
                      localNameLength == nameLength else { throw GamePackageError.invalid("NXB local header") }
                let localMetadata = try read(local + 30, localNameLength + localExtraLength)
                guard Data(localMetadata.prefix(localNameLength)) == Data(name.utf8) else {
                    throw GamePackageError.invalid("NXB local filename mismatch")
                }
                var localBytes = UInt64(u32(header, 22))
                var localCompressed = UInt64(u32(header, 18))
                var unused: UInt64 = 0
                let localExtra = Data(localMetadata.dropFirst(localNameLength))
                try sizes(localExtra, bytes: &localBytes, compressed: &localCompressed, offset: &unused)
                if flags & 8 == 0 {
                    guard localBytes == bytes, localCompressed == bytes, u32(header, 14) == crc else {
                        throw GamePackageError.invalid("NXB local size or CRC mismatch")
                    }
                } else {
                    guard (localBytes == 0 || localBytes == bytes),
                          (localCompressed == 0 || localCompressed == bytes),
                          (u32(header, 14) == 0 || u32(header, 14) == crc) else {
                        throw GamePackageError.invalid("NXB descriptor header mismatch")
                    }
                }
                let start = local + 30 + UInt64(localMetadata.count)
                guard start <= offset, bytes <= offset - start else { throw GamePackageError.invalid("NXB data bounds") }
                var end = start + bytes
                if flags & 8 != 0 {
                    // ZIP64 local sentinels choose 64-bit data descriptors, even
                    // when a stream happened to finish below the 4 GiB boundary.
                    let wide = u32(header, 18) == 0xffffffff || u32(header, 22) == 0xffffffff || bytes >= 0xffffffff
                    let first = try read(end, 4)
                    let layouts = u32(first, 0) == 0x08074b50 ? [4, 0] : [0]
                    var matchedLength: Int?
                    for p in layouts {
                        let descriptorSize = (wide ? 20 : 12) + p
                        guard UInt64(descriptorSize) <= offset - end else { continue }
                        let descriptor = try read(end, descriptorSize)
                        let stored = wide ? u64(descriptor, p + 4) : UInt64(u32(descriptor, p + 4))
                        let unpacked = wide ? u64(descriptor, p + 12) : UInt64(u32(descriptor, p + 8))
                        if u32(descriptor, p) == crc, stored == bytes, unpacked == bytes {
                            matchedLength = descriptorSize
                            break
                        }
                    }
                    guard let matchedLength else { throw GamePackageError.invalid("NXB descriptor mismatch") }
                    end += UInt64(matchedLength)
                }
                entries[name] = Entry(path: name, bytes: bytes, crc: crc, start: start, end: end)
                intervals.append((local, end))
                cursor += recordLength
            }
            guard cursor == central.count else { throw GamePackageError.invalid("NXB extra central records") }
            intervals.sort { $0.0 < $1.0 }
            var previous: UInt64 = 0
            for interval in intervals {
                guard interval.0 == previous else { throw GamePackageError.invalid("NXB overlapping or hidden ZIP data") }
                previous = interval.1
            }
            guard previous == offset else { throw GamePackageError.invalid("NXB trailing hidden ZIP data") }
        }
    }

    static func sizes(_ extra: Data, bytes: inout UInt64, compressed: inout UInt64, offset: inout UInt64) throws {
        let needed = bytes == 0xffffffff || compressed == 0xffffffff || offset == 0xffffffff
        var cursor = 0
        var found = false
        while cursor < extra.count {
            guard extra.count - cursor >= 4 else { throw GamePackageError.invalid("NXB ZIP extra field") }
            let kind = u16(extra, cursor), length = Int(u16(extra, cursor + 2))
            cursor += 4
            guard length <= extra.count - cursor else { throw GamePackageError.invalid("NXB ZIP extra length") }
            if kind == 1 {
                guard !found else { throw GamePackageError.invalid("NXB duplicate ZIP64 field") }
                found = true
                var p = cursor
                func next() throws -> UInt64 {
                    guard p <= cursor + length - 8 else { throw GamePackageError.invalid("NXB ZIP64 dimensions") }
                    defer { p += 8 }
                    return u64(extra, p)
                }
                if bytes == 0xffffffff { bytes = try next() }
                if compressed == 0xffffffff { compressed = try next() }
                if offset == 0xffffffff { offset = try next() }
            }
            cursor += length
        }
        guard !needed || found else { throw GamePackageError.invalid("NXB missing ZIP64 dimensions") }
    }

    static func u16(_ data: Data, _ p: Int) -> UInt16 { UInt16(data[p]) | UInt16(data[p + 1]) << 8 }
    static func u32(_ data: Data, _ p: Int) -> UInt32 { UInt32(u16(data, p)) | UInt32(u16(data, p + 2)) << 16 }
    static func u64(_ data: Data, _ p: Int) -> UInt64 { UInt64(u32(data, p)) | UInt64(u32(data, p + 4)) << 32 }
    static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : 0xedb88320 ^ (crc >> 1) }
        return crc
    }
    static func updateCRC(_ crc: UInt32, _ data: Data) -> UInt32 {
        var value = crc
        for byte in data { value = crcTable[Int((value ^ UInt32(byte)) & 255)] ^ (value >> 8) }
        return value
    }
    static func checksum(_ data: Data) -> UInt32 { updateCRC(0xffffffff, data) ^ 0xffffffff }
}

extension NXBArchive {
    /// Rebuilds STORE entries with ZIP64 dimensions. Only one data chunk and the
    /// bounded central directory are retained, including for multi-GB games.
    static func write(_ destination: URL, reader: Reader, files: [GamePackageManifest.File],
                      manifest: Data, proof: Data) throws {
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try write(entries: reader.entries, files: files, manifest: manifest, proof: proof,
                  read: { path, offset, count in
                      try reader.read(reader.entries[path]!.start + offset, count)
                  }, emit: { try output.write(contentsOf: $0) })
        try output.synchronize()
    }

    /// The sink may be a file or a backpressured transport. It never owns an
    /// archive-sized buffer. Offsets supplied to read are relative to each file.
    static func write(entries: [String: Entry], files: [GamePackageManifest.File],
                      manifest: Data, proof: Data?,
                      read: (String, UInt64, Int) throws -> Data,
                      emit sink: (Data) throws -> Void) throws {
        var position: UInt64 = 0
        var central = Data()
        func words(_ values: [(UInt64, Int)]) -> Data {
            Data(values.flatMap { value, count in (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } })
        }
        func emit(_ data: Data) throws {
            try sink(data)
            position += UInt64(data.count)
        }
        func entry(_ path: String, bytes: UInt64, crc: UInt32, executable: Bool,
                   contents: () throws -> Void) throws {
            let name = Data(path.utf8), offset = position
            let extra = words([(1, 2), (16, 2), (bytes, 8), (bytes, 8)])
            try emit(words([(0x04034b50, 4), (45, 2), (0x800, 2), (0, 2), (0, 2), (0, 2),
                            (UInt64(crc), 4), (0xffffffff, 4), (0xffffffff, 4),
                            (UInt64(name.count), 2), (UInt64(extra.count), 2)]))
            try emit(name); try emit(extra)
            try contents()
            let centralExtra = words([(1, 2), (24, 2), (bytes, 8), (bytes, 8), (offset, 8)])
            central.append(words([(0x02014b50, 4), (0x32d, 2), (45, 2), (0x800, 2), (0, 2),
                                  (0, 2), (0, 2), (UInt64(crc), 4), (0xffffffff, 4), (0xffffffff, 4),
                                  (UInt64(name.count), 2), (UInt64(centralExtra.count), 2),
                                  (0, 2), (0, 2), (0, 2), (executable ? 0x81ed0000 : 0x81a40000, 4),
                                  (0xffffffff, 4)]))
            central.append(name); central.append(centralExtra)
            guard central.count <= directoryLimit else { throw GamePackageError.invalid("NXB directory size") }
        }
        var metadata = [("nxb.json", manifest)]
        if let proof { metadata.append(("nxb.signature.json", proof)) }
        for (name, data) in metadata {
            try entry(name, bytes: UInt64(data.count), crc: checksum(data), executable: false) { try emit(data) }
        }
        for file in files {
            let source = entries[file.path]!
            try entry(file.path, bytes: source.bytes, crc: source.crc, executable: file.executable) {
                var cursor: UInt64 = 0
                var remaining = source.bytes
                var hash = SHA256(), crc: UInt32 = 0xffffffff
                while remaining > 0 {
                    try Task.checkCancellation()
                    let data = try read(file.path, cursor, Int(min(remaining, UInt64(chunk))))
                    guard !data.isEmpty, UInt64(data.count) <= remaining else {
                        throw GamePackageError.invalid("file length changed")
                    }
                    hash.update(data: data); crc = updateCRC(crc, data)
                    try emit(data)
                    remaining -= UInt64(data.count); cursor += UInt64(data.count)
                }
                guard crc ^ 0xffffffff == source.crc,
                      hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                    throw GamePackageError.invalid("file checksum mismatch")
                }
            }
        }
        let directoryOffset = position
        try emit(central)
        let endOffset = position, count = UInt64(files.count + metadata.count)
        try emit(words([(0x06064b50, 4), (44, 8), (45, 2), (45, 2), (0, 4), (0, 4),
                        (count, 8), (count, 8), (UInt64(central.count), 8), (directoryOffset, 8)]))
        try emit(words([(0x07064b50, 4), (0, 4), (endOffset, 8), (1, 4)]))
        try emit(words([(0x06054b50, 4), (0, 2), (0, 2), (0xffff, 2), (0xffff, 2),
                        (0xffffffff, 4), (0xffffffff, 4), (0, 2)]))
    }
}
