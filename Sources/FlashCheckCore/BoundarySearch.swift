import Foundation

public struct BoundaryResult: Codable, Sendable {
    public var lastGoodEnd: UInt64?
    public var firstBad: UInt64?
    public var monotonic: Bool
    public var established: Bool { monotonic && lastGoodEnd != nil && firstBad != nil && firstBad! >= lastGoodEnd! && firstBad! - lastGoodEnd! <= resolution }
    public var rounds: Int
    private var resolution: UInt64

    public init(lastGoodEnd: UInt64?, firstBad: UInt64?, monotonic: Bool, rounds: Int, resolution: UInt64 = 1 << 20) {
        self.lastGoodEnd = lastGoodEnd
        self.firstBad = firstBad
        self.monotonic = monotonic
        self.rounds = rounds
        self.resolution = resolution
    }
}

public enum BoundarySearch {
    public static func run(_ runner: RoundRunner, lo initialLo: UInt64, hi initialHi: UInt64, top: UInt64, k: Int = 8, resolution: UInt64 = 1 << 20, seed: UInt64) throws(IOError) -> BoundaryResult {
        let unit = Layout.unit
        var lo = alignDown(initialLo, unit: unit)
        var hi = alignDown(initialHi, unit: unit)
        let alignedTop = alignDown(top, unit: unit)
        var rounds = 0
        var monotonic = true

        guard k > 0, resolution > 0, hi > lo, alignedTop >= hi else {
            return BoundaryResult(lastGoodEnd: nil, firstBad: nil, monotonic: false, rounds: rounds, resolution: resolution)
        }

        while hi > lo, hi - lo > resolution {
            let points = evenlySpaced(lo: lo, hi: hi, count: k, unit: unit)
            guard !points.isEmpty else { break }
            let records = try runner.round(writes: points.map { ($0, .probe) }, reads: points, decoysAbove: hi)
            rounds += 1
            let outcomes = Dictionary(records.filter { $0.kind == .probe }.map { ($0.offset, isGood($0)) }, uniquingKeysWith: { _, latest in latest })
            let good = outcomes.filter(\.value).map(\.key).max()
            let bad = outcomes.filter { !$0.value }.map(\.key).min()
            if let good { lo = good }
            if let bad { hi = bad }
            if let good, let bad, good >= bad { monotonic = false; break }
            if good == nil && bad == nil { monotonic = false; break }
        }

        var sample = SplitMix64(seed: seed)
        let floor: UInt64 = 512 * 1024 * 1024
        let lowStart = min(floor, lo)
        if lo > lowStart {
            for offset in randomOffsets(from: lowStart, to: lo, count: 8, rng: &sample, unit: unit) {
                if try !check(runner, offset: offset) { monotonic = false }
            }
        }
        if alignedTop > hi {
            for offset in randomOffsets(from: hi, to: alignedTop, count: 8, rng: &sample, unit: unit) {
                if try check(runner, offset: offset) { monotonic = false }
            }
        }

        let boundaryOffsets = Array(Set([lo, hi])).sorted()
        if !boundaryOffsets.isEmpty {
            let records = try runner.round(writes: boundaryOffsets.map { ($0, .probe) }, reads: boundaryOffsets, decoysAbove: hi)
            rounds += 1
            let outcomes = Dictionary(records.filter { $0.kind == .probe }.map { ($0.offset, isGood($0)) }, uniquingKeysWith: { _, latest in latest })
            if outcomes[lo] != true || outcomes[hi] != false { monotonic = false }
        }

        return BoundaryResult(lastGoodEnd: lo <= UInt64.max - unit ? lo + unit : nil, firstBad: hi, monotonic: monotonic, rounds: rounds, resolution: resolution)
    }

    private static func check(_ runner: RoundRunner, offset: UInt64) throws(IOError) -> Bool {
        let records = try runner.round(writes: [(offset, .probe)], reads: [offset], decoysAbove: nil)
        return records.first(where: { $0.kind == .probe }).map(isGood) ?? false
    }

    private static func evenlySpaced(lo: UInt64, hi: UInt64, count: Int, unit: UInt64) -> [UInt64] {
        guard count > 0, hi > lo else { return [] }
        let span = hi - lo
        return (1...count).compactMap { index in
            let distance = span / UInt64(count + 1) * UInt64(index)
            let point = alignDown(lo + distance, unit: unit)
            return point > lo && point < hi ? point : nil
        }.reduce(into: []) { result, point in
            if result.last != point { result.append(point) }
        }
    }

    private static func randomOffsets(from lower: UInt64, to upper: UInt64, count: Int, rng: inout SplitMix64, unit: UInt64) -> [UInt64] {
        guard upper > lower + unit, count > 0 else { return [] }
        let first = lower / unit + 1
        let last = (upper - 1) / unit
        guard last >= first else { return [] }
        let slots = last - first + 1
        return (0..<count).map { _ in first + rng.next() % slots }.map { $0 * unit }
    }

    private static func alignDown(_ value: UInt64, unit: UInt64) -> UInt64 { value / unit * unit }

    private static func isGood(_ record: ProbeRecord) -> Bool {
        record.writeError == nil && record.syncError == nil && record.reads.contains { $0.verification == .match }
    }
}
