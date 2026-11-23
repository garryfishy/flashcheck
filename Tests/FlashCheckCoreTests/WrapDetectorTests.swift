import Testing
@testable import FlashCheckCore

private let wrapGiB: UInt64 = 1024 * 1024 * 1024
private let wrapMiB: UInt64 = 1024 * 1024
private let wrapPattern = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))

private func wrapRunner(_ device: BlockDevice, evictMiB: UInt64 = 1) -> RoundRunner {
    RoundRunner(device: device, pattern: wrapPattern, layout: Layout(evictBytes: evictMiB * wrapMiB), isCancelled: { false })
}

@Test func confirms4GiBWrap() throws {
    let device = FakeDevice(reported: 512 * wrapGiB, usable: 4 * wrapGiB, modulus: 4 * wrapGiB)
    let result = try WrapDetector.run(wrapRunner(device), layout: Layout(evictBytes: wrapMiB), candidates: [4 * wrapGiB], seed: 1)
    #expect(result.confirmedModulus == 4 * wrapGiB)
    #expect(result.trials.count == 3)
    #expect(device.writeCount < 100) // Batched trials share two eviction rounds.
}

@Test func confirms32GiBWrap() throws {
    let device = FakeDevice(reported: 512 * wrapGiB, usable: 32 * wrapGiB, modulus: 32 * wrapGiB)
    let result = try WrapDetector.run(wrapRunner(device), layout: Layout(evictBytes: wrapMiB), candidates: [32 * wrapGiB], seed: 2)
    #expect(result.confirmedModulus == 32 * wrapGiB)
}

@Test func confirmsBehindCache() throws {
    let device = CachedDevice(FakeDevice(reported: 512 * wrapGiB, usable: 4 * wrapGiB, modulus: 4 * wrapGiB), cacheBytes: 8 * wrapMiB)
    let result = try WrapDetector.run(wrapRunner(device, evictMiB: 16), layout: Layout(evictBytes: 16 * wrapMiB), candidates: [4 * wrapGiB], seed: 3)
    #expect(result.confirmedModulus == 4 * wrapGiB)
}

@Test func nonPowerOfTwoViaDistance() throws {
    let result = WrapDetector.candidates(reportedSize: 32 * wrapGiB, observedDistances: [3 * wrapGiB])
    #expect(result.contains(3 * wrapGiB))
}

@Test func noWrapOnGenuine() throws {
    let device = GenuineDevice(size: 64 * wrapGiB)
    let result = try WrapDetector.run(wrapRunner(device), layout: Layout(evictBytes: wrapMiB), candidates: [wrapGiB, 2 * wrapGiB], seed: 4)
    #expect(result.confirmedModulus == nil)
    #expect(result.suspected.isEmpty)
}

@Test func corruptionNeverConfirms() throws {
    let device = CorruptingDevice(GenuineDevice(size: 64 * wrapGiB), bitErrorRate: 1e-4, seed: 1)
    let result = try WrapDetector.run(wrapRunner(device), layout: Layout(evictBytes: wrapMiB), candidates: [wrapGiB], seed: 5)
    #expect(result.confirmedModulus == nil)
}

@Test func tinyFakeFlagsScopeFloor() throws {
    let device = FakeDevice(reported: 64 * wrapGiB, usable: 32 * wrapMiB, modulus: 32 * wrapMiB)
    let result = try WrapDetector.run(wrapRunner(device, evictMiB: 32), layout: Layout(evictBytes: 32 * wrapMiB), candidates: [wrapGiB], seed: 6)
    #expect(result.belowScopeFloor)
}

@Test func cacheBiggerThanEvictionIsKnownMiss() throws {
    let device = CachedDevice(FakeDevice(reported: 512 * wrapGiB, usable: 4 * wrapGiB, modulus: 4 * wrapGiB), cacheBytes: 512 * wrapMiB)
    let result = try WrapDetector.run(wrapRunner(device, evictMiB: 1), layout: Layout(evictBytes: wrapMiB), candidates: [4 * wrapGiB], seed: 7)
    #expect(result.confirmedModulus == nil)
}

@Test func smallerCandidateCanConfirmLargerPeriod() throws {
    let device = FakeDevice(reported: 512 * wrapGiB, usable: 256 * wrapMiB, modulus: 256 * wrapMiB)
    let result = try WrapDetector.run(wrapRunner(device), layout: Layout(evictBytes: wrapMiB), candidates: [512 * wrapMiB], seed: 8)
    #expect(result.confirmedModulus == 512 * wrapMiB)
}
