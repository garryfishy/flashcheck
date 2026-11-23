import Darwin
import Testing
@testable import FlashCheckCore

private let testPattern = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
private let gib: UInt64 = 1024 * 1024 * 1024

private final class OperationSpy: BlockDevice {
    let inner: BlockDevice
    var events: [String] = []
    var reportedSize: UInt64 { inner.reportedSize }
    var blockSize: Int { inner.blockSize }
    init(_ inner: BlockDevice) { self.inner = inner }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        events.append("read")
        try inner.read(at: offset, into: buffer)
    }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        events.append(offset >= 9 * 1024 * 1024 ? "filler" : "write")
        try inner.write(at: offset, from: buffer)
    }
    func synchronize() throws(IOError) { events.append("sync"); try inner.synchronize() }
}

private final class FailingEvictionDevice: BlockDevice {
    let reportedSize: UInt64
    let blockSize = 512
    private let inner: BlockDevice
    private let failSync: Bool
    init(_ inner: BlockDevice, failSync: Bool = false) { self.inner = inner; self.reportedSize = inner.reportedSize; self.failSync = failSync }
    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) { try inner.read(at: offset, into: buffer) }
    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        if offset >= 9 * 1024 * 1024 && offset < 10 * 1024 * 1024 { throw .writeFailed(errno: EIO) }
        try inner.write(at: offset, from: buffer)
    }
    func synchronize() throws(IOError) { if failSync { throw .writeFailed(errno: EIO) }; try inner.synchronize() }
}

@Test func roundDetectsDiscardBehindCache() throws {
    let fake = FakeDevice(reported: 8 * gib, usable: 3 * gib + 900 * 1024 * 1024)
    let device = CachedDevice(fake, cacheBytes: 8 * 1024 * 1024)
    let runner = RoundRunner(device: device, pattern: testPattern, layout: Layout(evictBytes: 64 * 1024 * 1024), isCancelled: { false })
    let records = try runner.round(writes: [(5 * gib, .probe)], reads: [5 * gib], decoysAbove: nil)
    #expect(records.first?.reads.first?.verification == .blank(0))
}

@Test func roundSeesFillerAliasing() throws {
    let fake = FakeDevice(reported: 4 * gib, usable: gib, modulus: gib)
    let runner = RoundRunner(device: fake, pattern: testPattern, layout: Layout(evictBytes: 64 * 1024 * 1024), isCancelled: { false })
    let offset = gib + 10 * 1024 * 1024
    let records = try runner.round(writes: [(offset, .probe)], reads: [offset], decoysAbove: nil)
    #expect(records.first?.reads.first?.verification == .foreign(offset: 10 * 1024 * 1024, kind: .filler, generation: 0))
}

@Test func limboDefeatedByDecoys() throws {
    let fake = FakeDevice(reported: 8 * gib, usable: 3 * gib + 900 * 1024 * 1024, beyond: .limbo)
    let runner = RoundRunner(device: fake, pattern: testPattern, layout: Layout(evictBytes: 64 * 1024 * 1024), isCancelled: { false })
    let records = try runner.round(writes: [(5 * gib, .probe)], reads: [5 * gib], decoysAbove: nil)
    #expect(records.first?.reads.first?.verification != .match)
}

@Test func writeErrorRecordedNotThrown() throws {
    let fake = FakeDevice(reported: 8 * gib, usable: 3 * gib, beyond: .reject)
    let runner = RoundRunner(device: fake, pattern: testPattern, layout: Layout(evictBytes: 64 * 1024 * 1024), isCancelled: { false })
    let records = try runner.round(writes: [(5 * gib, .probe)], reads: [5 * gib], decoysAbove: nil)
    #expect(records.first?.writeError == .writeFailed(errno: EIO))
}

@Test func rereadEvictsFirst() throws {
    let spy = OperationSpy(FakeDevice(reported: 2 * gib, usable: 2 * gib))
    let runner = RoundRunner(device: spy, pattern: testPattern, layout: Layout(evictBytes: 64 * 1024 * 1024), isCancelled: { false })
    _ = try runner.round(writes: [(gib, .probe)], reads: [gib], decoysAbove: nil)
    spy.events.removeAll()
    _ = try runner.reread([gib])
    let firstRead = try #require(spy.events.firstIndex(of: "read"))
    #expect(spy.events[..<firstRead].contains("filler"))
}

@Test func fillerFailureRecordedAndEvictionIncomplete() throws {
    let device = FailingEvictionDevice(FakeDevice(reported: 2 * gib, usable: 2 * gib))
    let runner = RoundRunner(device: device, pattern: testPattern, layout: Layout(evictBytes: 1 * 1024 * 1024), isCancelled: { false })
    let records = try runner.round(writes: [(gib, .probe)], reads: [gib], decoysAbove: nil)
    #expect(records.contains { $0.kind == .filler && $0.writeError == .writeFailed(errno: EIO) })
    #expect(runner.lastEvictionIncomplete)
}

@Test func lastUnitProbeGetsFallbackDecoys() throws {
    let fake = FakeDevice(reported: 8 * gib, usable: 3 * gib + 900 * 1024 * 1024, beyond: .limbo)
    let runner = RoundRunner(device: fake, pattern: testPattern, layout: Layout(evictBytes: 1 * 1024 * 1024), isCancelled: { false })
    let offset = fake.reportedSize / Layout.unit * Layout.unit - Layout.unit
    let records = try runner.round(writes: [(offset, .probe)], reads: [offset], decoysAbove: nil)
    #expect(records.first?.reads.first?.verification != .match)
    #expect(!runner.lastRoundHadNoDecoys)
}

@Test func syncFailureExposedForRoundAndReread() throws {
    let device = FailingEvictionDevice(FakeDevice(reported: 2 * gib, usable: 2 * gib), failSync: true)
    let runner = RoundRunner(device: device, pattern: testPattern, layout: Layout(evictBytes: 1 * 1024 * 1024), isCancelled: { false })
    let records = try runner.round(writes: [(gib, .probe)], reads: [gib], decoysAbove: nil)
    #expect(runner.lastSyncError == .writeFailed(errno: EIO))
    #expect(records.contains { $0.syncError == .writeFailed(errno: EIO) })
    _ = try runner.reread([gib])
    #expect(runner.lastSyncError == .writeFailed(errno: EIO))
}
