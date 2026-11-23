import Testing
import Foundation
@testable import FlashCheckCore

@Test func engineCancellationIsError() {
    let device = FakeDevice(reported: 2 * 1024 * 1024 * 1024, usable: 2 * 1024 * 1024 * 1024)
    let events = EventCounter()
    let engine = Engine(device: device, summary: DeviceSummary(name: "test", identifier: "id", reportedSize: device.reportedSize, blockSize: 512, connection: "sim"), session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)), config: EngineConfig(mode: .scan, evictBytes: 1 * 1024 * 1024, seed: 0), onEvent: { event in if case .probe = event { events.increment() } }, isCancelled: { events.value >= 10 })
    let report = engine.run()
    let writeCount = device.writeCount
    #expect(events.value == 10)
    #expect(report.verdict == .testError)
    #expect(report.errors.contains("cancelled"))
    #expect(writeCount == 0)
    #expect(device.writeCount == writeCount)
}

@Test func vanishMidRunIsTestError() {
    let underlying = GenuineDevice(size: 2 * 1024 * 1024 * 1024)
    let device = VanishingDevice(underlying, afterOperations: 50)
    let report = makeEngine(device, mode: .scan).run()
    #expect(report.verdict == .testError)
    #expect(device.operationsAfterVanish == 1)
}

@Test func shortIOIsNeverSuccess() {
    let device = ShortIODevice(GenuineDevice(size: 2 * 1024 * 1024 * 1024), failEvery: 9)
    #expect(makeEngine(device, mode: .scan).run().verdict != .sampledPassed)
}

@Test func tooSmallForScan() {
    let report = makeEngine(GenuineDevice(size: 512 * 1024 * 1024), mode: .scan).run()
    #expect(report.verdict == .testError)
    #expect(report.capacity.note == "device too small for sampled modes; use full")
}

@Test func staleSessionDataNeverMatches() throws {
    let size: UInt64 = 2 * 1024 * 1024 * 1024
    let device = GenuineDevice(size: size)
    let oldPattern = PatternGenerator(session: SessionKey(id: Array(16..<32), keyBytes: Array(32..<64)))
    for offset in ProbePlanner.stageAOffsets(reportedSize: size, seed: 3) {
        var bytes = [UInt8](repeating: 0, count: PatternGenerator.unitSize)
        bytes.withUnsafeMutableBytes { oldPattern.fill($0, offset: offset, kind: .probe, generation: 0) }
        try device.write(at: offset, from: bytes.withUnsafeBytes { $0 })
    }
    let engine = makeEngine(device, mode: .scan)
    let report = engine.run()
    #expect(report.verdict == .sampledPassed)
    #expect(report.stageA?.preReads.values.contains { $0.verification == .otherSession } == true)
    #expect(report.stageA?.records.allSatisfy { $0.reads.allSatisfy { $0.verification == .match } } == true)
}

private func makeEngine(_ device: BlockDevice, mode: Mode) -> Engine {
    Engine(device: device, summary: DeviceSummary(name: "sim", identifier: "sim", reportedSize: device.reportedSize, blockSize: device.blockSize, connection: "sim"), session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)), config: EngineConfig(mode: mode, evictBytes: 1 * 1024 * 1024, seed: 3), onEvent: { _ in }, isCancelled: { false })
}

private final class EventCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
