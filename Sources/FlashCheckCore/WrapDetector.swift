import Foundation

public struct AliasTrial: Codable, Sendable {
    public let modulus: UInt64
    public let base: UInt64
    public let readAtBase: Verification?
    public let readAtAlias: Verification?
    public let confirms: Bool

    public init(modulus: UInt64, base: UInt64, readAtBase: Verification?, readAtAlias: Verification?, confirms: Bool) {
        self.modulus = modulus
        self.base = base
        self.readAtBase = readAtBase
        self.readAtAlias = readAtAlias
        self.confirms = confirms
    }
}

public struct WrapResult: Codable, Sendable {
    public var confirmedModulus: UInt64?
    public var suspected: [UInt64]
    public var trials: [AliasTrial]
    public var belowScopeFloor: Bool

    public init(confirmedModulus: UInt64? = nil, suspected: [UInt64] = [], trials: [AliasTrial] = [], belowScopeFloor: Bool = false) {
        self.confirmedModulus = confirmedModulus
        self.suspected = suspected
        self.trials = trials
        self.belowScopeFloor = belowScopeFloor
    }
}

public enum WrapDetector {
    public static func candidates(reportedSize: UInt64, observedDistances: [UInt64]) -> [UInt64] {
        var values = Set(observedDistances.filter { $0 >= Layout.minCandidate && $0 < reportedSize && $0 % Layout.unit == 0 })
        var power = Layout.minCandidate
        while power < reportedSize {
            values.insert(power)
            let (next, overflow) = power.multipliedReportingOverflow(by: 2)
            if overflow { break }
            power = next
        }
        return values.sorted()
    }

    public static func run(_ runner: RoundRunner, layout: Layout, candidates: [UInt64], trialsPerCandidate: Int = 3, seed: UInt64) throws(IOError) -> WrapResult {
        var result = WrapResult()
        let count = max(0, trialsPerCandidate)
        var usedBaseSets = Set<[UInt64]>()

        for modulus in Array(Set(candidates)).sorted() {
            guard modulus >= Layout.minCandidate, modulus % Layout.unit == 0 else { continue }
            var candidateSeed = seed ^ modulus
            var bases = selectedBases(layout.aliasBases, count: count, seed: candidateSeed)
            while usedBaseSets.contains(bases), !bases.isEmpty {
                candidateSeed &+= 0x9E37_79B9_7F4A_7C15
                bases = selectedBases(layout.aliasBases, count: count, seed: candidateSeed)
            }
            usedBaseSets.insert(bases)
            let pairs = bases.compactMap { base -> (base: UInt64, alias: UInt64)? in
                let (alias, overflow) = base.addingReportingOverflow(modulus)
                return overflow ? nil : (base, alias)
            }
            guard !pairs.isEmpty else { continue }

            // Keep each trial's base tag live while testing all bases for this
            // modulus. Two rounds replace the previous two rounds per trial.
            _ = try runner.round(writes: pairs.map { ($0.base, .aliasA) }, reads: [], decoysAbove: nil)
            let reads = pairs.flatMap { [$0.base, $0.alias] }
            let records = try runner.round(writes: pairs.map { ($0.alias, .aliasB) }, reads: reads, decoysAbove: nil)
            var observations: [UInt64: ReadObservation] = [:]
            for record in records {
                if let observation = record.reads.first { observations[record.offset] = observation }
            }

            var confirms = 0
            for pair in pairs {
                let atBase = observations[pair.base]?.verification
                let atAlias = observations[pair.alias]?.verification
                let confirmsTrial: Bool
                if case .foreign(let offset, .aliasB, _) = atBase, offset == pair.alias {
                    confirmsTrial = true
                } else {
                    confirmsTrial = false
                }
                result.trials.append(AliasTrial(modulus: modulus, base: pair.base, readAtBase: atBase, readAtAlias: atAlias, confirms: confirmsTrial))
                if isFiller(atBase) || isFiller(atAlias) { result.belowScopeFloor = true }
                if confirmsTrial { confirms += 1 }
            }
            if !pairs.isEmpty, confirms == pairs.count {
                result.confirmedModulus = modulus
                break
            }
            if confirms > 0 { result.suspected.append(modulus) }
        }
        return result
    }

    private static func selectedBases(_ range: Range<UInt64>, count: Int, seed: UInt64) -> [UInt64] {
        guard count > 0 else { return [] }
        let first = (range.lowerBound + Layout.unit - 1) / Layout.unit * Layout.unit
        let end = range.upperBound / Layout.unit * Layout.unit
        guard end > first else { return [] }
        let available = Int((end - first) / Layout.unit)
        let actualCount = min(count, available)
        var indices = Array(0..<available)
        var random = seed
        if !indices.isEmpty {
            for i in indices.indices.reversed() where i > 0 {
                random &+= 0x9E37_79B9_7F4A_7C15
                var value = random
                value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
                value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
                value ^= value >> 31
                indices.swapAt(i, Int(value % UInt64(i + 1)))
            }
        }
        return indices.prefix(actualCount).map { first + UInt64($0) * Layout.unit }
    }

    private static func isFiller(_ verification: Verification?) -> Bool {
        if case .foreign(_, .filler, _)? = verification { return true }
        return false
    }
}
