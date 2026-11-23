import Testing
@testable import FlashCheckCore

@Test func stageAIncludesPowersAndLastUnit() {
    let offsets = ProbePlanner.stageAOffsets(reportedSize: 512 * 1024 * 1024 * 1024, seed: 17)
    #expect(offsets.contains(1 * 1024 * 1024 * 1024))
    #expect(offsets.contains(1 * 1024 * 1024 * 1024 - Layout.unit))
    #expect(offsets.contains(256 * 1024 * 1024 * 1024))
    #expect(offsets.contains(512 * 1024 * 1024 * 1024 - Layout.unit))
    #expect(offsets.allSatisfy { $0 >= Layout.minCandidate })
}

@Test func oddGeometry() {
    let size: UInt64 = 536_871_960_576
    let offsets = ProbePlanner.stageAOffsets(reportedSize: size, seed: 19)
    #expect(offsets.allSatisfy { $0 % Layout.unit == 0 && $0 + Layout.unit <= size })
}

@Test func decoysSampleLargeDeviceWithinRange() {
    let size: UInt64 = 2 * 1024 * 1024 * 1024 * 1024
    let above: UInt64 = 512 * 1024 * 1024
    let excluding: Set<UInt64> = [above + Layout.unit, above + 3 * Layout.unit]
    let offsets = ProbePlanner.decoyOffsets(above: above, reportedSize: size, count: 4, round: 7, seed: 23, excluding: excluding)
    #expect(offsets.count == 4)
    #expect(offsets.allSatisfy { $0 % Layout.unit == 0 && $0 > above && $0 < size })
    #expect(Set(offsets).count == offsets.count)
    #expect(offsets.allSatisfy { !excluding.contains($0) })
}

@Test func decoySamplingIsDeterministic() {
    let arguments: (above: UInt64, reportedSize: UInt64, count: Int, round: Int, seed: UInt64) =
        (512 * 1024 * 1024, 2 * 1024 * 1024 * 1024 * 1024, 4, 7, 23)
    let first = ProbePlanner.decoyOffsets(above: arguments.above, reportedSize: arguments.reportedSize, count: arguments.count, round: arguments.round, seed: arguments.seed)
    let second = ProbePlanner.decoyOffsets(above: arguments.above, reportedSize: arguments.reportedSize, count: arguments.count, round: arguments.round, seed: arguments.seed)
    #expect(first == second)
}

@Test func decoySamplingReturnsEmptyWhenAllSlotsExcluded() {
    let above: UInt64 = 10 * Layout.unit
    let size = above + 4 * Layout.unit
    let excluding: Set<UInt64> = [above + Layout.unit, above + 2 * Layout.unit, above + 3 * Layout.unit]
    let offsets = ProbePlanner.decoyOffsets(above: above, reportedSize: size, count: 4, round: 1, seed: 2, excluding: excluding)
    #expect(offsets == [])
}
