import Testing
import Foundation
@testable import FlashCheckCore

private let mGiB: UInt64 = 1024 * 1024 * 1024
private let mMiB: UInt64 = 1024 * 1024

private struct MatrixCase: @unchecked Sendable {
    let name: String
    let makeDevice: () -> BlockDevice
    let mode: Mode
    let verdict: Verdict
    let evictMiB: UInt64
    let check: (Report) -> Bool
}

private let matrixCases: [MatrixCase] = [
    .init(name: "genuine", makeDevice: { GenuineDevice(size: 64 * mGiB) }, mode: .scan, verdict: .sampledPassed, check: { $0.capacity.kind == .undetermined && $0.capacity.usableLow == nil && $0.capacity.note.localizedCaseInsensitiveContains("sampled") }),
    .init(name: "cached genuine", makeDevice: { CachedDevice(GenuineDevice(size: 64 * mGiB), cacheBytes: 32 * mMiB) }, mode: .scan, verdict: .sampledPassed, check: { $0.stageA?.allMatched == true }),
    .init(name: "wrap 4 GiB", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 4 * mGiB, modulus: 4 * mGiB) }, mode: .probe, verdict: .misrepresentation, check: { $0.capacity.wrapModulus == 4 * mGiB }),
    .init(name: "wrap 32 GiB", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 32 * mGiB, modulus: 32 * mGiB) }, mode: .probe, verdict: .misrepresentation, check: { $0.capacity.wrapModulus == 32 * mGiB }),
    .init(name: "cached wrap 4 GiB", makeDevice: { CachedDevice(FakeDevice(reported: 512 * mGiB, usable: 4 * mGiB, modulus: 4 * mGiB), cacheBytes: 8 * mMiB) }, mode: .probe, verdict: .misrepresentation, evictMiB: 16, check: { $0.capacity.wrapModulus == 4 * mGiB }),
    .init(name: "discard 3.9 GiB", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 3_900_000_000) }, mode: .scan, verdict: .misrepresentation, check: { $0.capacity.kind == .established && abs(Int64($0.capacity.usableLow ?? 0) - 3_900_000_000) <= 1_048_576 }),
    .init(name: "reject 32 GiB", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 32 * mGiB, beyond: .reject) }, mode: .scan, verdict: .misrepresentation, check: { abs(Int64($0.capacity.usableLow ?? 0) - Int64(32 * mGiB)) <= 1_048_576 }),
    .init(name: "wrap and discard", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 3_700_000_000, modulus: 4 * mGiB) }, mode: .probe, verdict: .misrepresentation, check: { $0.capacity.wrapModulus == 4 * mGiB && abs(Int64($0.capacity.usableLow ?? 0) - 3_700_000_000) <= 1_048_576 }),
    .init(name: "limbo", makeDevice: { FakeDevice(reported: 512 * mGiB, usable: 3_900_000_000, beyond: .limbo) }, mode: .scan, verdict: .misrepresentation, check: { $0.capacity.kind == .established && ($0.capacity.usableHigh ?? UInt64.max) <= 3_900_000_000 + 1_048_576 }),
    .init(name: "scope floor 32 MiB", makeDevice: { FakeDevice(reported: 64 * mGiB, usable: 32 * mMiB, modulus: 32 * mMiB) }, mode: .probe, verdict: .inconclusive, evictMiB: 32, check: { $0.capacity.note == "real capacity may be below 512 MiB — run full" }),
    .init(name: "256 MiB wraps at scope floor", makeDevice: { FakeDevice(reported: 64 * mGiB, usable: 256 * mMiB, modulus: 256 * mMiB) }, mode: .probe, verdict: .misrepresentation, check: { $0.capacity.wrapModulus == 512 * mMiB && $0.capacity.note.localizedCaseInsensitiveContains("true wrap period may be smaller") }),
    .init(name: "corruption", makeDevice: { CorruptingDevice(GenuineDevice(size: 64 * mGiB), bitErrorRate: 1e-4, seed: 31) }, mode: .scan, verdict: .integrityFailure, check: { $0.capacity.wrapModulus == nil }),
    .init(name: "flaky", makeDevice: { FlakyDevice(GenuineDevice(size: 64 * mGiB), readFailureRate: 0.08, seed: 12) }, mode: .scan, verdict: .integrityFailure, check: { $0.verdict == .integrityFailure }),
    .init(name: "full genuine 2 GiB", makeDevice: { GenuineDevice(size: 2 * mGiB) }, mode: .full, verdict: .fullPassed, check: { $0.full?.unitsMatched == $0.full?.unitsTotal }),
    .init(name: "full discard 1.5 of 2 GiB", makeDevice: { FakeDevice(reported: 2 * mGiB, usable: 1_610_612_736) }, mode: .full, verdict: .misrepresentation, check: { abs(Int64($0.full?.firstBad ?? 0) - 1_610_612_736) <= 65_536 })
]

extension MatrixCase {
    init(name: String, makeDevice: @escaping () -> BlockDevice, mode: Mode, verdict: Verdict, check: @escaping (Report) -> Bool) {
        self.init(name: name, makeDevice: makeDevice, mode: mode, verdict: verdict, evictMiB: 1, check: check)
    }
}

@Test
private func engineMatrix() {
    for c in matrixCases where c.mode != .full {
    let device = c.makeDevice()
    let session = SessionKey(id: Array(0..<16), keyBytes: Array(0..<32))
    let config = EngineConfig(mode: c.mode, evictBytes: c.evictMiB * mMiB, seed: 7)
    let report = Engine(device: device, summary: DeviceSummary(name: c.name, identifier: c.name, reportedSize: device.reportedSize, blockSize: device.blockSize, connection: "sim"), session: session, config: config, onEvent: { _ in }, isCancelled: { false }).run()
    let verdictMatches = report.verdict == c.verdict
    let detailsMatch = c.check(report)
    #expect(verdictMatches, "\(c.name): got \(report.verdict), expected \(c.verdict)")
    #expect(detailsMatch, "\(c.name): capacity kind \(report.capacity.kind), modulus \(String(describing: report.capacity.wrapModulus)), boundary \(String(describing: report.boundary?.established))")
    }
}

@Test
private func engineFullMatrix() {
    for isGenuine in [true, false] {
    let device: BlockDevice = isGenuine ? GenuineDevice(size: 2 * mGiB) : FakeDevice(reported: 2 * mGiB, usable: 1_610_612_736)
    let name = isGenuine ? "full genuine 2 GiB" : "full discard 1.5 of 2 GiB"
    let expected: Verdict = isGenuine ? .fullPassed : .misrepresentation
    let session = SessionKey(id: Array(0..<16), keyBytes: Array(0..<32))
    let report = Engine(device: device, summary: DeviceSummary(name: name, identifier: name, reportedSize: device.reportedSize, blockSize: device.blockSize, connection: "sim"), session: session, config: EngineConfig(mode: .full, evictBytes: 1 * mMiB, seed: 7), onEvent: { _ in }, isCancelled: { false }).run()
    #expect(report.verdict == expected, "\(name): got \(report.verdict), expected \(expected)")
    if isGenuine { #expect(report.full?.unitsMatched == report.full?.unitsTotal) }
    else { #expect(abs(Int64(report.full?.firstBad ?? 0) - 1_610_612_736) <= 65_536) }
    }
}
