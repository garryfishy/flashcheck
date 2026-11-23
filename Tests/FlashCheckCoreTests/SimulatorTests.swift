import Darwin
import Testing
@testable import FlashCheckCore

private let unit = 65_536
private let gib: UInt64 = 1_073_741_824

private func write(_ device: BlockDevice, at offset: UInt64, _ bytes: [UInt8]) throws(IOError) {
    do { try bytes.withUnsafeBytes { try device.write(at: offset, from: $0) } }
    catch let error as IOError { throw error }
    catch { throw .writeFailed(errno: EIO) }
}

private func read(_ device: BlockDevice, at offset: UInt64, count: Int) throws(IOError) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    do { try bytes.withUnsafeMutableBytes { try device.read(at: offset, into: $0) } }
    catch let error as IOError { throw error }
    catch { throw .readFailed(errno: EIO) }
    return bytes
}

@Test func wrapAliases() throws {
    let device = FakeDevice(reported: 512 * gib, usable: 4 * gib, modulus: 4 * gib)
    let payload = [UInt8](repeating: 0xA1, count: unit)
    try write(device, at: 4 * gib + 1 * 1024 * 1024, payload)
    #expect(try read(device, at: 1 * 1024 * 1024, count: unit) == payload)
}

@Test func discardReturnsFill() throws {
    let device = FakeDevice(reported: 512 * gib, usable: 3_900_000_000)
    try write(device, at: 5 * gib, [UInt8](repeating: 0xA2, count: unit))
    #expect(try read(device, at: 5 * gib, count: unit) == [UInt8](repeating: 0, count: unit))
}

@Test func rejectThrows() {
    let device = FakeDevice(reported: 512 * gib, usable: 3_900_000_000, beyond: .reject)
    do {
        try write(device, at: 5 * gib, [UInt8](repeating: 1, count: unit))
        Issue.record("expected rejection")
    } catch let error {
        #expect(error == .writeFailed(errno: EIO))
    }
}

@Test func limboEchoesLastWrite() throws {
    let device = FakeDevice(reported: 512 * gib, usable: 3_900_000_000, beyond: .limbo)
    let a = [UInt8](repeating: 0xA3, count: unit)
    let b = [UInt8](repeating: 0xB4, count: unit)
    try write(device, at: 5 * gib, a)
    #expect(try read(device, at: 5 * gib, count: unit) == a)
    try write(device, at: 6 * gib, b)
    #expect(try read(device, at: 5 * gib, count: unit) == b)
}

@Test func cacheHidesDiscard() throws {
    let device = CachedDevice(FakeDevice(reported: 512 * gib, usable: 3_900_000_000), cacheBytes: 8 * 1024 * 1024)
    let payload = [UInt8](repeating: 0xC5, count: unit)
    try write(device, at: 5 * gib, payload)
    #expect(try read(device, at: 5 * gib, count: unit) == payload)
}

@Test func cacheEvictsLRU() throws {
    let device = CachedDevice(FakeDevice(reported: 512 * gib, usable: 3_900_000_000), cacheBytes: 8 * 1024 * 1024)
    let payload = [UInt8](repeating: 0xC5, count: unit)
    try write(device, at: 5 * gib, payload)
    let filler = [UInt8](repeating: 0xD6, count: 16 * 1024 * 1024)
    try write(device, at: 100 * 1024 * 1024, filler)
    #expect(try read(device, at: 5 * gib, count: unit) == [UInt8](repeating: 0, count: unit))
}

@Test func cachedDirtyEvictionPersistsToGenuineDevice() throws {
    let inner = GenuineDevice(size: 32 * 1024 * 1024)
    let device = CachedDevice(inner, cacheBytes: UInt64(unit))
    let payload = [UInt8](repeating: 0x71, count: unit)
    try write(device, at: 0, payload)
    try write(device, at: UInt64(unit), [UInt8](repeating: 0x82, count: unit))
    #expect(try read(device, at: 0, count: unit) == payload)
}

@Test func fullWriteReplacesPreviouslyCachedDirtyEntry() throws {
    let inner = GenuineDevice(size: 1024 * 1024)
    let device = CachedDevice(inner, cacheBytes: UInt64(unit))
    let a = [UInt8](repeating: 0xA1, count: unit)
    let b = [UInt8](repeating: 0xB2, count: unit)
    try write(device, at: 0, a)
    try write(device, at: 0, b)
    #expect(try read(device, at: 0, count: unit) == b)
    try device.synchronize()
    #expect(try read(inner, at: 0, count: unit) == b)
}

@Test func fullWriteReplacesPreviouslyCachedCleanEntry() throws {
    let inner = GenuineDevice(size: 1024 * 1024)
    let device = CachedDevice(inner, cacheBytes: UInt64(unit))
    let a = [UInt8](repeating: 0xA3, count: unit)
    let b = [UInt8](repeating: 0xB4, count: unit)
    try write(inner, at: 0, a)
    #expect(try read(device, at: 0, count: unit) == a)
    try write(device, at: 0, b)
    #expect(try read(device, at: 0, count: unit) == b)
    try device.synchronize()
    #expect(try read(inner, at: 0, count: unit) == b)
}

@Test func cleanCacheEntriesDoNotWriteOnSynchronize() throws {
    let inner = FakeDevice(reported: 8 * 1024 * 1024, usable: 8 * 1024 * 1024)
    let device = CachedDevice(inner, cacheBytes: UInt64(unit * 2))
    try write(inner, at: 0, [UInt8](repeating: 0x31, count: unit))
    let before = inner.writeCount
    _ = try read(device, at: 0, count: unit)
    try device.synchronize()
    #expect(inner.writeCount == before)
}

@Test func zeroCapacityWritesThrough() throws {
    let inner = GenuineDevice(size: 1024 * 1024)
    let device = CachedDevice(inner, cacheBytes: 0)
    let payload = [UInt8](repeating: 0x93, count: unit)
    try write(device, at: 0, payload)
    #expect(try read(inner, at: 0, count: unit) == payload)
}

@Test func fullEntryWriteToRejectInnerSurfacesWriteFailure() {
    let inner = FakeDevice(reported: 512 * gib, usable: 3_900_000_000, beyond: .reject)
    let device = CachedDevice(inner, cacheBytes: UInt64(unit))
    do {
        try write(device, at: 5 * gib, [UInt8](repeating: 0xA7, count: unit))
        try device.synchronize()
        Issue.record("expected rejected write while flushing full cached entry")
    } catch let error { #expect(error == .writeFailed(errno: EIO)) }
}

@Test func vanishStopsIO() throws {
    let device = VanishingDevice(GenuineDevice(size: 16 * 1024 * 1024), afterOperations: 2)
    try write(device, at: 0, [UInt8](repeating: 1, count: unit))
    _ = try read(device, at: 0, count: unit)
    for attempt in 1...3 {
        do {
            _ = try read(device, at: 0, count: unit)
            Issue.record("expected vanished device")
        } catch let error { #expect(error == .deviceGone) }
        #expect(device.operationsAfterVanish == attempt)
    }
}

@Test func sparseStoreDefaultsToZero() {
    let store = SparseStore()
    store.write(512, [1, 2, 3])
    #expect(store.read(510, 6) == [0, 0, 1, 2, 3, 0])
}
