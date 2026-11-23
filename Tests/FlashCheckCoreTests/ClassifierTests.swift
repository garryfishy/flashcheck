import Testing
@testable import FlashCheckCore

@Test func classifierBaselineCases() {
    let clean = StageAResult(records: [], preReads: [:], retests: [:])
    let passed = Classifier.classify(mode: .scan, stageA: clean, wrap: nil, boundary: nil, full: nil)
    #expect(passed.0 == .sampledPassed)
    #expect(passed.1.kind == .undetermined)
    #expect(passed.1.note.localizedCaseInsensitiveContains("sampled"))

    let wrapped = Classifier.classify(mode: .probe, stageA: nil, wrap: WrapResult(confirmedModulus: 512 * 1024 * 1024), boundary: nil, full: nil)
    #expect(wrapped.0 == .misrepresentation)
    #expect(wrapped.1.kind == .wrapOnly)
    #expect(wrapped.1.note.localizedCaseInsensitiveContains("smaller"))

    let floor = Classifier.classify(mode: .probe, stageA: nil, wrap: WrapResult(belowScopeFloor: true), boundary: nil, full: nil)
    #expect(floor.0 == .inconclusive)
    #expect(floor.1.note == "real capacity may be below 512 MiB — run full")
}

@Test func classifierDecisionRows() {
    let match = ReadObservation(error: nil, verification: .match)
    let goodRecord = ProbeRecord(sequence: 0, sessionID: "s", offset: 1 << 30, length: 65_536, kind: .probe, generation: 0, reads: [match, match])
    let good = StageAResult(records: [goodRecord], preReads: [:], retests: [:])
    let boundary = BoundaryResult(lastGoodEnd: 3_900_000_000, firstBad: 3_900_500_000, monotonic: true, rounds: 4)
    let established = Classifier.classify(mode: .scan, reported: 8_000_000_000, stageA: good, wrap: nil, boundary: boundary, full: nil)
    #expect(established.0 == .misrepresentation)
    #expect(established.1.kind == .established)

    let suspected = Classifier.classify(mode: .probe, reported: 8_000_000_000, stageA: good, wrap: WrapResult(suspected: [1 << 30]), boundary: nil, full: nil)
    #expect(suspected.0 == .inconclusive)

    let badRecord = ProbeRecord(sequence: 1, sessionID: "s", offset: 2 << 30, length: 65_536, kind: .probe, generation: 0, reads: [ReadObservation(error: nil, verification: .garbage), ReadObservation(error: nil, verification: .garbage)])
    let bad = StageAResult(records: [badRecord], preReads: [:], retests: [:])
    #expect(Classifier.classify(mode: .scan, reported: 8_000_000_000, stageA: bad, wrap: nil, boundary: nil, full: nil).0 == .integrityFailure)
    let transient = StageAResult(records: [badRecord], preReads: [:], retests: [badRecord.offset: .transient])
    #expect(Classifier.classify(mode: .scan, reported: 8_000_000_000, stageA: transient, wrap: nil, boundary: nil, full: nil).0 == .inconclusive)

    let fullPass = Classifier.classify(mode: .full, reported: 100, stageA: nil, wrap: nil, boundary: nil, full: FullResult(unitsTotal: 1, unitsMatched: 1, firstBad: nil, badRanges: [], writeMBps: 1, readMBps: 1))
    #expect(fullPass.0 == .fullPassed)
    let fullFail = Classifier.classify(mode: .full, reported: 100, stageA: nil, wrap: nil, boundary: nil, full: FullResult(unitsTotal: 1, unitsMatched: 0, firstBad: 0, badRanges: [0..<65_536], writeMBps: 1, readMBps: 1))
    #expect(fullFail.0 == .misrepresentation)
}
