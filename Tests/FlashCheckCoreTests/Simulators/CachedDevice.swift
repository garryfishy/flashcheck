import Foundation
@testable import FlashCheckCore

final class CachedDevice: BlockDevice {
    private struct Entry { var bytes: [UInt8]; var stamp: UInt64; var dirty: Bool }
    private let inner: BlockDevice
    private let capacity: UInt64
    private var entries: [UInt64: Entry] = [:]
    private var clock: UInt64 = 0
    private let entrySize = 65_536
    var reportedSize: UInt64 { inner.reportedSize }
    var blockSize: Int { inner.blockSize }

    init(_ inner: BlockDevice, cacheBytes: UInt64) { self.inner = inner; self.capacity = cacheBytes / 65_536 }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        var cursor = 0
        while cursor < buffer.count {
            let address = offset + UInt64(cursor), base = address / UInt64(entrySize) * UInt64(entrySize)
            let within = Int(address - base), count = min(entrySize - within, buffer.count - cursor)
            let data = try load(base)
            for i in 0..<count { buffer[cursor + i] = data[within + i] }
            cursor += count
        }
    }

    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        if capacity == 0 {
            try inner.write(at: offset, from: buffer)
            return
        }
        var cursor = 0
        while cursor < buffer.count {
            let address = offset + UInt64(cursor), base = address / UInt64(entrySize) * UInt64(entrySize)
            let within = Int(address - base), count = min(entrySize - within, buffer.count - cursor)
            var data: [UInt8]
            if within == 0 && count == entrySize {
                data = (0..<entrySize).map { buffer[cursor + $0] }
                entries[base] = Entry(bytes: data, stamp: 0, dirty: true)
            } else {
                data = try load(base)
                for i in 0..<count { data[within + i] = buffer[cursor + i] }
                entries[base] = Entry(bytes: data, stamp: 0, dirty: true)
            }
            touch(base)
            try evictIfNeeded()
            cursor += count
        }
    }

    private func load(_ base: UInt64) throws(IOError) -> [UInt8] {
        if entries[base] != nil { touch(base); return entries[base]!.bytes }
        var bytes = [UInt8](repeating: 0, count: entrySize)
        do { try bytes.withUnsafeMutableBytes { try inner.read(at: base, into: $0) } }
        catch let error as IOError { throw error }
        catch { throw .readFailed(errno: 5) }
        if capacity > 0 {
            // Evict before inserting so a failed flush leaves the existing cache intact.
            if UInt64(entries.count) >= capacity, entries[base] == nil {
                try evictIfNeeded(keepingRoomFor: 1)
            }
            entries[base] = Entry(bytes: bytes, stamp: 0, dirty: false); touch(base)
        }
        return bytes
    }

    private func touch(_ base: UInt64) {
        clock &+= 1
        if entries[base] != nil { entries[base]!.stamp = clock }
    }
    private func evictIfNeeded(keepingRoomFor extra: UInt64 = 0) throws(IOError) {
        while UInt64(entries.count) + extra > capacity, let victim = entries.min(by: { $0.value.stamp < $1.value.stamp })?.key {
            try flush(victim); entries.removeValue(forKey: victim)
        }
    }
    private func flush(_ base: UInt64) throws(IOError) {
        guard var entry = entries[base], entry.dirty else { return }
        do { try entry.bytes.withUnsafeBytes { try inner.write(at: base, from: $0) } }
        catch let error as IOError { throw error }
        catch { throw .writeFailed(errno: 5) }
        entry.dirty = false
        entries[base] = entry
    }
    func synchronize() throws(IOError) {
        for base in entries.keys.sorted() { try flush(base) }
        try inner.synchronize()
    }
}
