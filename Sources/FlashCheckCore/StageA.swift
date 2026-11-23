import Foundation

public enum Reproducibility: String, Codable, Sendable {
    case transient, intermittent, persistent
}

public struct StageAResult: Codable, Sendable {
    public var records: [ProbeRecord]
    public var preReads: [UInt64: ReadObservation]
    public var retests: [UInt64: Reproducibility]

    public var allMatched: Bool { records.allSatisfy(\.isGood) }
    public var highestGood: UInt64? { records.filter { $0.isGood || retests[$0.offset] == .transient }.map(\.offset).max() }
    public var lowestBad: UInt64? { records.filter { !$0.isGood && retests[$0.offset] != .transient }.map(\.offset).min() }
    public var foreignDistances: [UInt64] {
        records.flatMap { record in
            record.reads.compactMap { observation -> UInt64? in
                guard case .foreign(let offset, _, _) = observation.verification else { return nil }
                return offset >= record.offset ? offset - record.offset : record.offset - offset
            }
        }
    }
}

public enum StageA {
    public static func run(_ runner: RoundRunner, reportedSize: UInt64, seed: UInt64, onProgress: ((Int, Int) -> Void)? = nil) throws(IOError) -> StageAResult {
        let offsets = ProbePlanner.stageAOffsets(reportedSize: reportedSize, seed: seed)
        var preReads: [UInt64: ReadObservation] = [:]
        for (index, offset) in offsets.enumerated() {
            preReads.merge(try runner.preRead([offset])) { _, new in new }
            onProgress?(index + 1, offsets.count)
        }
        let firstRound = try runner.round(writes: offsets.map { ($0, .probe) }, reads: offsets, decoysAbove: nil)
        let secondReads = try runner.reread(offsets)
        var records = firstRound.filter { $0.kind == .probe }
        for index in records.indices {
            if let observation = secondReads[records[index].offset] { records[index].reads.append(observation) }
        }

        var retests: [UInt64: Reproducibility] = [:]
        if records.count >= 3 {
            for index in 1..<(records.count - 1) where !records[index].isGood && records[index - 1].isGood && records[index + 1].isGood {
                let offset = records[index].offset
                _ = try runner.round(writes: [(offset, .probe)], reads: [offset], decoysAbove: nil)
                let first = try runner.reread([offset])[offset]?.verification == .match
                _ = try runner.round(writes: [(offset, .probe)], reads: [offset], decoysAbove: nil)
                let second = try runner.reread([offset])[offset]?.verification == .match
                let failures = (first ? 0 : 1) + (second ? 0 : 1)
                retests[offset] = failures == 0 ? .transient : (failures == 1 ? .intermittent : .persistent)
            }
        }
        return StageAResult(records: records, preReads: preReads, retests: retests)
    }
}
