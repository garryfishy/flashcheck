import Testing
import Darwin
@testable import FlashCheckCore

private let stagePattern = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))
private let stageGiB: UInt64 = 1024 * 1024 * 1024

private func makeStageRunner(_ device: BlockDevice) -> RoundRunner {
    RoundRunner(device: device, pattern: stagePattern, layout: Layout(evictBytes: 1 * 1024 * 1024), isCancelled: { false })
}

private final class IsolatedFailureDevice: BlockDevice {
    let reportedSize: UInt64
    let blockSize = 512
    private let inner: BlockDevice
    private let failingOffsets: Set<UInt64>
    private let failOnlyFirstReadAt: UInt64?
    private var targetHasBeenWritten = false
    private var failedPostWriteRead = false

    init(size: UInt64, failingOffsets: Set<UInt64> = [], failOnlyFirstReadAt: UInt64? = nil) {
        reportedSize = size
        inner = GenuineDevice(size: size)
        self.failingOffsets = failingOffsets
        self.failOnlyFirstReadAt = failOnlyFirstReadAt
    }

    func read(at offset: UInt64, into buffer: UnsafeMutableRawBufferPointer) throws(IOError) {
        if failingOffsets.contains(offset) { throw .readFailed(errno: EIO) }
        if offset == failOnlyFirstReadAt && targetHasBeenWritten && !failedPostWriteRead {
            failedPostWriteRead = true
            throw .readFailed(errno: EIO)
        }
        try inner.read(at: offset, into: buffer)
    }

    func write(at offset: UInt64, from buffer: UnsafeRawBufferPointer) throws(IOError) {
        if offset == failOnlyFirstReadAt { targetHasBeenWritten = true }
        try inner.write(at: offset, from: buffer)
    }

    func synchronize() throws(IOError) { try inner.synchronize() }
}

@Test func genuinePassesStageA() throws {
    let result = try StageA.run(makeStageRunner(GenuineDevice(size: 64 * stageGiB)), reportedSize: 64 * stageGiB, seed: 7)
    #expect(result.allMatched)
    #expect(result.records.allSatisfy { $0.kind == .probe })
}

@Test func discardBoundsFromStageA() throws {
    let device = FakeDevice(reported: 8 * stageGiB, usable: 3_900_000_000)
    let result = try StageA.run(makeStageRunner(device), reportedSize: device.reportedSize, seed: 7)
    #expect(result.highestGood != nil)
    #expect(result.lowestBad != nil)
    #expect(result.highestGood! < 3_900_000_000)
    #expect(result.highestGood! <= 3_900_000_000)
    #expect(3_900_000_000 <= result.lowestBad!)
}

@Test func isolatedFlakeIsTransientOrIntermittent() throws {
    let device = FlakyDevice(GenuineDevice(size: 64 * stageGiB), readFailureRate: 0.02, seed: 1)
    let result = try StageA.run(makeStageRunner(device), reportedSize: device.reportedSize, seed: 7)
    #expect(!result.retests.isEmpty)
    #expect(!result.retests.values.contains(.persistent))
}

@Test func foreignDistancesReflectModuloAliases() throws {
    let modulus = 4 * stageGiB
    let device = FakeDevice(reported: 16 * stageGiB, usable: 4 * stageGiB, modulus: modulus)
    let result = try StageA.run(makeStageRunner(device), reportedSize: device.reportedSize, seed: 7)
    #expect(!result.foreignDistances.isEmpty)
    #expect(result.foreignDistances.allSatisfy { $0 % modulus == 0 })
}

@Test func isolatedPersistentFailureIsRetested() throws {
    let size = 8 * stageGiB
    let offsets = ProbePlanner.stageAOffsets(reportedSize: size, seed: 7)
    let target = offsets[offsets.count / 2]
    let device = IsolatedFailureDevice(size: size, failingOffsets: [target])
    let result = try StageA.run(makeStageRunner(device), reportedSize: size, seed: 7)
    #expect(result.retests[target] == .persistent)
}

@Test func adjacentFailuresAreNotRetested() throws {
    let size = 8 * stageGiB
    let offsets = ProbePlanner.stageAOffsets(reportedSize: size, seed: 7)
    let middle = offsets.count / 2
    let targets: Set<UInt64> = [offsets[middle], offsets[middle + 1]]
    let device = IsolatedFailureDevice(size: size, failingOffsets: targets)
    let result = try StageA.run(makeStageRunner(device), reportedSize: size, seed: 7)
    #expect(result.retests[offsets[middle]] == nil)
    #expect(result.retests[offsets[middle + 1]] == nil)
}

@Test func transientRetestBoundsAreGood() throws {
    let size = 8 * stageGiB
    let offsets = ProbePlanner.stageAOffsets(reportedSize: size, seed: 7)
    let target = offsets[offsets.count / 2]
    let device = IsolatedFailureDevice(size: size, failOnlyFirstReadAt: target)
    let result = try StageA.run(makeStageRunner(device), reportedSize: size, seed: 7)
    #expect(result.retests[target] == .transient)
    #expect(result.highestGood! >= target)
    #expect(result.lowestBad == nil || result.lowestBad! > target)
}

@Test func preReadOfFreshDeviceIsBlank() throws {
    let size = 4 * stageGiB
    let result = try StageA.run(makeStageRunner(GenuineDevice(size: size)), reportedSize: size, seed: 7)
    #expect(!result.preReads.values.contains { if case .foreign = $0.verification { true } else { false } })
    #expect(result.preReads.values.allSatisfy { if case .blank = $0.verification { true } else { false } })
}
