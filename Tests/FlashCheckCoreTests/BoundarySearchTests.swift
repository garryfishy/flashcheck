import Testing
@testable import FlashCheckCore

private let boundaryGiB: UInt64 = 1024 * 1024 * 1024
private let boundaryMiB: UInt64 = 1024 * 1024
private let boundaryPattern = PatternGenerator(session: SessionKey(id: Array(0..<16), keyBytes: Array(0..<32)))

private func boundaryRunner(_ device: BlockDevice, evictMiB: UInt64 = 1) -> RoundRunner {
    RoundRunner(device: device, pattern: boundaryPattern, layout: Layout(evictBytes: evictMiB * boundaryMiB), isCancelled: { false })
}

@Test func findsDiscardBoundaryNonPow2() throws {
    let usable: UInt64 = 3_900_000_000
    let device = FakeDevice(reported: 8 * boundaryGiB, usable: usable)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 2 * boundaryGiB, hi: 4 * boundaryGiB, top: 8 * boundaryGiB, seed: 11)
    #expect(result.established)
    #expect(result.firstBad.map { distance($0, usable) <= boundaryMiB } == true)
}

@Test func findsRejectBoundary32() throws {
    let usable = 32 * boundaryGiB
    let device = FakeDevice(reported: 64 * boundaryGiB, usable: usable, beyond: .reject)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 16 * boundaryGiB, hi: 40 * boundaryGiB, top: 64 * boundaryGiB, seed: 12)
    #expect(result.established)
    #expect(result.firstBad.map { distance($0, usable) <= boundaryMiB } == true)
}

@Test func limboBoundaryNotTooHigh() throws {
    let usable: UInt64 = 3_900_000_000
    let device = FakeDevice(reported: 8 * boundaryGiB, usable: usable, beyond: .limbo)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 2 * boundaryGiB, hi: 4 * boundaryGiB, top: 8 * boundaryGiB, seed: 13)
    #expect(result.firstBad.map { $0 <= usable + boundaryMiB } == true)
}

@Test func wrapPlusDiscard() throws {
    let usable: UInt64 = 3_700_000_000
    let device = FakeDevice(reported: 64 * boundaryGiB, usable: usable, modulus: 4 * boundaryGiB)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 2 * boundaryGiB, hi: 4 * boundaryGiB, top: 4 * boundaryGiB, seed: 14)
    #expect(result.established)
    #expect(result.firstBad.map { distance($0, usable) <= boundaryMiB } == true)
}

@Test func scatteredFailuresNotEstablished() throws {
    let device = CorruptingDevice(GenuineDevice(size: 64 * boundaryGiB), bitErrorRate: 1e-4, seed: 15)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 2 * boundaryGiB, hi: 8 * boundaryGiB, top: 64 * boundaryGiB, seed: 16)
    #expect(!result.established)
    #expect(!result.monotonic)
}

@Test func roundCountBounded() throws {
    let device = FakeDevice(reported: 8 * boundaryGiB, usable: 4 * boundaryGiB)
    let result = try BoundarySearch.run(boundaryRunner(device), lo: 2 * boundaryGiB, hi: 6 * boundaryGiB, top: 8 * boundaryGiB, seed: 17)
    #expect(result.rounds <= 7)
}

private func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 { lhs > rhs ? lhs - rhs : rhs - lhs }
